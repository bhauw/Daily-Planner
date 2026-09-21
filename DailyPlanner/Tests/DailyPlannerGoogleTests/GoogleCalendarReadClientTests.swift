import DailyPlannerDomain
import Foundation
import XCTest
@testable import DailyPlannerGoogle

final class GoogleCalendarReadClientTests: XCTestCase {
    func testTimedEventWithoutAnExplicitTimeZoneDecodes() async throws {
        // THE bug that left the calendar blank on real data. Google sends `timeZone` only when an
        // event carries an explicitly-set zone; an ordinary timed event is just
        // {"dateTime": "...-07:00"}. The decoder required `timeZone`, so almost every real event
        // failed as `malformedResponse` and threw out of the entire page — Mail and Tasks
        // rendered while the whole day showed "Couldn't load your day".
        let page = eventPageJSON(items: [
            eventItem(
                id: "no-zone",
                start: ["dateTime": "2026-09-10T09:00:00-07:00"],
                end: ["dateTime": "2026-09-10T10:00:00-07:00"]
            ),
        ])

        let decoded = try await CalendarHarness(events: page).events()

        XCTAssertEqual(decoded.events.map(\.id), [try GoogleCalendarEventID(validating: "no-zone")])
        // -07:00 means the instant is 16:00Z, and the identifier is absent because the provider
        // sent none — not defaulted to something that was never declared.
        let expected = ISO8601DateFormatter().date(from: "2026-09-10T16:00:00Z")
        XCTAssertEqual(decoded.events.first?.start, .dateTime(try XCTUnwrap(expected), timeZoneIdentifier: nil))
    }

    func testPresentButMalformedTimeZoneIsStillRejected() async throws {
        // Making the field optional must not make a malformed one acceptable. The event is still
        // rejected — it is now dropped on its own rather than failing the whole page.
        let harness = CalendarHarness(events: eventPageJSON(items: [
            eventItem(id: "good"),
            eventItem(
                id: "bad-zone",
                start: ["dateTime": "2026-09-10T09:00:00-07:00", "timeZone": "Not/AZone"],
                end: ["dateTime": "2026-09-10T10:00:00-07:00"]
            ),
        ]))
        let page = try await harness.events()
        XCTAssertEqual(page.events.map(\.id), [try GoogleCalendarEventID(validating: "good")])
    }

    func testZeroDurationTimedEventIsLegalRatherThanMalformed() async throws {
        // Google permits start == end for a timed event (a point-in-time marker, the shape
        // Canvas-style "due at" entries take). The decoder required a strictly increasing range.
        let page = eventPageJSON(items: [
            eventItem(
                id: "zero-length",
                start: ["dateTime": "2026-09-10T17:00:00Z"],
                end: ["dateTime": "2026-09-10T17:00:00Z"]
            ),
        ])

        let decoded = try await CalendarHarness(events: page).events()

        XCTAssertEqual(decoded.events.map(\.id), [try GoogleCalendarEventID(validating: "zero-length")])
        XCTAssertEqual(decoded.events.first?.start, decoded.events.first?.end)
    }

    func testTimedEventWithEndBeforeStartIsStillRejected() async throws {
        // Loosening `<` to `<=` for timed events must not let a genuinely backwards range
        // through. Still rejected — now as a dropped event rather than a failed page.
        let harness = CalendarHarness(events: eventPageJSON(items: [
            eventItem(id: "good"),
            eventItem(
                id: "backwards",
                start: ["dateTime": "2026-09-10T18:00:00Z"],
                end: ["dateTime": "2026-09-10T17:00:00Z"]
            ),
        ]))
        let page = try await harness.events()
        XCTAssertEqual(page.events.map(\.id), [try GoogleCalendarEventID(validating: "good")])
    }

