import Foundation
import XCTest
@testable import DailyPlannerDomain

final class GoogleColorModelsTests: XCTestCase {
    func testEffectiveColorIdPrefersEventColourThenInheritsCalendarColour() {
        // Event colour wins when present.
        XCTAssertEqual(
            GoogleColorCategory.effectiveColorID(eventColorID: "11", calendarColorID: "7"), "11"
        )
        // Absent event colour inherits the calendar's — explicit inheritance, not a silent nil.
        XCTAssertEqual(
            GoogleColorCategory.effectiveColorID(eventColorID: nil, calendarColorID: "7"), "7"
        )
        XCTAssertEqual(
            GoogleColorCategory.effectiveColorID(eventColorID: "", calendarColorID: "7"), "7"
        )
        // Neither present → no colour to resolve.
        XCTAssertNil(GoogleColorCategory.effectiveColorID(eventColorID: nil, calendarColorID: nil))
        XCTAssertNil(GoogleColorCategory.effectiveColorID(eventColorID: "", calendarColorID: ""))
    }

    func testCategoryResolvesThroughInheritanceAndFallsBackWhenUnmapped() {
        let mapping: [String: PlannerCategory] = ["7": .school, "11": .finance]

        // Event's own colour is mapped.
        XCTAssertEqual(
            GoogleColorCategory.category(forEventColorID: "11", calendarColorID: "7", mapping: mapping),
            .finance
        )
        // No event colour → inherits calendar colour "7" → school.
        XCTAssertEqual(
            GoogleColorCategory.category(forEventColorID: nil, calendarColorID: "7", mapping: mapping),
            .school
        )
        // A colour the user has not mapped falls back (never nil), default `.other`.
        XCTAssertEqual(
            GoogleColorCategory.category(forEventColorID: "24", calendarColorID: nil, mapping: mapping),
            .other
        )
        // Explicit fallback is honoured.
        XCTAssertEqual(
            GoogleColorCategory.category(
                forEventColorID: nil, calendarColorID: nil, mapping: mapping, fallback: .personal
            ),
            .personal
        )
    }

    func testColorCategoryMappingPersistsRoundTripInPrivateSettings() throws {
        var settings = PrivateSettings.empty
        settings.colorCategoryMapping = ["7": .school, "11": .finance, "24": .work]

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(PrivateSettings.self, from: encoded)
        XCTAssertEqual(decoded.colorCategoryMapping, settings.colorCategoryMapping)
    }

    func testPrivateSettingsToleratesBlobWrittenBeforeColorMappingExisted() throws {
        // A settings blob from before `colorCategoryMapping` was added must still load,
        // defaulting the map to empty rather than failing to decode. Build the legacy blob
        // by encoding real settings and stripping the key, so every other field keeps its
        // exact on-disk shape.
        var settings = PrivateSettings.empty
        settings.colorCategoryMapping = ["7": .school]
        let encoded = try JSONEncoder().encode(settings)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "colorCategoryMapping")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(PrivateSettings.self, from: legacy)
        XCTAssertEqual(decoded.colorCategoryMapping, [:])
    }
}
