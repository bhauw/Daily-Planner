import XCTest
import DailyPlannerDomain
@testable import DailyPlannerGoogle

/// Covers the adapter that turns live Google reads into `PlannerEvent`s — the seam that decides
/// what the user actually sees on their day. The rules under test are the ones whose failure
/// would be silent: a cancelled event slipping into the plan, a colour category being invented,
/// or an excluded calendar leaking into planning.
final class GoogleCalendarSourceTests: XCTestCase {
    // MARK: - Fakes

    private struct FakeTokens: GoogleAccessTokenProviding {
        func accessToken() async throws -> GoogleAccessToken {
            try GoogleAccessToken(validating: "test-token")
        }
    }

    private struct FakeColors: GoogleColorsReading {
        var palette: GoogleColorPalette = .empty
        func palette(accessToken: GoogleAccessToken) async throws -> GoogleColorPalette {
            palette
        }
    }

    private struct FakeCalendars: GoogleCalendarReading {
        var records: [GoogleCalendarRecord] = []
        /// Pages keyed in order; each call pops the next one.
        var pages: [CalendarEventPage] = []
        /// Records every page token requested, to prove pagination actually follows them.
        final class Calls: @unchecked Sendable {
            var pageTokens: [CalendarPageToken?] = []
            var eventCallCount = 0
        }
        var calls = Calls()

        func primaryCalendar(accessToken: GoogleAccessToken) async throws -> GoogleCalendarRecord {
            records.first ?? GoogleCalendarRecord(
                id: CalendarID(rawValue: "primary"), displayName: "Primary", isPrimary: true
            )
        }

        func calendars(accessToken: GoogleAccessToken) async throws -> [GoogleCalendarRecord] {
            records
        }

        func events(
            calendarID: CalendarID, interval: DateInterval, syncToken: CalendarSyncToken?,
            pageToken: CalendarPageToken?, accessToken: GoogleAccessToken
        ) async throws -> CalendarEventPage {
            calls.pageTokens.append(pageToken)
            let index = calls.eventCallCount
            calls.eventCallCount += 1
            guard index < pages.count else {
                return CalendarEventPage(events: [], nextPageToken: nil, nextSyncToken: nil)
            }
            return pages[index]
        }
    }

    // MARK: - Helpers

    private let calendarID = CalendarID(rawValue: "cal-1")

    private func interval() -> DateInterval {
        let start = Date(timeIntervalSince1970: 1_757_800_000)
        return DateInterval(start: start, duration: 24 * 60 * 60)
    }

    private func timedRecord(
        id: String,
        colorId: String? = nil,
        status: GoogleEventStatus = .confirmed,
        calendar: CalendarID? = nil
    ) throws -> CalendarEventRecord {
        let start = Date(timeIntervalSince1970: 1_757_800_000)
        return CalendarEventRecord(
            id: try GoogleCalendarEventID(validating: id),
            calendarID: calendar ?? calendarID,
            title: "Event \(id)",
            description: nil,
            location: nil,
            start: .dateTime(start, timeZoneIdentifier: "America/Vancouver"),
            end: .dateTime(start.addingTimeInterval(3600), timeZoneIdentifier: "America/Vancouver"),
            status: status,
            updatedAt: nil,
            privacyClass: .ordinary,
            colorId: colorId
        )
    }

    private func makeSource(
        calendars: FakeCalendars,
        colors: FakeColors = FakeColors(),
        mapping: [String: PlannerCategory] = [:]
    ) -> GoogleCalendarSource {
        GoogleCalendarSource(
            calendarClient: calendars,
            colorsClient: colors,
            tokens: FakeTokens(),
            colorMapping: mapping
        )
    }

    private func page(_ records: [CalendarEventRecord], next: String? = nil) throws
        -> CalendarEventPage
    {
        CalendarEventPage(
            events: records,
            nextPageToken: try next.map { try CalendarPageToken(validating: $0) },
            nextSyncToken: nil
        )
    }

    // MARK: - Tests

