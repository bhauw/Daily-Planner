import Foundation
import XCTest
@testable import DailyPlannerDomain
@testable import DailyPlannerApplication

@MainActor
final class VaultOnboardingWorkflowTests: XCTestCase {
    func testSelectionRunsOnlyAfterExplicitUserIntentAndPersistsOnlyBookmark() async {
        let picker = RecordingFolderPicker(result: .success(Data("opaque-bookmark".utf8)))
        let original = PrivateSettings(
            vaultBookmark: Data("previous-opaque-bookmark".utf8),
            calendarRoles: [.init(rawValue: "synthetic-calendar"): .planning],
            calendarRoleAudit: []
        )
        let store = RecordingSettingsStore(initial: original)
        let workflow = VaultOnboardingWorkflow(picker: picker, settingsStore: store)

        XCTAssertEqual(picker.callCount, 0)
        XCTAssertEqual(store.replaceCount, 0)

        let result = await workflow.chooseVaultRoot()

        XCTAssertEqual(result, .selected)
        XCTAssertEqual(picker.callCount, 1)
        XCTAssertEqual(store.lastReplacement?.vaultBookmark, Data("opaque-bookmark".utf8))
        XCTAssertEqual(store.lastReplacement?.schemaVersion, original.schemaVersion)
        XCTAssertEqual(store.lastReplacement?.calendarRoles, original.calendarRoles)
        XCTAssertEqual(store.lastReplacement?.calendarRoleAudit, original.calendarRoleAudit)
    }

    func testCancellationLeavesExistingSettingsUnchanged() async {
        let store = RecordingSettingsStore(initial: .empty)
        let picker = RecordingFolderPicker(result: .success(nil))
        let workflow = VaultOnboardingWorkflow(picker: picker, settingsStore: store)

        let result = await workflow.chooseVaultRoot()

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(store.replaceCount, 0)
    }

    func testPickerFailureReturnsFiniteStateWithoutRawErrorOrPath() async {
        let store = RecordingSettingsStore(initial: .empty)
        let picker = RecordingFolderPicker(result: .failure(.injected))
        let workflow = VaultOnboardingWorkflow(picker: picker, settingsStore: store)

        let result = await workflow.chooseVaultRoot()

        XCTAssertEqual(result, .failed(.selectionUnavailable))
        XCTAssertEqual(store.replaceCount, 0)
    }

    func testSettingsFailureReturnsStorageFiniteState() async {
        let picker = RecordingFolderPicker(result: .success(Data("opaque-bookmark".utf8)))
        let store = RecordingSettingsStore(initial: .empty, mode: .failLoad)
        let workflow = VaultOnboardingWorkflow(picker: picker, settingsStore: store)

        let result = await workflow.chooseVaultRoot()

        XCTAssertEqual(result, .failed(.settingsUnavailable))
        XCTAssertEqual(store.replaceCount, 0)
    }

    func testSettingsReplaceFailureReturnsStorageFiniteState() async {
        let picker = RecordingFolderPicker(result: .success(Data("opaque-bookmark".utf8)))
        let store = RecordingSettingsStore(initial: .empty, mode: .failReplace)
        let workflow = VaultOnboardingWorkflow(picker: picker, settingsStore: store)

        let result = await workflow.chooseVaultRoot()

        XCTAssertEqual(result, .failed(.settingsUnavailable))
        XCTAssertEqual(store.replaceCount, 0)
    }
}
