import XCTest
@testable import DailyPlannerDomain

final class PriorityEngineTests: XCTestCase {
    // Mutation caught: changing the category ordering or admitting advertisements into ordering.
    func testSchoolAlwaysPrecedesCareerFinancePersonalAndOther() {
        let school = event("school", category: .school)
        let career = event("career", category: .career)
        let finance = event("finance", category: .finance)
        let personal = event("personal", category: .personal)
        let other = event("other", category: .other)
        let shuffled = [other, personal, finance, career, school]

        XCTAssertEqual(PriorityEngine().ordered(shuffled).map(\.category), [
            .school, .career, .finance, .personal, .other,
        ])
    }

    // Mutation caught: omitting the advertisement filter from the priority queue.
    func testAdvertisementsNeverEnterTheQueue() {
        let school = event("school", category: .school)
        let advertisement = event("ad", category: .other, kind: .advertisement)
        let preview = PlanningPreview.build(
            eligibleEvents: [advertisement, school],
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(preview.queue.map(\.id), [school.id])
        XCTAssertEqual(preview.schedule.map(\.id), [school.id])
        XCTAssertFalse(preview.allSourceIDs.contains(advertisement.id))
        XCTAssertFalse(preview.influence.contains(advertisement.id))
    }

    // Mutation caught: removing or reversing the due/start/opaque-ID tie-break branches.
    func testStableTieBreakUsesDueThenStartThenOpaqueID() {
        let earlierDue = event("due-first", category: .school, startOffset: 180, dueOffset: 60)
        let earlierStart = event("z-earlier-start", category: .school, startOffset: 0, dueOffset: 120)
        let laterStart = event("a-later-start", category: .school, startOffset: 60, dueOffset: 120)
        let earlierID = event("a", category: .school, startOffset: 120, dueOffset: 120)
        let laterID = event("z", category: .school, startOffset: 120, dueOffset: 120)

        XCTAssertEqual(PriorityEngine().ordered([laterID, earlierID, laterStart, earlierStart, earlierDue]).map(\.id), [
            earlierDue.id, earlierStart.id, laterStart.id, earlierID.id, laterID.id,
        ])
    }

    private func event(
        _ id: String,
        category: PlannerCategory,
        kind: PlannerItemKind = .task,
        startOffset: TimeInterval = 0,
        dueOffset: TimeInterval = 300
    ) -> PlannerEvent {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let eventStart = start.addingTimeInterval(startOffset)
        return PlannerEvent(
            id: id,
            calendarID: .init(rawValue: "synthetic-calendar"),
            title: "Synthetic item",
            category: category,
            kind: kind,
            start: eventStart,
            end: eventStart.addingTimeInterval(1800),
            due: start.addingTimeInterval(dueOffset)
        )
    }
}