    func testCancelledEventsNeverReachThePlan() async throws {
        var fake = FakeCalendars()
        fake.records = [
            GoogleCalendarRecord(id: calendarID, displayName: "Cal", isPrimary: true)
        ]
        fake.pages = [
            try page([
                try timedRecord(id: "live-1"),
                try timedRecord(id: "cancelled-1", status: .cancelled),
            ])
        ]
        let events = try await makeSource(calendars: fake)
            .planningEvents(calendarIDs: [calendarID], interval: interval())

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.id, "live-1")
    }

    func testEventWithoutOwnColourInheritsItsCalendarColour() async throws {
        var fake = FakeCalendars()
        fake.records = [
            GoogleCalendarRecord(
                id: calendarID, displayName: "Cal", isPrimary: true, colorId: "5"
            )
        ]
        fake.pages = [try page([try timedRecord(id: "e1", colorId: nil)])]

        let events = try await makeSource(calendars: fake, mapping: ["5": .finance])
            .planningEvents(calendarIDs: [calendarID], interval: interval())

        XCTAssertEqual(events.first?.category, .finance, "should inherit the calendar's colour")
    }

    func testEventOwnColourOverridesTheCalendarColour() async throws {
        var fake = FakeCalendars()
        fake.records = [
            GoogleCalendarRecord(
                id: calendarID, displayName: "Cal", isPrimary: true, colorId: "5"
            )
        ]
        fake.pages = [try page([try timedRecord(id: "e1", colorId: "9")])]

        let events = try await makeSource(
            calendars: fake, mapping: ["5": .finance, "9": .school]
        ).planningEvents(calendarIDs: [calendarID], interval: interval())

        XCTAssertEqual(events.first?.category, .school, "event colour must win over calendar")
    }

    func testUnmappedColourFallsBackToOtherRatherThanGuessing() async throws {
        var fake = FakeCalendars()
        fake.records = [
            GoogleCalendarRecord(
                id: calendarID, displayName: "Cal", isPrimary: true, colorId: "77"
            )
        ]
        fake.pages = [try page([try timedRecord(id: "e1")])]

        let events = try await makeSource(calendars: fake, mapping: ["5": .finance])
            .planningEvents(calendarIDs: [calendarID], interval: interval())

        XCTAssertEqual(events.first?.category, .other)
    }

    func testAllDayEventBecomesADeadlineNotADayLongBlock() async throws {
        var fake = FakeCalendars()
        fake.records = [
            GoogleCalendarRecord(id: calendarID, displayName: "Cal", isPrimary: true)
        ]
        let allDay = CalendarEventRecord(
            id: try GoogleCalendarEventID(validating: "all-day-1"),
            calendarID: calendarID,
            title: "Essay due",
            description: nil,
            location: nil,
            start: .date(DateComponents(year: 2026, month: 9, day: 14)),
            end: .date(DateComponents(year: 2026, month: 9, day: 15)),
            status: .confirmed,
            updatedAt: nil,
            privacyClass: .ordinary,
            colorId: nil
        )
        fake.pages = [try page([allDay])]

        let events = try await makeSource(calendars: fake)
            .planningEvents(calendarIDs: [calendarID], interval: interval())

        XCTAssertEqual(events.first?.kind, .deadline)
        XCTAssertGreaterThan(
            events.first!.end, events.first!.start,
            "Google's all-day end is exclusive, so the span must still be positive"
        )
    }

    func testEventMissingATimeRangeIsDropped() async throws {
        var fake = FakeCalendars()
        fake.records = [
            GoogleCalendarRecord(id: calendarID, displayName: "Cal", isPrimary: true)
        ]
        let broken = CalendarEventRecord(
            id: try GoogleCalendarEventID(validating: "no-times"),
            calendarID: calendarID, title: "Broken", description: nil, location: nil,
            start: nil, end: nil, status: .confirmed, updatedAt: nil,
            privacyClass: .ordinary, colorId: nil
        )
        fake.pages = [try page([broken, try timedRecord(id: "ok")])]

        let events = try await makeSource(calendars: fake)
            .planningEvents(calendarIDs: [calendarID], interval: interval())

        XCTAssertEqual(events.map(\.id), ["ok"])
    }

    func testPaginationFollowsNextPageToken() async throws {
        var fake = FakeCalendars()
        fake.records = [
            GoogleCalendarRecord(id: calendarID, displayName: "Cal", isPrimary: true)
        ]
        fake.pages = [
            try page([try timedRecord(id: "p1")], next: "token-2"),
            try page([try timedRecord(id: "p2")]),
        ]

        let events = try await makeSource(calendars: fake)
            .planningEvents(calendarIDs: [calendarID], interval: interval())

        XCTAssertEqual(Set(events.map(\.id)), ["p1", "p2"])
        XCTAssertEqual(fake.calls.pageTokens.count, 2)
        XCTAssertNil(fake.calls.pageTokens.first ?? nil)
        XCTAssertNotNil(fake.calls.pageTokens.last ?? nil, "second call must carry the token")
    }

    func testPlanningIgnoresCalendarsThatWereNotAskedFor() async throws {
        let excluded = CalendarID(rawValue: "cal-excluded")
        var fake = FakeCalendars()
        fake.records = [
            GoogleCalendarRecord(id: calendarID, displayName: "Cal", isPrimary: true),
            GoogleCalendarRecord(id: excluded, displayName: "Reference", isPrimary: false),
        ]
        fake.pages = [try page([try timedRecord(id: "planning-only")])]

        let events = try await makeSource(calendars: fake)
            .planningEvents(calendarIDs: [calendarID], interval: interval())

        // Exactly one calendar was requested, so exactly one events() call may happen.
        XCTAssertEqual(fake.calls.eventCallCount, 1)
        XCTAssertEqual(events.map(\.id), ["planning-only"])
    }

    func testEmptyCalendarSetReadsNothingAtAll() async throws {
        let fake = FakeCalendars()
        let events = try await makeSource(calendars: fake)
            .planningEvents(calendarIDs: [], interval: interval())

        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(fake.calls.eventCallCount, 0, "must not call Google for an empty set")
    }

    func testCatalogMapsGoogleCalendarsToDescriptors() async throws {
        var fake = FakeCalendars()
        fake.records = [
            GoogleCalendarRecord(id: calendarID, displayName: "School", isPrimary: true),
            GoogleCalendarRecord(
                id: CalendarID(rawValue: "cal-2"), displayName: "Work", isPrimary: false
            ),
        ]
        let descriptors = try await makeSource(calendars: fake).calendars()

        XCTAssertEqual(descriptors.map(\.displayName), ["School", "Work"])
        XCTAssertEqual(
            descriptors.map(\.id), [calendarID, CalendarID(rawValue: "cal-2")],
            "secondary calendars must not be dropped — their colours drive categorisation"
        )
    }

    func testColoursInUseReportsOnlyColoursActuallyOnCalendars() async throws {
        var fake = FakeCalendars()
        fake.records = [
            GoogleCalendarRecord(
                id: calendarID, displayName: "Cal", isPrimary: true, colorId: "5"
            ),
            GoogleCalendarRecord(
                id: CalendarID(rawValue: "cal-2"), displayName: "Two", isPrimary: false,
                colorId: nil
            ),
        ]
        var colors = FakeColors()
        colors.palette = GoogleColorPalette(
            calendar: [
                "5": GoogleColorEntry(background: "#111111", foreground: "#ffffff"),
                "6": GoogleColorEntry(background: "#222222", foreground: "#ffffff"),
            ],
            event: [:]
        )

        let entries = try await makeSource(calendars: fake, colors: colors).colorsInUse()

        XCTAssertEqual(entries.map(\.colorID), ["5"], "only colours in use, not the whole palette")
        XCTAssertEqual(entries.first?.background, "#111111")
    }

    func testColourLabelNeverLeaksACalendarTitle() async throws {
        var fake = FakeCalendars()
        fake.records = [
            GoogleCalendarRecord(
                id: calendarID, displayName: "Braxton's Private Therapy", isPrimary: true,
                colorId: "5"
            )
        ]
        var colors = FakeColors()
        colors.palette = GoogleColorPalette(
            calendar: ["5": GoogleColorEntry(background: "#111111", foreground: "#ffffff")],
            event: [:]
        )

        let entries = try await makeSource(calendars: fake, colors: colors).colorsInUse()

        XCTAssertFalse(
            entries.contains { $0.label.contains("Therapy") },
            "a colour label must be non-content — never a calendar title"
        )
    }
}
