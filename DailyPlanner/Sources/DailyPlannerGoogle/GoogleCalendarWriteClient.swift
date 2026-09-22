import DailyPlannerDomain
import Foundation

public enum GoogleCalendarWriteClientError: Error, Equatable, CaseIterable, Sendable {
    case cancelled
    case offline
    case refused
    case providerUnavailable
    case malformedResponse
}

/// Creates one event through `POST /calendar/v3/calendars/{id}/events`, and moves an existing
/// one through `PATCH /calendar/v3/calendars/{id}/events/{eventId}`.
///
/// Insert and move. There is still no delete here, and no `sendUpdates` parameter — mailing an
/// event's attendees is a separate decision and `GoogleNetworkPolicy` refuses any query on a
/// write, so it cannot be reached from this path even by mistake.
///
/// The move is a PATCH carrying `start` and `end` and nothing else. Google applies a patch
/// field by field, so everything this app does not know about the event — its guests, its
/// description, its recurrence, its colour — survives untouched precisely because the body
/// never mentions them.
public struct GoogleCalendarWriteClient: Sendable {
    public let transport: any GoogleHTTPTransport

    public init(transport: any GoogleHTTPTransport) {
        self.transport = transport
    }

    public func create(
        _ draft: PlannerEventDraft,
        accessToken: GoogleAccessToken
    ) async throws -> PlannerScheduledEvent {
        do {
            try Task.checkCancellation()
            let url = try Self.insertURL(calendarID: draft.calendarID)
            let body = try Self.requestBody(for: draft)
            let request = try GoogleRequestBuilder.postJSON(
                url: url, accessToken: accessToken, body: body
            )
            let response = try await transport.send(request)
            switch response.statusCode {
            case 200...299:
                return try Self.decode(response.data, fallback: draft)
            case 400, 401, 403, 404, 409, 429:
                throw GoogleCalendarWriteClientError.refused
            default:
                throw GoogleCalendarWriteClientError.providerUnavailable
            }
        } catch {
            throw Self.map(error)
        }
    }

    public func move(
        _ move: PlannerEventMove,
        accessToken: GoogleAccessToken
    ) async throws -> PlannerScheduledEvent {
        do {
            try Task.checkCancellation()
            let url = try Self.patchURL(calendarID: move.calendarID, eventID: move.eventID)
            let body = try Self.requestBody(for: move)
            let request = try GoogleRequestBuilder.patchJSON(
                url: url, accessToken: accessToken, body: body
            )
            let response = try await transport.send(request)
            switch response.statusCode {
            case 200...299:
                return try Self.decode(response.data, fallback: move)
            case 400, 401, 403, 404, 409, 429:
                throw GoogleCalendarWriteClientError.refused
            default:
                throw GoogleCalendarWriteClientError.providerUnavailable
            }
        } catch {
            throw Self.map(error)
        }
    }

    /// `primary` when no calendar was named — the account's own calendar, which is the one a
    /// planner should write to by default.
    static func insertURL(calendarID: CalendarID?) throws -> URL {
        let segment = try encodedPathSegment(calendarID?.rawValue ?? "primary")
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.googleapis.com"
        components.percentEncodedPath = "/calendar/v3/calendars/\(segment)/events"
        guard let url = components.url else { throw GoogleCalendarWriteClientError.malformedResponse }
        return url
    }

    /// Unlike the insert URL there is no `primary` fallback: a move names the calendar the
    /// event is actually on, because patching an id against the wrong calendar is not a
    /// harmless miss.
    static func patchURL(calendarID: CalendarID, eventID: String) throws -> URL {
        let calendar = try encodedPathSegment(calendarID.rawValue)
        let event = try encodedPathSegment(eventID)
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.googleapis.com"
        components.percentEncodedPath = "/calendar/v3/calendars/\(calendar)/events/\(event)"
        guard let url = components.url else { throw GoogleCalendarWriteClientError.malformedResponse }
        return url
    }