    func testPrimaryCalendarRequiresExactlyOneProviderPrimaryRecord() async throws {
        let one = CalendarHarness(calendarList: fixture("calendar-list"))
        let primary = try await one.client.primaryCalendar(accessToken: one.token)

        XCTAssertTrue(primary.isPrimary)
        XCTAssertEqual(primary.id, CalendarID(rawValue: "primary@example.test"))
        XCTAssertEqual(one.query["minAccessRole"], ["reader"])
        XCTAssertEqual(one.query["showDeleted"], ["false"])
        XCTAssertEqual(one.query["maxResults"], ["100"])

        for (invalid, expected) in [
            (CalendarHarness(noPrimary: true), GoogleCalendarReadClientError.missingPrimary),
            (CalendarHarness(duplicatePrimary: true), GoogleCalendarReadClientError.duplicatePrimary),
        ] {
            await assertFiniteError(invalid.primaryOperation(), expected: expected)
        }
    }

    func testPrimarySelectionNeverUsesDisplayNameAndRequiresReadableDeclaredRoles() async throws {
        let namedPrimary = calendarListJSON(items: [
            calendarItem(id: "named-primary", summary: "Primary", primary: false, accessRole: "reader"),
        ])
        await assertFiniteError(CalendarHarness(calendarList: namedPrimary).primaryOperation(), expected: .missingPrimary)

        for role in [nil, "freeBusyReader", "invalid"] {
            let response = calendarListJSON(items: [
                calendarItem(id: "primary-id", summary: "Personal", primary: true, accessRole: role),
            ])
            await assertFiniteError(CalendarHarness(calendarList: response).primaryOperation(), expected: .malformedResponse)
        }
    }

    func testCalendarListPaginationIsStableBoundedAndRejectsMalformedIDsAndTokens() async throws {
        let paged = CalendarHarness(results: [
            .response(data: calendarListJSON(
                items: [calendarItem(id: "reference", primary: false)], nextPageToken: "page-2"
            )),
            .response(data: calendarListJSON(items: [calendarItem(id: "primary-id", primary: true)])),
        ])
        let selected = try await paged.client.primaryCalendar(accessToken: paged.token)
        XCTAssertEqual(selected.id, CalendarID(rawValue: "primary-id"))
        XCTAssertEqual(paged.sendCount, 2)
        XCTAssertNil(paged.queries[0]["pageToken"])
        XCTAssertEqual(paged.queries[1]["pageToken"], ["page-2"])
        XCTAssertEqual(removingPageToken(paged.queries[0]), removingPageToken(paged.queries[1]))

        for response in [
            calendarListJSON(items: [calendarItem(id: "", primary: true)]),
            calendarListJSON(items: [calendarItem(id: "unsafe/id", primary: true)]),
            calendarListJSON(items: [], nextPageToken: ""),
            calendarListJSON(items: [], nextPageToken: String(repeating: "x", count: 4_097)),
        ] {
            await assertFiniteError(CalendarHarness(calendarList: response).primaryOperation(), expected: .malformedResponse)
        }

        var boundedResults: [CalendarHarness.Result] = (1...10).map { index in
            .response(data: calendarListJSON(items: [], nextPageToken: "page-\(index + 1)"))
        }
        boundedResults.append(.response(data: calendarListJSON(items: [calendarItem(id: "primary", primary: true)])))
        let bounded = CalendarHarness(results: boundedResults)
        await assertFiniteError(bounded.primaryOperation(), expected: .limitViolation)
        XCTAssertEqual(bounded.sendCount, 10)
    }

    func testCalendarListDecodesColoursAndKeepsSecondaryCalendarsAlongsidePrimary() async throws {
        let harness = CalendarHarness(calendarList: calendarListJSON(items: [
            calendarItem(
                id: "primary-id", summary: "Personal", primary: true,
                colorId: "7", backgroundColor: "#039be5", foregroundColor: "#ffffff"
            ),
            calendarItem(
                id: "reference-id", summary: "Reference", primary: false, accessRole: "reader",
                colorId: "24", backgroundColor: "#616161", foregroundColor: "#000000"
            ),
        ]))
        let calendars = try await harness.allCalendars()

        // The secondary calendar is no longer dropped: both survive so its colour is visible.
        XCTAssertEqual(calendars.count, 2)
        let secondary = try XCTUnwrap(calendars.first { $0.id == CalendarID(rawValue: "reference-id") })
        XCTAssertFalse(secondary.isPrimary)
        XCTAssertEqual(secondary.colorId, "24")
        // Hex swatches are decoded and normalised to uppercase.
        XCTAssertEqual(secondary.backgroundColor, "#616161")
        XCTAssertEqual(secondary.foregroundColor, "#000000")
        let primary = try XCTUnwrap(calendars.first(where: \.isPrimary))
        XCTAssertEqual(primary.colorId, "7")
        XCTAssertEqual(primary.backgroundColor, "#039BE5")
    }

