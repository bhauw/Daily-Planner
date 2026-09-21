import DailyPlannerDomain
import Foundation
import os

public enum GoogleCalendarReadClientError: Error, Equatable, CaseIterable, Sendable {
    case missingPrimary
    case duplicatePrimary
    case expiredSyncToken
    case cancelled
    case offline
    case providerUnavailable
    case malformedResponse
    case limitViolation
}

public struct GoogleCalendarReadClient: GoogleCalendarReading, Sendable {
    public let transport: any GoogleHTTPTransport

    public init(transport: any GoogleHTTPTransport) {
        self.transport = transport
    }

    public func primaryCalendar(accessToken: GoogleAccessToken) async throws -> GoogleCalendarRecord {
        do {
            let primaries = try await allCalendars(accessToken: accessToken).filter(\.isPrimary)
            guard primaries.count == 1 else {
                throw primaries.isEmpty
                    ? GoogleCalendarReadClientError.missingPrimary
                    : GoogleCalendarReadClientError.duplicatePrimary
            }
            return primaries[0]
        } catch {
            throw mapCalendarError(error)
        }
    }

    /// Every readable calendar, primary and secondary alike, carrying its Google colour.
    /// Secondary calendars are no longer dropped — their colours drive categorisation and
    /// they must be selectable in Settings — while role assignment stays fail-closed
    /// (see `CalendarRolePolicy`: an unassigned calendar is Excluded reference).
    public func calendars(accessToken: GoogleAccessToken) async throws -> [GoogleCalendarRecord] {
        do {
            return try await allCalendars(accessToken: accessToken)
        } catch {
            throw mapCalendarError(error)
        }
    }

    private func allCalendars(accessToken: GoogleAccessToken) async throws -> [GoogleCalendarRecord] {
        let pages = try await readCalendarListPages(
            accessToken: accessToken,
            maximumPages: GoogleSyncLimits.calendarPages
        )
        return pages.flatMap(\.calendars)
    }

    public func events(
        calendarID: CalendarID,
        interval: DateInterval,
        syncToken: CalendarSyncToken?,
        pageToken: CalendarPageToken?,
        accessToken: GoogleAccessToken
    ) async throws -> CalendarEventPage {
        do {
            let url = try CalendarURL.events(
                calendarID: calendarID,
                interval: interval,
                syncToken: syncToken,
                pageToken: pageToken
            )
            try Task.checkCancellation()
            let response = try await transport.send(
                GoogleRequestBuilder.get(url: url, accessToken: accessToken)
            )
            guard response.statusCode != 410 else {
                throw GoogleCalendarReadClientError.expiredSyncToken
            }
            return try CalendarWireDecoder.page(from: response, calendarID: calendarID)
        } catch {
            throw mapCalendarError(error)
        }
    }

    private func readCalendarListPages(
        accessToken: GoogleAccessToken,
        maximumPages: Int
    ) async throws -> [CalendarListPage] {
        guard maximumPages > 0 else { throw GoogleCalendarReadClientError.limitViolation }
        var pages: [CalendarListPage] = []
        var pageToken: CalendarPageToken?
        var seenTokens = Set<CalendarPageToken>()

        for pageIndex in 0..<maximumPages {
            try Task.checkCancellation()
            let url = try CalendarURL.calendarList(pageToken: pageToken)
            let response = try await transport.send(
                GoogleRequestBuilder.get(url: url, accessToken: accessToken)
            )
            let page = try CalendarWireDecoder.calendarListPage(from: response)
            pages.append(page)
            guard let next = page.nextPageToken else { return pages }
            guard pageIndex + 1 < maximumPages else {
                throw GoogleCalendarReadClientError.limitViolation
            }
            guard seenTokens.insert(next).inserted else {
                throw malformed("calendar list paging repeated a page token")
            }
            pageToken = next
        }
        throw GoogleCalendarReadClientError.limitViolation
    }
}

