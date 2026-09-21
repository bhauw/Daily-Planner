import XCTest
@testable import DailyPlannerDomain

final class LocalSchedulePolicyTests: XCTestCase {
    // Mutation caught: changing Vancouver's fixed daily scan hours.
    func testScanSlotsAreSixNoonAndTwentyOneInVancouver() throws {
        let localSummerDay = localDate(year: 2026, month: 8, day: 30)
        let slots = try LocalSchedulePolicy.v1.scanSlots(on: localSummerDay)

        XCTAssertEqual(slots.map(localHour), [6, 12, 21])
    }

    // Mutation caught: using fixed-duration days instead of Vancouver local calendar days around DST.
    func testSlotsRemainLocalAcrossSpringAndFallDSTDays() throws {
        let policy = LocalSchedulePolicy.v1
        let springTransitionDay = localDate(year: 2026, month: 3, day: 8)
        let fallTransitionDay = localDate(year: 2026, month: 11, day: 1)

        XCTAssertEqual(try policy.scanSlots(on: springTransitionDay).map(localHour), [6, 12, 21])
        XCTAssertEqual(try policy.scanSlots(on: fallTransitionDay).map(localHour), [6, 12, 21])
        XCTAssertEqual(policy.localDayInterval(containing: springTransitionDay).duration, 23 * 60 * 60)
        XCTAssertEqual(policy.localDayInterval(containing: fallTransitionDay).duration, 25 * 60 * 60)
    }

    // Mutation caught: treating a no-usage or zero-source midnight as summary eligible.
    func testMidnightSummaryIsEligibilityOnlyAndRequiresUsage() {
        let policy = LocalSchedulePolicy.v1

        XCTAssertEqual(policy.midnightEligibility(usageSincePreviousMidnight: false, eligibleSourceCount: 3), .ineligible(.noUsage))
        XCTAssertEqual(policy.midnightEligibility(usageSincePreviousMidnight: true, eligibleSourceCount: 0), .ineligible(.noEligibleSources))
        XCTAssertEqual(policy.midnightEligibility(usageSincePreviousMidnight: true, eligibleSourceCount: 3), .eligible(sourceCount: 3))
    }

    private func localDate(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Vancouver")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func localHour(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Vancouver")!
        return calendar.component(.hour, from: date)
    }
}