    func testCalendarListRejectsMalformedColourFieldsThroughFinitePath() async {
        for item in [
            calendarItem(id: "c", primary: true, colorId: "12a"),
            calendarItem(id: "c", primary: true, colorId: "9999"),
            calendarItem(id: "c", primary: true, backgroundColor: "039be5"),
            calendarItem(id: "c", primary: true, backgroundColor: "#039be"),
            calendarItem(id: "c", primary: true, foregroundColor: "#zzzzzz"),
        ] {
            let harness = CalendarHarness(calendarList: calendarListJSON(items: [item]))
            await assertFiniteError(
                { _ = try await harness.allCalendars() }, expected: .malformedResponse
            )
        }
    }

    func testEventsDecodeColorIdAndLeaveItNilToInheritCalendarColour() async throws {
        let harness = CalendarHarness(events: eventPageJSON(items: [
            eventItem(id: "with-colour", colorId: "11"),
            eventItem(id: "no-colour"),
        ]))
        let page = try await harness.events()
        XCTAssertEqual(page.events[0].colorId, "11")
        // No event colour → nil, meaning it inherits its calendar's colour (resolved by
        // GoogleColorCategory.effectiveColorID), never a silent default.
        XCTAssertNil(page.events[1].colorId)

        // A present-but-malformed event colour still fails closed — that one event is dropped.
        let withBadColour = CalendarHarness(events: eventPageJSON(items: [
            eventItem(id: "good"), eventItem(id: "bad-colour", colorId: "1x"),
        ]))
        let filtered = try await withBadColour.events()
        XCTAssertEqual(filtered.events.map(\.id), [try GoogleCalendarEventID(validating: "good")])
    }

    func testEventsPreserveTimesAndDecodeMinimalCancellationTombstoneForDeletion() async throws {
        let harness = CalendarHarness(events: fixture("calendar-events"))
        let page = try await harness.events()

        XCTAssertEqual(page.events.count, 4)
        XCTAssertEqual(page.nextSyncToken, try CalendarSyncToken(validating: "opaque-sync"))
        XCTAssertEqual(page.events[0].start, .date(DateComponents(year: 2026, month: 9, day: 10)))
        XCTAssertEqual(page.events[0].end, .date(DateComponents(year: 2026, month: 9, day: 11)))
        XCTAssertEqual(page.events[1].start, .dateTime(
            try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-10T16:30:00Z")),
            timeZoneIdentifier: "America/Vancouver"
        ))
        XCTAssertEqual(page.events[1].status, .tentative)
        XCTAssertEqual(page.events[2].id, try GoogleCalendarEventID(validating: "instance-1"))
        XCTAssertEqual(page.events[2].status, .cancelled)
        XCTAssertEqual(page.events[2].calendarID, harness.calendarID)
        XCTAssertEqual(page.events[3].id, try GoogleCalendarEventID(validating: "deleted-tombstone-1"))
        XCTAssertEqual(page.events[3].status, .cancelled)
        XCTAssertNil(page.events[3].start)
        XCTAssertNil(page.events[3].end)
        XCTAssertNil(page.events[3].updatedAt)
        XCTAssertEqual(harness.sendCount, 1)
    }