private enum CalendarURL {
    static func calendarList(pageToken: CalendarPageToken?) throws -> URL {
        var items = [
            URLQueryItem(name: "minAccessRole", value: "reader"),
            URLQueryItem(name: "showDeleted", value: "false"),
            URLQueryItem(name: "maxResults", value: "100"),
        ]
        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: try CalendarProviderValue.raw(pageToken)))
        }
        return try url(path: "/calendar/v3/users/me/calendarList", items: items)
    }

    static func events(
        calendarID: CalendarID,
        interval: DateInterval,
        syncToken: CalendarSyncToken?,
        pageToken: CalendarPageToken?
    ) throws -> URL {
        guard interval.start < interval.end else { throw malformed("requested interval is empty or inverted") }
        let encodedCalendarID = try CalendarProviderValue.encodedPathSegment(calendarID)
        var items = [
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "showDeleted", value: "true"),
            URLQueryItem(name: "maxResults", value: "100"),
        ]
        if let syncToken {
            items.append(URLQueryItem(name: "syncToken", value: try CalendarProviderValue.raw(syncToken)))
        } else {
            items.append(URLQueryItem(name: "timeMin", value: CalendarRFC3339.string(from: interval.start)))
            items.append(URLQueryItem(name: "timeMax", value: CalendarRFC3339.string(from: interval.end)))
        }
        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: try CalendarProviderValue.raw(pageToken)))
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.googleapis.com"
        components.percentEncodedPath = "/calendar/v3/calendars/\(encodedCalendarID)/events"
        components.queryItems = items
        guard let result = components.url else { throw malformed("events URL could not be composed") }
        return result
    }

    private static func url(path: String, items: [URLQueryItem]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.googleapis.com"
        components.path = path
        components.queryItems = items
        guard let result = components.url else { throw malformed("calendar list URL could not be composed") }
        return result
    }
}

private enum CalendarProviderValue {
    private static let maximumIDBytes = 1_024
    private static let maximumTokenBytes = 4_096

    static func calendarID(_ value: String) throws -> CalendarID {
        guard isSafeID(value) else { throw malformed("calendarList id failed the safe-ID check") }
        return CalendarID(rawValue: value)
    }

    static func eventID(_ value: String) throws -> GoogleCalendarEventID {
        guard isSafeID(value) else { throw malformed("event.id failed the safe-ID check") }
        do {
            return try GoogleCalendarEventID(validating: value)
        } catch {
            throw malformed("event.id rejected by GoogleCalendarEventID validation")
        }
    }

    static func pageToken(_ value: String?) throws -> CalendarPageToken? {
        guard let value else { return nil }
        guard isSafeToken(value) else { throw malformed("page token failed the safe-token check") }
        do {
            return try CalendarPageToken(validating: value)
        } catch {
            throw malformed("page token rejected by CalendarPageToken validation")
        }
    }

    static func syncToken(_ value: String?) throws -> CalendarSyncToken? {
        guard let value else { return nil }
        guard isSafeToken(value) else { throw malformed("sync token failed the safe-token check") }
        do {
            return try CalendarSyncToken(validating: value)
        } catch {
            throw malformed("sync token rejected by CalendarSyncToken validation")
        }
    }

    static func raw(_ value: CalendarPageToken) throws -> String {
        try value.withUnsafeRawValue { rawValue in
            guard isSafeToken(rawValue) else { throw malformed("stored page token failed the safe-token check") }
            return rawValue
        }
    }

    static func raw(_ value: CalendarSyncToken) throws -> String {
        try value.withUnsafeRawValue { rawValue in
            guard isSafeToken(rawValue) else { throw malformed("stored sync token failed the safe-token check") }
            return rawValue
        }
    }

    static func encodedPathSegment(_ value: CalendarID) throws -> String {
        guard isSafeID(value.rawValue) else { throw malformed("calendar id failed the safe-ID check") }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%\\")
        guard let encoded = value.rawValue.addingPercentEncoding(withAllowedCharacters: allowed),
              !encoded.isEmpty else {
            throw malformed("calendar id could not be percent-encoded for the path")
        }
        return encoded
    }

    private static func isSafeID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumIDBytes && value != "." && value != ".."
            && !value.unicodeScalars.contains { scalar in
                CharacterSet.controlCharacters.contains(scalar)
                    || scalar == "/" || scalar == "\\" || scalar == "%"
            }
    }

    /// Google's page and sync tokens are opaque base64-style strings, so `=` padding is ordinary
    /// and must be accepted — rejecting it threw `malformedResponse` on Google's own valid
    /// response and emptied the day on the very first request, since `page(from:)` reads
    /// `nextSyncToken` even when none was sent.
    ///
    /// `&` and `%` stay forbidden, and they are the two that actually matter: `&` would let a
    /// token split itself into extra query parameters, and a raw `%` makes percent-encoding
    /// ambiguous. `=` can do neither — a query value is split on its *first* `=`, so trailing
    /// padding stays part of the value.
    private static func isSafeToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumTokenBytes
            && !value.unicodeScalars.contains { scalar in
                CharacterSet.controlCharacters.contains(scalar)
                    || scalar == "&" || scalar == "%"
            }
    }
}

private struct CalendarListPage {
    let calendars: [GoogleCalendarRecord]
    let nextPageToken: CalendarPageToken?
}

