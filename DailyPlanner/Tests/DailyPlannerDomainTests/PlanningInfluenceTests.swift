import XCTest
@testable import DailyPlannerDomain

final class PlanningInfluenceTests: XCTestCase {
    // Mutation caught: deriving an influence surface from anything other than admitted eligible events.
    func testInfluenceUsesOnlyPlanningEventsAndLeavesUnavailableContextsEmpty() {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let planning = event("planning-canary", category: .school)
        let reference = event("reference-canary", category: .other)
        let preview = PlanningPreview.build(eligibleEvents: [planning], now: fixedNow)

        XCTAssertTrue(preview.influence.conflictSourceIDs.contains(planning.id))
        XCTAssertTrue(preview.influence.freeBusySourceIDs.contains(planning.id))
        XCTAssertTrue(preview.influence.workloadSourceIDs.contains(planning.id))
        XCTAssertTrue(preview.influence.fatigueSourceIDs.contains(planning.id))
        XCTAssertTrue(preview.influence.prioritySourceIDs.contains(planning.id))
        XCTAssertTrue(preview.influence.digestSourceIDs.contains(planning.id))
        XCTAssertTrue(preview.influence.summarySourceIDs.contains(planning.id))
        XCTAssertFalse(preview.influence.conflictSourceIDs.contains(reference.id))
        XCTAssertFalse(preview.influence.freeBusySourceIDs.contains(reference.id))
        XCTAssertFalse(preview.influence.workloadSourceIDs.contains(reference.id))
        XCTAssertFalse(preview.influence.fatigueSourceIDs.contains(reference.id))
        XCTAssertFalse(preview.influence.prioritySourceIDs.contains(reference.id))
        XCTAssertFalse(preview.influence.digestSourceIDs.contains(reference.id))
        XCTAssertFalse(preview.influence.summarySourceIDs.contains(reference.id))
        XCTAssertFalse(preview.influence.proposalContextSourceIDs.contains(reference.id))
        XCTAssertFalse(preview.influence.assistantContextSourceIDs.contains(reference.id))
        XCTAssertFalse(preview.influence.actionCandidateSourceIDs.contains(reference.id))
        XCTAssertTrue(preview.influence.proposalContextSourceIDs.isEmpty)
        XCTAssertTrue(preview.influence.assistantContextSourceIDs.isEmpty)
        XCTAssertTrue(preview.influence.actionCandidateSourceIDs.isEmpty)
    }

    private func event(_ id: String, category: PlannerCategory) -> PlannerEvent {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return PlannerEvent(
            id: id,
            calendarID: .init(rawValue: "synthetic-calendar"),
            title: "Synthetic item",
            category: category,
            kind: .task,
            start: start,
            end: start.addingTimeInterval(1800),
            due: start.addingTimeInterval(300)
        )
    }
}