    func testEventsRejectMissingMixedReversedAndMalformedEndpoints() async {
        let validDate = ["date": "2026-09-10"]
        let laterDate = ["date": "2026-09-11"]
        let validInstant = ["dateTime": "2026-09-10T09:00:00-07:00", "timeZone": "America/Vancouver"]
        let invalidPairs: [([String: String]?, [String: String]?)] = [
            (validDate, nil),
            (validDate, validInstant),
            (laterDate, validDate),
            (validDate, validDate),
            (["date": "2026-02-30"], laterDate),
            (["dateTime": "2026-09-10 09:00:00", "timeZone": "America/Vancouver"], validInstant),
            (["dateTime": "2026-09-10T09:00:00-07:00", "timeZone": "Not/AZone"], validInstant),
            (["date": "2026-09-10", "dateTime": "2026-09-10T09:00:00Z"], laterDate),
        ]
        // These used to assert the whole page failed. A single undecodable event is now dropped
        // instead, so the rest of the day survives — one odd entry must not blank a planner.
        // Each pair is still rejected; the assertion is that it is rejected *alone*.
        for (start, end) in invalidPairs {
            let harness = CalendarHarness(events: eventPageJSON(items: [
                eventItem(id: "good-1", start: validDate, end: laterDate),
                eventItem(id: "bad-1", start: start, end: end),
            ]))
            let page = try! await harness.events()
            XCTAssertEqual(
                page.events.map(\.id), [try! GoogleCalendarEventID(validating: "good-1")],
                "the undecodable event must be dropped and the readable one kept"
            )
        }
    }

    /// Page-level invariants still fail the whole page: they say the *response* cannot be
    /// trusted, not that one row in it is odd.
    func testEventsRejectMalformedPageInvariants() async {
        for response in [
            eventPageJSON(items: [], nextPageToken: ""),
            eventPageJSON(items: [], nextSyncToken: ""),
            eventPageJSON(items: [], nextPageToken: "next", nextSyncToken: "sync"),
            eventPageJSON(items: Array(repeating: eventItem(), count: 101)),
        ] {
            await assertFiniteError(CalendarHarness(events: response).eventsOperation())
        }
    }

    /// A bad id or an unknown status is a property of one event, so it costs only that event.
    func testEventsDropIndividuallyUnreadableEventsAndKeepTheRest() async throws {
        for bad in [eventItem(id: ""), eventItem(id: "unsafe/id"), eventItem(status: "deleted")] {
            let harness = CalendarHarness(events: eventPageJSON(items: [
                eventItem(id: "good-1"), bad,
            ]))
            let page = try await harness.events()
            XCTAssertEqual(page.events.map(\.id), [try GoogleCalendarEventID(validating: "good-1")])
        }
    }

    func testEventsQueriesStayStableAcrossPageAndSyncTokensAndEncodeCalendarIDAsOneSegment() async throws {
        let initial = CalendarHarness(events: eventPageJSON(items: []), calendarID: CalendarID(rawValue: "team#one@example.test"))
        _ = try await initial.events(pageToken: try CalendarPageToken(validating: "next-page"))
        XCTAssertEqual(initial.request.url?.path, "/calendar/v3/calendars/team#one@example.test/events")
        let encodedPath = URLComponents(url: initial.request.url!, resolvingAgainstBaseURL: false)!.percentEncodedPath
        XCTAssertTrue(encodedPath.contains("team%23one@example.test"))
        XCTAssertEqual(initial.query["singleEvents"], ["true"])
        XCTAssertEqual(initial.query["showDeleted"], ["true"])
        XCTAssertEqual(initial.query["maxResults"], ["100"])
        XCTAssertEqual(initial.query["pageToken"], ["next-page"])
        XCTAssertNotNil(initial.query["timeMin"])
        XCTAssertNotNil(initial.query["timeMax"])

        let incremental = CalendarHarness(events: eventPageJSON(items: []))
        _ = try await incremental.events(
            syncToken: try CalendarSyncToken(validating: "opaque-sync"),
            pageToken: try CalendarPageToken(validating: "next-page")
        )
        XCTAssertEqual(incremental.query["syncToken"], ["opaque-sync"])
        XCTAssertEqual(incremental.query["pageToken"], ["next-page"])
        XCTAssertNil(incremental.query["timeMin"])
        XCTAssertNil(incremental.query["timeMax"])
        for key in ["singleEvents", "showDeleted", "maxResults"] {
            XCTAssertEqual(incremental.query[key], initial.query[key])
        }
        XCTAssertEqual(initial.sendCount, 1)
        XCTAssertEqual(incremental.sendCount, 1)
    }

