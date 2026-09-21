import Foundation
import XCTest
@testable import DailyPlannerApplication
@testable import DailyPlannerDomain
@testable import DailyPlannerPlatform
@testable import DailyPlannerUI

@MainActor
final class M2AReadOnlyAcceptanceTests: XCTestCase {
    func testAcceptanceCompositionWithFakesDoesNotTouchExternalBoundariesUntilConnect() async {
        let harness = M2AAcceptanceHarness.generated()

        await harness.model.loadGoogleConnectionState()

        XCTAssertEqual(harness.externalCalls, [])
        XCTAssertFalse(harness.model.canExecuteExternalAction)
        XCTAssertEqual(harness.model.safetyBanner, "Read-only · no actions executed")
        XCTAssertEqual(harness.model.assistantState, .unavailable(.notIncludedInM2))
    }

    func testCanaryCompositionOpensSettingsWithGenericGuidanceAndNoAutomaticAction() {
        let harness = M2AAcceptanceHarness.generated(mode: .liveReadOnlyCanary)

        XCTAssertTrue(harness.model.isSettingsPresented)
        XCTAssertEqual(
            harness.model.googleConnectionGuidance,
            "Canary mode is ready. Click Connect to begin; nothing starts automatically."
        )
        XCTAssertEqual(harness.externalCalls, [])

        let exposedGuidance = harness.model.googleConnectionGuidance ?? ""
        for forbidden in [
            "--live-readonly-canary", "client-id", "token", "https://",
        ] {
            XCTAssertFalse(exposedGuidance.contains(forbidden))
        }
    }

    func testStandardCompositionDoesNotOpenSettingsOrPublishCanaryGuidance() {
        let harness = M2AAcceptanceHarness.generated(mode: .standard)

        XCTAssertFalse(harness.model.isSettingsPresented)
        XCTAssertNil(harness.model.googleConnectionGuidance)
        XCTAssertEqual(harness.externalCalls, [])
    }
}

@MainActor
private final class M2AAcceptanceHarness {
    let model: PlannerAppModel
    private let recorder: M2AExternalCallRecorder

    var externalCalls: [M2AExternalCall] {
        recorder.calls
    }

    private init(model: PlannerAppModel, recorder: M2AExternalCallRecorder) {
        self.model = model
        self.recorder = recorder
    }

    static func generated(mode: LaunchMode = .standard) -> M2AAcceptanceHarness {
        let recorder = M2AExternalCallRecorder()
        let store = M2ASettingsStore()
        let calendar = M2ACalendarSource()
        let connection = GoogleConnectionWorkflow(
            controller: M2AConnectionController(recorder: recorder),
            settingsStore: store
        )
        let now = Date(timeIntervalSince1970: 1_788_112_800)
        let isCanary = mode == .liveReadOnlyCanary
        let model = PlannerAppModel(
            vaultOnboarding: VaultOnboardingWorkflow(
                picker: M2AFolderPicker(),
                settingsStore: store
            ),
            roles: CalendarRoleWorkflow(settingsStore: store, catalogReader: calendar),
            planning: PlanningPreviewWorkflow(
                catalogReader: calendar,
                planningReader: calendar,
                settingsReader: store,
                clock: M2AClock(now: now)
            ),
            referenceView: ReferenceCalendarWorkflow(
                referenceReader: calendar,
                settingsReader: store
            ),
            googleConnection: connection,
            previewInterval: DateInterval(start: now, duration: 24 * 60 * 60),
            startsWithSettingsPresented: isCanary,
            googleConnectionGuidance: isCanary
                ? "Canary mode is ready. Click Connect to begin; nothing starts automatically."
                : nil
        )
        return M2AAcceptanceHarness(model: model, recorder: recorder)
    }
}

private enum M2AExternalCall: Equatable, Sendable {
    case browser, keychainMutation, transport
}

private final class M2AExternalCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [M2AExternalCall] = []

    func append(_ call: M2AExternalCall) {
        lock.withLock { storage.append(call) }
    }

    var calls: [M2AExternalCall] {
        lock.withLock { storage }
    }
}

private final class M2AConnectionController: GoogleConnectionControlling, @unchecked Sendable {
    private let recorder: M2AExternalCallRecorder
    private let binding = try! GoogleIdentityBinding(normalizing: "reader@example.test")

    init(recorder: M2AExternalCallRecorder) {
        self.recorder = recorder
    }

    func saveClientConfiguration(_ value: GoogleOAuthClientConfiguration) throws {
        recorder.append(.keychainMutation)
    }

    func credentialPresence() throws -> GoogleCredentialPresence {
        .none
    }

    func begin(
        capability: GoogleGrantedCapability = .readOnly,
        progress: @escaping @Sendable (GoogleConnectionProgress) async -> Void
    ) async throws -> GooglePendingIdentity {
        recorder.append(.browser)
        await progress(.connecting)
        await progress(.awaitingConsent)
        return GooglePendingIdentity(displayEmail: "reader@example.test", binding: binding)
    }

    func confirmPendingIdentity() async throws -> GoogleConnectionReceipt {
        recorder.append(.keychainMutation)
        return GoogleConnectionReceipt(
            scopes: [
                "openid",
                "email",
                "https://www.googleapis.com/auth/gmail.readonly",
                "https://www.googleapis.com/auth/calendar.readonly",
                "https://www.googleapis.com/auth/tasks.readonly",
            ],
            refreshSucceeded: true,
            gmailProfileRead: true,
            calendarListRead: true,
            taskListsRead: true,
            binding: binding
        )
    }

    func cancelPendingConnection() async {}

    func disconnect() async throws {
        recorder.append(.keychainMutation)
    }

    func disconnectForReconsent() async throws {
        recorder.append(.keychainMutation)
    }
}

private final class M2ASettingsStore: PrivateSettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var settings = PrivateSettings.empty

    func load() throws -> PrivateSettings {
        lock.withLock { settings }
    }

    func replace(_ settings: PrivateSettings) throws {
        lock.withLock { self.settings = settings }
    }
}

private struct M2ACalendarSource:
    CalendarCatalogReading,
    PlanningCalendarReading,
    ExcludedReferenceViewing,
    Sendable
{
    func calendars() async throws -> [CalendarDescriptor] { [] }

    func planningEvents(
        calendarIDs: Set<CalendarID>,
        interval: DateInterval
    ) async throws -> [PlannerEvent] { [] }

    func referenceEvents(
        calendarID: CalendarID,
        interval: DateInterval
    ) async throws -> [PlannerEvent] { [] }
}

@MainActor
private struct M2AFolderPicker: VaultFolderSelecting, Sendable {
    func selectRootBookmark() async throws -> Data? { nil }
}

private struct M2AClock: PlannerClock, Sendable {
    let now: Date
}
