import Foundation
import XCTest
@testable import DailyPlannerApplication
@testable import DailyPlannerDomain

final class ColorCategoryWorkflowTests: XCTestCase {
    func testRowsMergeCatalogWithPersistedMappingSortedByColourId() async throws {
        let store = RecordingSettingsStore(initial: settings(mapping: ["11": .finance, "99": .work]))
        let workflow = ColorCategoryWorkflow(
            settingsStore: store,
            catalogReader: FakeColorCatalog(entries: [
                entry("7", "#039BE5", "Peacock"),
                entry("11", "#DC2127", "Tomato"),
            ])
        )

        let rows = try await workflow.rows()

        // Sorted by numeric id: 7, 11, then the mapped-but-absent 99 (kept so a saved
        // mapping stays editable even if the colour is no longer in the catalog).
        XCTAssertEqual(rows.map(\.entry.colorID), ["7", "11", "99"])
        XCTAssertNil(rows[0].category)               // in use, unmapped
        XCTAssertEqual(rows[1].category, .finance)    // in use, mapped
        XCTAssertEqual(rows[1].entry.background, "#DC2127")
        XCTAssertEqual(rows[2].category, .work)       // mapped, absent from catalog
        XCTAssertEqual(rows[2].entry.label, "Colour 99")
    }

    func testSetCategoryPersistsAssignmentAndClearsWithNil() throws {
        let store = RecordingSettingsStore(initial: settings(mapping: [:]))
        let workflow = ColorCategoryWorkflow(settingsStore: store, catalogReader: FakeColorCatalog(entries: []))

        try workflow.setCategory(.school, forColorID: "7")
        XCTAssertEqual(store.storedSettings.colorCategoryMapping, ["7": .school])

        try workflow.setCategory(.commute, forColorID: "24")
        XCTAssertEqual(store.storedSettings.colorCategoryMapping, ["7": .school, "24": .commute])

        // nil clears the assignment so the colour falls back to the default palette.
        try workflow.setCategory(nil, forColorID: "7")
        XCTAssertEqual(store.storedSettings.colorCategoryMapping, ["24": .commute])
    }

    func testFailuresMapToFiniteWorkflowErrors() async {
        let catalogFailure = ColorCategoryWorkflow(
            settingsStore: RecordingSettingsStore(initial: settings(mapping: [:])),
            catalogReader: FakeColorCatalog(entries: [], shouldFail: true)
        )
        await assertThrows(PlanningWorkflowError.catalogUnavailable) { _ = try await catalogFailure.rows() }

        let loadFailure = ColorCategoryWorkflow(
            settingsStore: RecordingSettingsStore(initial: settings(mapping: [:]), mode: .failLoad),
            catalogReader: FakeColorCatalog(entries: [])
        )
        await assertThrows(PlanningWorkflowError.settingsUnavailable) { _ = try await loadFailure.rows() }

        let replaceFailure = ColorCategoryWorkflow(
            settingsStore: RecordingSettingsStore(initial: settings(mapping: [:]), mode: .failReplace),
            catalogReader: FakeColorCatalog(entries: [])
        )
        await assertThrows(PlanningWorkflowError.settingsUnavailable) {
            try replaceFailure.setCategory(.school, forColorID: "7")
        }
    }

    // MARK: - Helpers

    private func settings(mapping: [String: PlannerCategory]) -> PrivateSettings {
        var settings = PrivateSettings.empty
        settings.colorCategoryMapping = mapping
        return settings
    }

    private func entry(_ id: String, _ background: String, _ label: String) -> ColorCatalogEntry {
        ColorCatalogEntry(colorID: id, background: background, foreground: "#1D1D1D", label: label)
    }

    private func assertThrows(
        _ expected: PlanningWorkflowError,
        _ operation: @escaping () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as PlanningWorkflowError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}

private struct FakeColorCatalog: ColorCatalogReading {
    let entries: [ColorCatalogEntry]
    var shouldFail = false
    func colorsInUse() async throws -> [ColorCatalogEntry] {
        if shouldFail { throw TestFixtureError.injected }
        return entries
    }
}