    func testEventsRejectInvalidRequestedIntervalsAndOpaqueRequestValuesBeforeTransport() async {
        let empty = CalendarHarness(events: eventPageJSON(items: []))
        await assertFiniteError(
            empty.eventsOperation(interval: DateInterval(start: empty.interval.start, duration: 0)),
            expected: .malformedResponse
        )
        XCTAssertEqual(empty.sendCount, 0)

        for calendarID in [CalendarID(rawValue: ""), CalendarID(rawValue: "unsafe/id")] {
            let harness = CalendarHarness(events: eventPageJSON(items: []), calendarID: calendarID)
            await assertFiniteError(harness.eventsOperation(), expected: .malformedResponse)
            XCTAssertEqual(harness.sendCount, 0)
        }
    }

    func testEventsHTTP410MapsExactlyToExpiredSyncTokenAfterOneRequest() async {
        let harness = CalendarHarness(results: [.response(status: 410, data: Data())])
        await assertFiniteError(harness.eventsOperation(), expected: .expiredSyncToken)
        XCTAssertEqual(harness.sendCount, 1)
    }

    func testCalendarReadsMapTransportDecodeAndProviderFailuresToFiniteRedactedErrors() async {
        let expected: [(CalendarHarness.Result, GoogleCalendarReadClientError)] = [
            (.failure(CancellationError()), .cancelled),
            (.failure(GoogleHTTPTransportError.cancelled), .cancelled),
            (.failure(GoogleHTTPTransportError.requestFailed), .offline),
            (.failure(GoogleHTTPTransportError.nonHTTPResponse), .providerUnavailable),
            (.response(status: 503, data: Data()), .providerUnavailable),
            (.response(data: Data("not-json".utf8)), .malformedResponse),
        ]
        for (result, expectedError) in expected {
            let harness = CalendarHarness(results: [result])
            await assertFiniteError(harness.eventsOperation(), expected: expectedError)
            XCTAssertEqual(harness.sendCount, 1)
            XCTAssertFalse(String(describing: expectedError).contains("not-json"))
        }
    }

    private func assertFiniteError(
        _ operation: @escaping @Sendable () async throws -> Void,
        expected: GoogleCalendarReadClientError? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("expected finite calendar client error", file: file, line: line)
        } catch let error as GoogleCalendarReadClientError {
            if let expected { XCTAssertEqual(error, expected, file: file, line: line) }
        } catch {
            XCTFail("raw error escaped the calendar client", file: file, line: line)
        }
    }
}

private final class CalendarHarness: @unchecked Sendable {
    enum Result: @unchecked Sendable {
        case response(status: Int = 200, data: Data)
        case failure(any Error)
    }

    final class Transport: GoogleHTTPTransport, @unchecked Sendable {
        private var results: [Result]
        private(set) var requests: [URLRequest] = []

        init(results: [Result]) { self.results = results }

        func send(_ request: URLRequest) async throws -> GoogleHTTPResponse {
            requests.append(request)
            let result = results.removeFirst()
            switch result {
            case let .response(status, data): return GoogleHTTPResponse(statusCode: status, data: data)
            case let .failure(error): throw error
            }
        }
    }

    let token = try! GoogleAccessToken(validating: "synthetic-access-token")
    let calendarID: CalendarID
    let interval = DateInterval(
        start: Date(timeIntervalSince1970: 1_789_027_200),
        end: Date(timeIntervalSince1970: 1_789_632_000)
    )
    let transport: Transport
    let client: GoogleCalendarReadClient

