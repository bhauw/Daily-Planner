import Foundation
import SwiftUI
import XCTest
@testable import DailyPlannerDomain
@testable import DailyPlannerUI

final class PlannerPaletteTests: XCTestCase {
    func testFinanceRendersLavenderNotCareerYellow() {
        // Locks the product-brief bug fix: finance used to return the career colour.
        XCTAssertEqual(PlannerPalette.finance, PlannerPalette.schoolDeadline)
        XCTAssertNotEqual(PlannerPalette.finance, PlannerPalette.career)

        let presentation = PlannerPalette.presentation(for: event(category: .finance, kind: .event))
        XCTAssertEqual(presentation.label, "Finance")
        XCTAssertEqual(presentation.color, PlannerPalette.finance)
        XCTAssertNotEqual(presentation.color, PlannerPalette.career)
    }

    func testPersonalIsSoftenedAwayFromRawMagenta() {
        XCTAssertNotEqual(PlannerPalette.personal, Color(nsColor: .magenta))
        XCTAssertEqual(
            PlannerPalette.presentation(for: event(category: .personal, kind: .event)).color,
            PlannerPalette.personal
        )
    }

    func testNewCommuteAndWorkCategoriesHaveDistinctLabelledPresentations() {
        let commute = PlannerPalette.presentation(for: event(category: .commute, kind: .event))
        XCTAssertEqual(commute.label, "Commute")
        XCTAssertEqual(commute.color, PlannerPalette.commute)

        let work = PlannerPalette.presentation(for: event(category: .work, kind: .event))
        XCTAssertEqual(work.label, "Work")
        XCTAssertEqual(work.color, PlannerPalette.work)

        XCTAssertNotEqual(commute.color, work.color)
    }

    private func event(category: PlannerCategory, kind: PlannerItemKind) -> PlannerEvent {
        PlannerEvent(
            id: "e",
            calendarID: CalendarID(rawValue: "cal"),
            title: "Item",
            category: category,
            kind: kind,
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 3_600),
            due: nil
        )
    }
}
