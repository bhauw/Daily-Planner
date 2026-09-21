import Foundation
import XCTest
@testable import DailyPlannerDomain
@testable import DailyPlannerPlatform

final class M1SyntheticCalendarSourceTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    func testSystemClockReturnsCurrentDate() {
        let before = Date()
        let observed = SystemClock().now
        let after = Date()

        XCTAssertGreaterThanOrEqual(observed, before)
        XCTAssertLessThanOrEqual(observed, after)
    }

    func testCatalogAndEventsAreDeterministicForReferenceDate() async throws {
        let first = M1SyntheticCalendarSource(referenceDate: referenceDate)
        let second = M1SyntheticCalendarSource(referenceDate: referenceDate)

        let firstCatalog = try await first.calendars()
        let secondCatalog = try await second.calendars()
        let interval = DateInterval(
            start: referenceDate.addingTimeInterval(-86_400),
            duration: 172_800
        )
        let firstEvents = try await first.planningEvents(
            calendarIDs: Set(firstCatalog.map(\.id)),
            interval: interval
        )
        let secondEvents = try await second.planningEvents(
            calendarIDs: Set(secondCatalog.map(\.id)),
            interval: interval
        )

        XCTAssertEqual(firstCatalog, secondCatalog)
        XCTAssertEqual(firstEvents, secondEvents)
    }

    func testSyntheticItemsStayWithinContainingVancouverLocalDay() async throws {
        let source = M1SyntheticCalendarSource(referenceDate: referenceDate)
        let catalog = try await source.calendars()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Vancouver"))
        let dayStart = calendar.startOfDay(for: referenceDate)
        let dayEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: dayStart))
        let events = try await source.planningEvents(
            calendarIDs: Set(catalog.map(\.id)),
            interval: DateInterval(start: dayStart, end: dayEnd)
        )

        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.allSatisfy { $0.start >= dayStart && $0.end <= dayEnd })
        XCTAssertTrue(events.allSatisfy { $0.title.localizedCaseInsensitiveContains("synthetic") })
    }

    func testPlanningReadReturnsOnlyRequestedCalendarIDsAndOverlappingInterval() async throws {
        let source = M1SyntheticCalendarSource(referenceDate: referenceDate)
        let catalog = try await source.calendars()
        let planningID = try XCTUnwrap(catalog.first?.id)
        let broadInterval = DateInterval(
            start: referenceDate.addingTimeInterval(-86_400),
            duration: 172_800
        )
        let events = try await source.planningEvents(
            calendarIDs: [planningID],
            interval: broadInterval
        )

        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.allSatisfy { $0.calendarID == planningID })
        let disjoint = DateInterval(
            start: referenceDate.addingTimeInterval(172_800),
            duration: 3_600
        )
        let disjointEvents = try await source.planningEvents(
            calendarIDs: [planningID],
            interval: disjoint
        )
        XCTAssertEqual(disjointEvents, [])
    }

    func testReferenceReadReturnsOnlyRequestedReferenceCalendar() async throws {
        let source = M1SyntheticCalendarSource(referenceDate: referenceDate)
        let catalog = try await source.calendars()
        let referenceID = try XCTUnwrap(catalog.last?.id)
        let events = try await source.referenceEvents(
            calendarID: referenceID,
            interval: DateInterval(
                start: referenceDate.addingTimeInterval(-86_400),
                duration: 172_800
            )
        )

        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.allSatisfy { $0.calendarID == referenceID })
    }
}