    convenience init(calendarList: Data) { self.init(results: [.response(data: calendarList)]) }
    convenience init(events: Data, calendarID: CalendarID = CalendarID(rawValue: "primary@example.test")) {
        self.init(results: [.response(data: events)], calendarID: calendarID)
    }
    convenience init(noPrimary: Bool) {
        self.init(calendarList: calendarListJSON(items: [calendarItem(id: "only", primary: !noPrimary)]))
    }
    convenience init(duplicatePrimary: Bool) {
        self.init(calendarList: calendarListJSON(items: [
            calendarItem(id: "one", primary: true),
            calendarItem(id: "two", primary: duplicatePrimary),
        ]))
    }
    init(results: [Result], calendarID: CalendarID = CalendarID(rawValue: "primary@example.test")) {
        self.calendarID = calendarID
        transport = Transport(results: results)
        client = GoogleCalendarReadClient(transport: transport)
    }

    var request: URLRequest { transport.requests.last! }
    var sendCount: Int { transport.requests.count }
    var queries: [[String: [String]]] { transport.requests.map(requestQuery(from:)) }
    var query: [String: [String]] { requestQuery(from: request) }

    func events(
        interval: DateInterval? = nil,
        syncToken: CalendarSyncToken? = nil,
        pageToken: CalendarPageToken? = nil
    ) async throws -> CalendarEventPage {
        try await client.events(
            calendarID: calendarID,
            interval: interval ?? self.interval,
            syncToken: syncToken,
            pageToken: pageToken,
            accessToken: token
        )
    }

    func eventsOperation(interval: DateInterval? = nil) -> @Sendable () async throws -> Void {
        { _ = try await self.events(interval: interval) }
    }

    func primaryOperation() -> @Sendable () async throws -> Void {
        { _ = try await self.client.primaryCalendar(accessToken: self.token) }
    }

    func allCalendars() async throws -> [GoogleCalendarRecord] {
        try await client.calendars(accessToken: token)
    }
}

private func fixture(_ name: String) -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "json")!
    return try! Data(contentsOf: url)
}

private func requestQuery(from request: URLRequest) -> [String: [String]] {
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
    return Dictionary(grouping: items, by: \.name).mapValues { $0.compactMap(\.value) }
}

private func removingPageToken(_ query: [String: [String]]) -> [String: [String]] {
    query.filter { $0.key != "pageToken" }
}

private func calendarItem(
    id: String,
    summary: String = "Calendar",
    primary: Bool,
    accessRole: String? = "owner",
    colorId: String? = nil,
    backgroundColor: String? = nil,
    foregroundColor: String? = nil
) -> [String: Any] {
    var item: [String: Any] = ["id": id, "summary": summary, "primary": primary]
    if let accessRole { item["accessRole"] = accessRole }
    if let colorId { item["colorId"] = colorId }
    if let backgroundColor { item["backgroundColor"] = backgroundColor }
    if let foregroundColor { item["foregroundColor"] = foregroundColor }
    return item
}

private func calendarListJSON(items: [[String: Any]], nextPageToken: String? = nil) -> Data {
    var object: [String: Any] = ["items": items]
    if let nextPageToken { object["nextPageToken"] = nextPageToken }
    return try! JSONSerialization.data(withJSONObject: object)
}

private func eventItem(
    id: String = "event-1",
    start: [String: String]? = ["date": "2026-09-10"],
    end: [String: String]? = ["date": "2026-09-11"],
    status: String = "confirmed",
    colorId: String? = nil
) -> [String: Any] {
    var item: [String: Any] = [
        "id": id,
        "summary": "Event",
        "status": status,
        "updated": "2026-09-01T12:00:00Z",
    ]
    if let start { item["start"] = start }
    if let end { item["end"] = end }
    if let colorId { item["colorId"] = colorId }
    return item
}

private func eventPageJSON(
    items: [[String: Any]],
    nextPageToken: String? = nil,
    nextSyncToken: String? = nil
) -> Data {
    var object: [String: Any] = ["items": items]
    if let nextPageToken { object["nextPageToken"] = nextPageToken }
    if let nextSyncToken { object["nextSyncToken"] = nextSyncToken }
    return try! JSONSerialization.data(withJSONObject: object)
}