private struct CalendarWireListPage: Decodable {
    let items: [CalendarWireListItem]?
    let nextPageToken: String?
}

private struct CalendarWireListItem: Decodable {
    let id: String
    let summary: String
    let primary: Bool?
    let accessRole: String
    let colorId: String?
    let backgroundColor: String?
    let foregroundColor: String?
}

private struct CalendarWireEventPage: Decodable {
    let items: [CalendarWireEvent]?
    let nextPageToken: String?
    let nextSyncToken: String?
}

private struct CalendarWireEvent: Decodable {
    let id: String
    let summary: String?
    let description: String?
    let location: String?
    let start: CalendarWireEventTime?
    let end: CalendarWireEventTime?
    let status: String
    let updated: String?
    let colorId: String?
}

private struct CalendarWireEventTime: Decodable {
    let date: String?
    let dateTime: String?
    let timeZone: String?
}

enum CalendarDiagnostics {
    static let log = Logger(subsystem: "com.example.dailyplanner", category: "calendar")
}

/// Records *why* a response was rejected, then returns the same finite error as before.
///
/// Leg 3's route-level logging narrowed a blank calendar to `malformedResponse`, but this
/// decoder has ~25 distinct throw sites, so that still left the actual cause to guesswork — and
/// one bad event fails the whole page, so it only takes one. The reason is a `StaticString`: it
/// can only ever be a literal written here, so no calendar title, event summary, ID or URL can
/// reach the log through this path even by mistake.
private func malformed(_ reason: StaticString) -> GoogleCalendarReadClientError {
    CalendarDiagnostics.log.error("calendar decode rejected: \(reason, privacy: .public)")
    return .malformedResponse
}

private enum CalendarWireDecoder {
    private static let maximumPageItems = 100
    private static let maximumTextScalars = 65_536
    private static let readableRoles: Set<String> = ["reader", "writer", "owner"]

    static func calendarListPage(from response: GoogleHTTPResponse) throws -> CalendarListPage {
        let wire: CalendarWireListPage = try decode(CalendarWireListPage.self, from: response)
        let items = wire.items ?? []
        guard items.count <= maximumPageItems else { throw GoogleCalendarReadClientError.limitViolation }
        let calendars = try items.map { item in
            guard readableRoles.contains(item.accessRole),
                  item.summary.unicodeScalars.count <= GoogleSyncLimits.displayScalars else {
                throw malformed("calendar has an unreadable accessRole or an over-long summary")
            }
            return GoogleCalendarRecord(
                id: try CalendarProviderValue.calendarID(item.id),
                displayName: item.summary,
                isPrimary: item.primary == true,
                colorId: try validatedColorID(item.colorId),
                backgroundColor: try validatedHexColor(item.backgroundColor),
                foregroundColor: try validatedHexColor(item.foregroundColor)
            )
        }
        return CalendarListPage(
            calendars: calendars,
            nextPageToken: try CalendarProviderValue.pageToken(wire.nextPageToken)
        )
    }

    static func page(from response: GoogleHTTPResponse, calendarID: CalendarID) throws -> CalendarEventPage {
        let wire: CalendarWireEventPage = try decode(CalendarWireEventPage.self, from: response)
        let items = wire.items ?? []
        guard items.count <= maximumPageItems else { throw GoogleCalendarReadClientError.limitViolation }
        let nextPageToken = try CalendarProviderValue.pageToken(wire.nextPageToken)
        let nextSyncToken = try CalendarProviderValue.syncToken(wire.nextSyncToken)
        guard nextPageToken == nil || nextSyncToken == nil else {
            throw malformed("page carries both nextPageToken and nextSyncToken")
        }
        // One undecodable event no longer fails the whole page.
        //
        // This was `try items.map`, so a single odd entry threw out of the entire read and the
        // user's day went blank — which is exactly what the sync-token bug did in practice, and
        // what the `timeZone` bug did before it. Dropping the one event we cannot read is still
        // fail-closed *for that event*: it is never guessed at or half-rendered. Blanking an
        // entire day over one entry is the worse failure for a daily driver, so we no longer do
        // it. (Deliberate reversal of the earlier page-level design, at Braxton's call.)
        //
        // Page-level invariants above — the token checks and the item-count limit — still fail
        // the whole page. Those say the *response* is untrustworthy, not one row in it.
        var events: [CalendarEventRecord] = []
        events.reserveCapacity(items.count)
        var skipped = 0
        for item in items {
            do {
                events.append(try record(from: item, calendarID: calendarID))
            } catch {
                // The specific reason is already logged by `malformed(_:)` at the throw site.
                skipped += 1
            }
        }
        if skipped > 0 {
            CalendarDiagnostics.log.error(
                "dropped \(skipped, privacy: .public) undecodable event(s); the rest of the day still renders"
            )
        }

        return CalendarEventPage(
            events: events,
            nextPageToken: nextPageToken,
            nextSyncToken: nextSyncToken
        )
    }

