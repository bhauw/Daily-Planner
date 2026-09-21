import XCTest
@testable import DailyPlannerUI

final class ThreeColumnLayoutPolicyTests: XCTestCase {
    func testBalancedWidthsAtDefaultWindowSize() {
        let widths = ThreeColumnLayoutPolicy.widths(total: 1280)
        XCTAssertEqual(widths.left, widths.right, accuracy: 0.5)
        XCTAssertGreaterThan(widths.center, widths.left)
        XCTAssertEqual(widths.left + widths.center + widths.right, 1280, accuracy: 0.5)
    }

    func testMinimumWindowWidthKeepsPositiveCenterColumn() {
        let widths = ThreeColumnLayoutPolicy.widths(total: 1100)
        XCTAssertGreaterThanOrEqual(widths.left, 260)
        XCTAssertGreaterThan(widths.center, 0)
        XCTAssertEqual(widths.left, widths.right, accuracy: 0.5)
    }
}
