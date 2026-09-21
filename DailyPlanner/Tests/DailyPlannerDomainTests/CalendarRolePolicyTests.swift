import XCTest
@testable import DailyPlannerDomain

final class CalendarRolePolicyTests: XCTestCase {
    func testMissingNewAndUnreadableAssignmentsFailClosedToExcludedReference() {
        let id = CalendarID(rawValue: "synthetic-new-calendar")
        XCTAssertEqual(CalendarRolePolicy.role(for: id, assignments: [:]), .excludedReference)
        XCTAssertEqual(CalendarRolePolicy.role(for: id, assignments: nil), .excludedReference)
    }

    func testPlanningIDsContainOnlyExplicitPlanningAssignments() {
        let planning = CalendarDescriptor(id: .init(rawValue: "synthetic-planning"), displayName: "School Demo")
        let reference = CalendarDescriptor(id: .init(rawValue: "synthetic-reference"), displayName: "Reference Demo")
        let ids = CalendarRolePolicy.planningCalendarIDs(
            catalog: [planning, reference],
            assignments: [planning.id: .planning, reference.id: .excludedReference]
        )
        XCTAssertEqual(ids, Set([planning.id]))
    }
}