    private static func record(from wire: CalendarWireEvent, calendarID: CalendarID) throws -> CalendarEventRecord {
        guard let status = GoogleEventStatus(rawValue: wire.status) else {
            throw malformed("event.status not a known status")
        }
        for text in [wire.summary, wire.description, wire.location].compactMap({ $0 }) {
            guard text.unicodeScalars.count <= maximumTextScalars else {
                throw GoogleCalendarReadClientError.limitViolation
            }
        }
        let id = try CalendarProviderValue.eventID(wire.id)
        let updatedAt = try updatedAt(from: wire.updated)
        // The event's own colour, if it overrides its calendar's. Nil means it inherits the
        // calendar's colour — resolved explicitly at categorisation time by
        // `GoogleColorCategory.effectiveColorID`, never left to a silent default.
        let eventColorID = try validatedColorID(wire.colorId)

        if status == .cancelled, wire.start == nil, wire.end == nil {
            return CalendarEventRecord(
                id: id,
                calendarID: calendarID,
                title: wire.summary ?? "",
                description: wire.description,
                location: wire.location,
                start: nil,
                end: nil,
                status: status,
                updatedAt: updatedAt,
                privacyClass: .ordinary,
                colorId: eventColorID
            )
        }

        guard let startWire = wire.start,
              let endWire = wire.end,
              let updatedAt else {
            throw malformed("event missing start, end or updated")
        }
        let start = try eventTime(from: startWire)
        let end = try eventTime(from: endWire)
        guard start.kind == end.kind else {
            throw malformed("event start/end kinds differ (date vs dateTime)")
        }
        // A timed event may legitimately be zero-duration — a point-in-time marker, the shape
        // Canvas-style "due at" entries take — so equality is allowed there. An all-day range is
        // not: Google's `end.date` is exclusive, so a well-formed all-day event always spans at
        // least one day and equality really does mean malformed.
        let ordered = start.kind == .dateTime
            ? start.orderingDate <= end.orderingDate
            : start.orderingDate < end.orderingDate
        guard ordered else {
            throw malformed("event end precedes start")
        }
        return CalendarEventRecord(
            id: id,
            calendarID: calendarID,
            title: wire.summary ?? "",
            description: wire.description,
            location: wire.location,
            start: start.value,
            end: end.value,
            status: status,
            updatedAt: updatedAt,
            privacyClass: .ordinary,
            colorId: eventColorID
        )
    }

    /// Google colour ids are short positive-integer strings (e.g. "1"..."24"). Absent is
    /// valid (nil); anything present but malformed fails closed through the finite path.
    private static func validatedColorID(_ value: String?) throws -> String? {
        guard let value else { return nil }
        guard !value.isEmpty, value.utf8.count <= 3,
              value.unicodeScalars.allSatisfy({ (0x30...0x39).contains($0.value) }) else {
            throw malformed("colorId is not a short numeric string")
        }
        return value
    }

    /// A `#RRGGBB` swatch. Absent is valid; a present-but-malformed value is rejected.
    private static func validatedHexColor(_ value: String?) throws -> String? {
        guard let value else { return nil }
        guard value.utf8.count == 7, value.hasPrefix("#"),
              value.dropFirst().unicodeScalars.allSatisfy({ scalar in
                  (0x30...0x39).contains(scalar.value)
                      || (0x41...0x46).contains(scalar.value)
                      || (0x61...0x66).contains(scalar.value)
              }) else {
            throw malformed("backgroundColor/foregroundColor is not a #RRGGBB swatch")
        }
        return value.uppercased()
    }

    private static func updatedAt(from value: String?) throws -> Date? {
        guard let value else { return nil }
        guard let parsed = CalendarRFC3339.date(from: value) else {
            throw malformed("event.updated is not a parseable RFC3339 instant")
        }
        return parsed
    }

