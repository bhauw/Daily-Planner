import XCTest
import DailyPlannerDomain
@testable import DailyPlannerGoogle

/// Drives the REAL `GoogleCalendarReadClient` — not a pre-decoded page — through
/// `GoogleCalendarSource`, over payloads shaped the way Google actually answers.
///
/// This is the seam that was missing. `GoogleCalendarReadClientTests` exercises the decoder
/// against hand-built fixtures, and `GoogleCalendarSourceTests` hands the source
/// `CalendarEventPage` values that are already decoded — so nothing connected the two, and a
/// decoder that rejected ordinary provider payloads passed both suites while the shipped app
/// showed an empty calendar. Every event below is a shape a real account returns.
final class GoogleCalendarPipelineTests: XCTestCase {
    private let calendarID = CalendarID(rawValue: "calendar@example.test")

    private struct FakeTokens: GoogleAccessTokenProviding {
        func accessToken() async throws -> GoogleAccessToken {
            try GoogleAccessToken(validating: "test-token")
        }
    }

    private struct FakeColors: GoogleColorsReading {
        func palette(accessToken: GoogleAccessToken) async throws -> GoogleColorPalette { .empty }
    }

    private final class Transport: GoogleHTTPTransport, @unchecked Sendable {
        private var responses: [Data]
        init(_ responses: [Data]) { self.responses = responses }
        func send(_ request: URLRequest) async throws -> GoogleHTTPResponse {
            GoogleHTTPResponse(statusCode: 200, data: responses.removeFirst())
        }
    }

    private func source(_ responses: [Data]) -> GoogleCalendarSource {
        GoogleCalendarSource(
            calendarClient: GoogleCalendarReadClient(transport: Transport(responses)),
            colorsClient: FakeColors(),
            tokens: FakeTokens(),
            colorMapping: [:]
        )
    }

    private var day: DateInterval {
        let start = ISO8601DateFormatter().date(from: "2026-09-16T07:00:00Z")!
        return DateInterval(start: start, duration: 24 * 60 * 60)
    }

    func testOrdinaryProviderPayloadReachesThePlanAsRealEvents() async throws {
        // A calendar list answer, then one page of events. The timed entries deliberately carry
        // NO `timeZone`: that is what Google sends unless an event has an explicitly-set zone,
        // and requiring it was what emptied the calendar.
        let calendars = json([
            "items": [
                ["id": "calendar@example.test", "summary": "calendar@example.test",
                 "primary": true, "accessRole": "owner"],
            ],
        ])
        let events = json([
            "items": [
                ["id": "standup", "summary": "Standup", "status": "confirmed",
                 "updated": "2026-09-15T12:00:00Z",
                 "start": ["dateTime": "2026-09-16T09:00:00-07:00"],
                 "end": ["dateTime": "2026-09-16T09:30:00-07:00"]],
                ["id": "zoned", "summary": "Zoned meeting", "status": "confirmed",
                 "updated": "2026-09-15T12:00:00Z",
                 "start": ["dateTime": "2026-09-16T13:00:00-07:00", "timeZone": "America/Vancouver"],
                 "end": ["dateTime": "2026-09-16T14:00:00-07:00", "timeZone": "America/Vancouver"]],
                ["id": "due-marker", "summary": "Assignment due", "status": "confirmed",
                 "updated": "2026-09-15T12:00:00Z",
                 "start": ["dateTime": "2026-09-16T23:59:00-07:00"],
                 "end": ["dateTime": "2026-09-16T23:59:00-07:00"]],
                ["id": "all-day", "summary": "Reading break", "status": "confirmed",
                 "updated": "2026-09-15T12:00:00Z",
                 "start": ["date": "2026-09-16"], "end": ["date": "2026-09-17"]],
                ["id": "gone", "summary": "Cancelled thing", "status": "cancelled",
                 "updated": "2026-09-15T12:00:00Z"],
            ],
        ])

        let events2 = try await source([calendars, events]).planningEvents(
            calendarIDs: [calendarID], interval: day
        )

        // The cancelled entry is dropped; everything else survives the round trip.
        XCTAssertEqual(
            Set(events2.map(\.title)),
            ["Standup", "Zoned meeting", "Assignment due", "Reading break"]
        )
        XCTAssertFalse(events2.contains { $0.title == "Cancelled thing" })
        XCTAssertTrue(
            events2.allSatisfy { $0.calendarID == self.calendarID },
            "every event must carry the calendar it came from"
        )
    }

    func testAPageThatDecodesToNothingIsAnEmptyDayRatherThanAFailure() async throws {
        let calendars = json(["items": [
            ["id": "calendar@example.test", "summary": "cal", "primary": true, "accessRole": "owner"],
        ]])
        let events = json(["items": []])

        let decoded = try await source([calendars, events]).planningEvents(
            calendarIDs: [calendarID], interval: day
        )

        XCTAssertTrue(decoded.isEmpty)
    }

    /// Google's `nextSyncToken` is an opaque base64-style string and routinely carries `=`
    /// padding. `isSafeToken` rejected `=` outright, so the decoder threw `malformedResponse`
    /// on Google's own valid answer — and because `page(from:)` reads `nextSyncToken` even when
    /// no sync token was sent, this failed on the very first request, emptying the whole day.
    ///
    /// Every existing fixture used a hand-picked token like "opaque-sync" that happens to
    /// contain no padding, which is why the suite stayed green while the real account failed.
    func testAPaddedSyncTokenIsAcceptedBecauseThatIsWhatGoogleSends() async throws {
        let calendars = json(["items": [
            ["id": "calendar@example.test", "summary": "cal", "primary": true, "accessRole": "owner"],
        ]])
        let events = json([
            "items": [[
                "id": "evt-1",
                "status": "confirmed",
                "summary": "Real event",
                "updated": "2026-09-16T10:00:00.000Z",
                "start": ["dateTime": "2026-09-16T09:00:00-07:00"],
                "end": ["dateTime": "2026-09-16T10:00:00-07:00"],
            ]],
            "nextSyncToken": "CPjJi8yF2fMCEPjJi8yF2fMCGAUgtc_QoQI=",
        ])

        let decoded = try await source([calendars, events]).planningEvents(
            calendarIDs: [calendarID], interval: day
        )

        XCTAssertEqual(decoded.count, 1, "a padded sync token must not empty the day")
    }

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}