    static func encodedPathSegment(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 1_024, value != ".", value != ".." else {
            throw GoogleCalendarWriteClientError.malformedResponse
        }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%\\")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed),
              !encoded.isEmpty, !encoded.contains("%") else {
            // A calendar id needing percent-encoding is one the network policy would refuse
            // anyway, so it fails here rather than being reshaped into something that passes.
            throw GoogleCalendarWriteClientError.malformedResponse
        }
        return encoded
    }

    static func requestBody(for draft: PlannerEventDraft) throws -> Data {
        var payload: [String: Any] = [
            "summary": draft.title,
            "start": ["dateTime": RFC3339.string(from: draft.start)],
            "end": ["dateTime": RFC3339.string(from: draft.end)],
        ]
        if let location = draft.location { payload["location"] = location }
        if let notes = draft.notes { payload["description"] = notes }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            throw GoogleCalendarWriteClientError.malformedResponse
        }
        return data
    }

    /// Two keys, and only two. A patch body is a list of the fields to change, so the shortness
    /// of this function is the safety property, not an omission to be filled in later.
    static func requestBody(for move: PlannerEventMove) throws -> Data {
        let payload: [String: Any] = [
            "start": ["dateTime": RFC3339.string(from: move.start)],
            "end": ["dateTime": RFC3339.string(from: move.end)],
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            throw GoogleCalendarWriteClientError.malformedResponse
        }
        return data
    }

    private struct Wire: Decodable {
        struct Stamp: Decodable { let dateTime: String? }
        let id: String
        let htmlLink: String?
        let start: Stamp?
        let end: Stamp?
    }

    /// Google echoes the times it stored. They are preferred over the requested ones — if the
    /// provider moved anything, the user should be told what is actually on their calendar —
    /// and the draft's own times are the fallback when the echo is absent or unparseable.
    static func decode(_ data: Data, fallback draft: PlannerEventDraft) throws -> PlannerScheduledEvent {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data), !wire.id.isEmpty else {
            throw GoogleCalendarWriteClientError.malformedResponse
        }
        return PlannerScheduledEvent(
            id: wire.id,
            start: wire.start?.dateTime.flatMap(RFC3339.date(from:)) ?? draft.start,
            end: wire.end?.dateTime.flatMap(RFC3339.date(from:)) ?? draft.end,
            link: wire.htmlLink
        )
    }

    /// Same rule as the insert: prefer the times Google echoes back over the ones requested,
    /// so the user is told what is actually on their calendar.
    static func decode(_ data: Data, fallback move: PlannerEventMove) throws -> PlannerScheduledEvent {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data), !wire.id.isEmpty else {
            throw GoogleCalendarWriteClientError.malformedResponse
        }
        return PlannerScheduledEvent(
            id: wire.id,
            start: wire.start?.dateTime.flatMap(RFC3339.date(from:)) ?? move.start,
            end: wire.end?.dateTime.flatMap(RFC3339.date(from:)) ?? move.end,
            link: wire.htmlLink
        )
    }

    private static func map(_ error: Error) -> GoogleCalendarWriteClientError {
        switch error {
        case is CancellationError:
            return .cancelled
        case let error as GoogleCalendarWriteClientError:
            return error
        case let error as GoogleHTTPTransportError:
            return error == .cancelled ? .cancelled : .offline
        default:
            return .refused
        }
    }
}

enum RFC3339 {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func date(from value: String) -> Date? {
        guard value.utf8.count <= 64 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: value) { return parsed }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

extension GoogleCalendarWriteClientError: PlannerWriteFailure {
    public var writeOutcome: PlannerWriteOutcome {
        switch self {
        case .cancelled: return .cancelled
        case .refused: return .refused
        // A malformed response means the send may well have happened and we could not read the
        // receipt. It is reported as not-through rather than refused, and it is never retried
        // automatically — a duplicate send is worse than an unclear one.
        case .offline, .providerUnavailable, .malformedResponse: return .unavailable
        }
    }
}