    private static func eventTime(from wire: CalendarWireEventTime) throws -> ParsedEventTime {
        if let date = wire.date, wire.dateTime == nil, wire.timeZone == nil,
           let parsed = CalendarDateOnly.parse(date) {
            return ParsedEventTime(value: .date(parsed.components), orderingDate: parsed.orderingDate, kind: .date)
        }
        if let dateTime = wire.dateTime, wire.date == nil,
           let instant = CalendarRFC3339.date(from: dateTime) {
            // `timeZone` is OPTIONAL in Google's payload: it is sent only when the event carries
            // an explicitly-set zone, which most ordinary events do not. The RFC3339 string
            // already fixes the instant through its UTC offset, and nothing downstream reads the
            // identifier (`GoogleCalendarSource.instant(from:)` discards it). Requiring it
            // rejected almost every real timed event as `malformedResponse`, which threw out of
            // the whole page and left the calendar surface blank while Mail and Tasks worked.
            //
            // A timeZone that IS present must still be well formed — a malformed one is a
            // genuinely untrustworthy response.
            if let timeZone = wire.timeZone {
                guard timeZone.utf8.count <= 128, TimeZone(identifier: timeZone) != nil else {
                    throw malformed("event time has an unrecognised timeZone identifier")
                }
            }
            return ParsedEventTime(
                value: .dateTime(instant, timeZoneIdentifier: wire.timeZone),
                orderingDate: instant,
                kind: .dateTime
            )
        }
        throw malformed("event time is neither a usable date nor dateTime")
    }

    private static func decode<T: Decodable>(_ type: T.Type, from response: GoogleHTTPResponse) throws -> T {
        guard (200...299).contains(response.statusCode) else {
            throw GoogleCalendarReadClientError.providerUnavailable
        }
        do {
            return try JSONDecoder().decode(type, from: response.data)
        } catch let error as DecodingError {
            // Only the coding path is logged — those are schema field names from our own wire
            // structs, never decoded values.
            let path = codingPath(of: error).joined(separator: ".")
            CalendarDiagnostics.log.error(
                "calendar decode rejected: JSON did not match the wire shape at \(path, privacy: .public)"
            )
            throw GoogleCalendarReadClientError.malformedResponse
        } catch {
            throw malformed("response body was not decodable JSON")
        }
    }
}

private struct ParsedEventTime {
    enum Kind { case date, dateTime }
    let value: GoogleEventTime
    let orderingDate: Date
    let kind: Kind
}

private enum CalendarDateOnly {
    static func parse(_ value: String) -> (components: DateComponents, orderingDate: Date)? {
        guard value.utf8.count == 10 else { return nil }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var dated = DateComponents()
        dated.calendar = calendar
        dated.timeZone = calendar.timeZone
        dated.year = year
        dated.month = month
        dated.day = day
        dated.hour = 12
        guard let orderingDate = calendar.date(from: dated),
              calendar.dateComponents([.year, .month, .day], from: orderingDate)
                == DateComponents(year: year, month: month, day: day) else {
            return nil
        }
        return (DateComponents(year: year, month: month, day: day), orderingDate)
    }
}

private enum CalendarRFC3339 {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(from value: String) -> Date? {
        guard value.utf8.count <= 64,
              value.range(
                  of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"#,
                  options: .regularExpression
              ) != nil else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private func mapCalendarError(_ error: any Error) -> GoogleCalendarReadClientError {
    if let error = error as? GoogleCalendarReadClientError { return error }
    if error is CancellationError { return .cancelled }
    if let error = error as? GoogleHTTPTransportError {
        switch error {
        case .cancelled: return .cancelled
        case .requestFailed: return .offline
        case .nonHTTPResponse: return .providerUnavailable
        }
    }
    // Anything else is reported to the caller as `malformedResponse`, which reads like a bad
    // payload from Google when it may be nothing of the sort — a policy refusal or a token
    // failure lands here too. Name the type so the label cannot mislead a future reader. Type
    // only: a foreign error (URLError/NSError) can carry a failing URL in its description.
    CalendarDiagnostics.log.error(
        "calendar request failed with an unmapped error type: \(String(describing: type(of: error)), privacy: .public)"
    )
    return .malformedResponse
}


/// The field path a `DecodingError` occurred at, as schema key names only. Index positions are
/// rendered as `[n]` so a failing element can be located without logging any decoded value.
private func codingPath(of error: DecodingError) -> [String] {
    let context: DecodingError.Context
    switch error {
    case let .typeMismatch(_, ctx), let .valueNotFound(_, ctx),
         let .keyNotFound(_, ctx), let .dataCorrupted(ctx):
        context = ctx
    @unknown default:
        return ["unknown"]
    }
    var path = context.codingPath.map { $0.intValue.map { i in "[\(i)]" } ?? $0.stringValue }
    if case let .keyNotFound(key, _) = error { path.append("\(key.stringValue) (missing)") }
    if case .valueNotFound = error { path.append("(null)") }
    return path.isEmpty ? ["<root>"] : path
}
