import Combine
import Foundation
import XCTest
@testable import DailyPlannerApplication
@testable import DailyPlannerDomain
@testable import DailyPlannerUI

@MainActor
final class PlannerAppModelTests: XCTestCase {
    func testM2ASafetyStateNeverOffersExecution() {
        let model = PlannerModelHarness.make().model
        XCTAssertEqual(model.safetyBanner, "Read-only · no actions executed")
        XCTAssertEqual(model.assistantState, .unavailable(.notIncludedInM2))
        XCTAssertFalse(model.canExecuteExternalAction)
    }

    /// Enabling writes must actually ask Google for the write scopes. If it re-asked for
    /// read-only, consent would appear to succeed and every send would then fail with a scope
    /// mismatch — the worst kind of failure, because it looks like it worked.
    func testEnablingWriteAccessAsksGoogleForTheWriteScopes() async {
        let harness = PlannerModelHarness.makeGoogle(state: .notConfigured)
        harness.model.googleClientIdentifierDraft = "synthetic-client.apps.example.test"
        harness.model.googleClientSecretDraft = "synthetic-secret-canary"
        await harness.model.saveGoogleClientConfiguration()

        await harness.model.enableGoogleWriteAccess()

        XCTAssertEqual(harness.connection.requestedCapabilities, [.readWrite])
    }

    /// An ordinary connect must not quietly acquire write access.
    func testAnOrdinaryConnectStillAsksOnlyForReadOnlyScopes() async {
        let harness = PlannerModelHarness.makeGoogle(state: .notConfigured)
        harness.model.googleClientIdentifierDraft = "synthetic-client.apps.example.test"
        harness.model.googleClientSecretDraft = "synthetic-secret-canary"
        await harness.model.saveGoogleClientConfiguration()

        await harness.model.connectGoogle()

        XCTAssertEqual(harness.connection.requestedCapabilities, [.readOnly])
    }

    /// Write access cannot be bolted onto an existing grant, so the upgrade must disconnect
    /// first — otherwise `begin` refuses and the user is told to reconnect with no way to.
    func testEnablingWriteAccessDisconnectsBeforeReconnecting() async {
        let harness = PlannerModelHarness.makeGoogle(state: .notConfigured)
        harness.model.googleClientIdentifierDraft = "synthetic-client.apps.example.test"
        harness.model.googleClientSecretDraft = "synthetic-secret-canary"
        await harness.model.saveGoogleClientConfiguration()

        await harness.model.enableGoogleWriteAccess()

        XCTAssertEqual(harness.connection.actions, [.save, .disconnect, .begin])
    }

    func testOpeningSettingsAndExplicitStateLoadNeverBeginOrOpenBrowser() async {
        let harness = PlannerModelHarness.makeGoogle(state: .notConfigured)

        harness.model.showSettings()
        await harness.model.loadGoogleConnectionState()

        XCTAssertTrue(harness.model.isSettingsPresented)
        XCTAssertEqual(harness.model.googleConnectionState, .notConfigured)
        XCTAssertEqual(harness.connection.beginCount, 0)
        XCTAssertEqual(harness.browser.openCount, 0)
    }

    func testExplicitMethodsDriveSaveBeginConfirmAndDisconnectInOrder() async {
        let harness = PlannerModelHarness.makeGoogle(state: .notConfigured)
        harness.model.googleClientIdentifierDraft = "synthetic-client.apps.example.test"
        harness.model.googleClientSecretDraft = "synthetic-secret-canary"

        await harness.model.saveGoogleClientConfiguration()
        await harness.model.connectGoogle()
        await harness.model.confirmGoogleIdentity()
        await harness.model.disconnectGoogle()

        XCTAssertEqual(harness.connection.actions, [.save, .begin, .confirm, .disconnect])
        XCTAssertEqual(harness.model.googleConnectionState, .notConfigured)
    }

    func testSaveClearsTransientDraftAndBeginPublishesWorkflowProgress() async throws {
        let harness = PlannerModelHarness.makeGoogle(state: .notConfigured)
        var states: [GoogleConnectionWorkflowState] = []
        let observation = harness.model.$googleConnectionState
            .dropFirst()
            .sink { states.append($0) }
        defer { observation.cancel() }

        harness.model.googleClientIdentifierDraft = "synthetic-client.apps.example.test"
        harness.model.googleClientSecretDraft = "synthetic-secret-canary"
        await harness.model.saveGoogleClientConfiguration()
        XCTAssertEqual(harness.model.googleClientIdentifierDraft, "")
        XCTAssertEqual(harness.model.googleClientSecretDraft, "")

        await harness.model.connectGoogle()

        XCTAssertEqual(states, [
            .readyToConnect,
            .connecting,
            .awaitingConsent,
            .confirmIdentity(displayEmail: "reader@example.test"),
        ])
        await assertMissingClientSecretIsNotSavedAndBothDraftsClearAfterAttempt()
    }

    private func assertMissingClientSecretIsNotSavedAndBothDraftsClearAfterAttempt() async {
        let harness = PlannerModelHarness.makeGoogle(state: .notConfigured)
        harness.model.googleClientIdentifierDraft = "synthetic-client.apps.example.test"
        harness.model.googleClientSecretDraft = ""
        XCTAssertFalse(harness.model.canSaveGoogleClientConfiguration)

        await harness.model.saveGoogleClientConfiguration()

        XCTAssertEqual(harness.connection.actions, [])
        XCTAssertEqual(harness.model.googleConnectionState, .cleanupRequired)
        XCTAssertEqual(harness.model.googleClientIdentifierDraft, "")
        XCTAssertEqual(harness.model.googleClientSecretDraft, "")
    }

    func testDismissingSettingsCancelsOnlyPendingConnection() async {
        let readyHarness = PlannerModelHarness.makeGoogle(state: .readyToConnect)
        readyHarness.model.showSettings()
        await readyHarness.model.dismissSettings()
        XCTAssertEqual(readyHarness.connection.cancelCount, 0)

        let pendingHarness = PlannerModelHarness.makeGoogle(state: .readyToConnect)
        await pendingHarness.model.connectGoogle()
        pendingHarness.model.showSettings()
        await pendingHarness.model.dismissSettings()
        XCTAssertEqual(pendingHarness.connection.cancelCount, 1)
        XCTAssertEqual(pendingHarness.model.googleConnectionState, .cancelled)
    }

    func testDismissingSettingsCancelsConnectionBeforeFirstProgress() async {
        // Break caught: dismissal misses an active begin while its published state is still ready-to-connect.
        let beginGate = SuspendedGoogleBegin()
        let harness = PlannerModelHarness.make(
            googleState: .readyToConnect,
            startsWithSettingsPresented: true,
            googleBeginGate: beginGate
        )
        let connectionTask = Task { await harness.model.connectGoogle() }
        let didEnterBegin = await beginGate.waitUntilEntered()
        XCTAssertTrue(didEnterBegin)
        XCTAssertEqual(harness.model.googleConnectionState, .readyToConnect)

        await harness.model.dismissSettings()
        let stateAfterDismissal = harness.model.googleConnectionState
        let cancelCountAfterDismissal = harness.connection.cancelCount
        beginGate.release()
        await connectionTask.value

        XCTAssertFalse(harness.model.isSettingsPresented)
        XCTAssertEqual(stateAfterDismissal, .cancelled)
        XCTAssertEqual(cancelCountAfterDismissal, 1)
        XCTAssertEqual(harness.model.googleConnectionState, .cancelled)
        XCTAssertEqual(harness.browser.openCount, 0)
    }

    func testNoExplicitPlanningRoleProducesEmptyPreview() async {
        let model = PlannerModelHarness.make(assignments: [:]).model
        await model.refresh()
        XCTAssertTrue(model.preview.queue.isEmpty)
    }

    func testRoleChangeInvalidatesPreviewUntilRefresh() async {
        let harness = PlannerModelHarness.make(planningSchool: true)
        let model = harness.model
        await model.refresh()
        await model.setRole(.excludedReference, for: harness.schoolCalendarID)
        XCTAssertEqual(model.previewState, .requiresRefresh)
        XCTAssertEqual(model.preview, .empty)
    }

    func testVaultSelectionShowsPermissionWithoutPath() async {
        let model = PlannerModelHarness.make(folderPickerResult: Data("opaque".utf8)).model
        await model.chooseVaultRoot()
        XCTAssertEqual(model.vaultPermissionLabel, "Permission remembered")
        XCTAssertFalse(model.vaultPermissionLabel.contains("/"))
    }

    func testOpeningSettingsDoesNotStartOnboardingOrRefresh() {
        let harness = PlannerModelHarness.make()
        let model = harness.model
        model.showSettings()
        XCTAssertTrue(model.isSettingsPresented)
        XCTAssertEqual(harness.picker.callCount, 0)
        XCTAssertEqual(harness.source.planningReadCallCount, 0)
    }

    func testExplicitSettingsLoadPublishesMemoryOnlyRoleRows() async {
        let harness = PlannerModelHarness.make()
        await harness.model.loadCalendarRoles()
        XCTAssertEqual(harness.model.calendarRoleRows.map(\.calendarID), [harness.schoolCalendarID])
        XCTAssertEqual(harness.model.calendarRoleRows.map(\.role), [.excludedReference])
        XCTAssertEqual(harness.store.replaceCount, 0)
    }
}

@MainActor
final class PlannerModelHarness {
    let model: PlannerAppModel
    let picker: RecordingFolderPicker
    let store: RecordingSettingsStore
    let source: RecordingCalendarSource
    let schoolCalendarID: CalendarID
    let connection: RecordingGoogleConnectionController
    let browser: RecordingSystemBrowser

    init(
        model: PlannerAppModel,
        picker: RecordingFolderPicker,
        store: RecordingSettingsStore,
        source: RecordingCalendarSource,
        schoolCalendarID: CalendarID,
        connection: RecordingGoogleConnectionController,
        browser: RecordingSystemBrowser
    ) {
        self.model = model
        self.picker = picker
        self.store = store
        self.source = source
        self.schoolCalendarID = schoolCalendarID
        self.connection = connection
        self.browser = browser
    }

    static func make(
        assignments: [CalendarID: CalendarRole] = [:],
        planningSchool: Bool = false,
        folderPickerResult: Data? = nil,
        googleState: GoogleConnectionWorkflowState = .notConfigured,
        startsWithSettingsPresented: Bool = false,
        googleConnectionGuidance: String? = nil,
        googleBeginGate: SuspendedGoogleBegin? = nil
    ) -> PlannerModelHarness {
        let schoolCalendarID = CalendarID(rawValue: "opaque-school-calendar-canary")
        var resolvedAssignments = assignments
        if planningSchool {
            resolvedAssignments[schoolCalendarID] = .planning
        }

        let store = RecordingSettingsStore(initial: PrivateSettings(
            vaultBookmark: Data("opaque-bookmark-canary".utf8),
            calendarRoles: resolvedAssignments,
            calendarRoleAudit: []
        ))
        let picker = RecordingFolderPicker(result: .success(folderPickerResult))
        let previewStart = Date(timeIntervalSince1970: 1_788_112_800)
        let event = PlannerEvent(
            id: "synthetic-event-id-canary",
            calendarID: schoolCalendarID,
            title: "synthetic-event-title-canary",
            category: .school,
            kind: .deadline,
            start: previewStart.addingTimeInterval(9 * 60 * 60),
            end: previewStart.addingTimeInterval(10 * 60 * 60),
            due: previewStart.addingTimeInterval(16 * 60 * 60)
        )
        let source = RecordingCalendarSource(
            catalog: [CalendarDescriptor(id: schoolCalendarID, displayName: "School")],
            events: [event]
        )
        let previewInterval = DateInterval(start: previewStart, duration: 24 * 60 * 60)
        let clock = FixedClock(now: previewStart.addingTimeInterval(8 * 60 * 60))
        let browser = RecordingSystemBrowser()
        let connection = RecordingGoogleConnectionController(
            presence: googleState == .readyToConnect ? .clientOnly : .none,
            browser: browser,
            beginGate: googleBeginGate
        )
        let googleConnection = GoogleConnectionWorkflow(
            controller: connection,
            settingsStore: store
        )
        let model = PlannerAppModel(
            vaultOnboarding: VaultOnboardingWorkflow(picker: picker, settingsStore: store),
            roles: CalendarRoleWorkflow(settingsStore: store, catalogReader: source),
            planning: PlanningPreviewWorkflow(
                catalogReader: source,
                planningReader: source,
                settingsReader: store,
                clock: clock
            ),
            referenceView: ReferenceCalendarWorkflow(
                referenceReader: source,
                settingsReader: store
            ),
            googleConnection: googleConnection,
            previewInterval: previewInterval,
            initialGoogleConnectionState: googleState,
            startsWithSettingsPresented: startsWithSettingsPresented,
            googleConnectionGuidance: googleConnectionGuidance
        )
        return PlannerModelHarness(
            model: model,
            picker: picker,
            store: store,
            source: source,
            schoolCalendarID: schoolCalendarID,
            connection: connection,
            browser: browser
        )
    }

    static func makeGoogle(state: GoogleConnectionWorkflowState) -> PlannerModelHarness {
        make(googleState: state)
    }
}

enum TestStoreMode: Sendable {
    case working
    case failLoad
    case failReplace
}

enum TestFixtureError: Error, Sendable {
    case injected
}

final class RecordingSettingsStore: PrivateSettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var current: PrivateSettings
    private let mode: TestStoreMode
    private var replacements: [PrivateSettings] = []
    private var loads = 0

    init(initial: PrivateSettings, mode: TestStoreMode = .working) {
        current = initial
        self.mode = mode
    }

    func load() throws -> PrivateSettings {
        try lock.withLock {
            loads += 1
            guard mode != .failLoad else { throw TestFixtureError.injected }
            return current
        }
    }

    func replace(_ settings: PrivateSettings) throws {
        try lock.withLock {
            guard mode != .failReplace else { throw TestFixtureError.injected }
            current = settings
            replacements.append(settings)
        }
    }

    var replaceCount: Int {
        lock.withLock { replacements.count }
    }

    var loadCount: Int {
        lock.withLock { loads }
    }
}

struct FixedClock: PlannerClock, Sendable {
    let now: Date
}

final class RecordingCalendarSource:
    CalendarCatalogReading,
    PlanningCalendarReading,
    ExcludedReferenceViewing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let catalogStorage: [CalendarDescriptor]
    private let eventStorage: [PlannerEvent]
    private var planningReads = 0

    init(catalog: [CalendarDescriptor], events: [PlannerEvent]) {
        catalogStorage = catalog
        eventStorage = events
    }

    func calendars() async throws -> [CalendarDescriptor] {
        catalogStorage
    }

    func planningEvents(
        calendarIDs: Set<CalendarID>,
        interval: DateInterval
    ) async throws -> [PlannerEvent] {
        lock.withLock { planningReads += 1 }
        return eventStorage.filter {
            calendarIDs.contains($0.calendarID) && $0.start < interval.end && $0.end > interval.start
        }
    }

    func referenceEvents(
        calendarID: CalendarID,
        interval: DateInterval
    ) async throws -> [PlannerEvent] {
        eventStorage.filter {
            $0.calendarID == calendarID && $0.start < interval.end && $0.end > interval.start
        }
    }

    var planningReadCallCount: Int {
        lock.withLock { planningReads }
    }
}

@MainActor
final class RecordingFolderPicker: VaultFolderSelecting, @unchecked Sendable {
    private let result: Result<Data?, TestFixtureError>
    private(set) var callCount = 0

    init(result: Result<Data?, TestFixtureError>) {
        self.result = result
    }

    func selectRootBookmark() async throws -> Data? {
        callCount += 1
        return try result.get()
    }
}

enum GoogleModelAction: Equatable, Sendable {
    case save, begin, confirm, cancel, disconnect
}

final class RecordingSystemBrowser: SystemBrowserOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var openedURLs: [URL] = []

    func open(_ url: URL) async -> Bool {
        lock.withLock { openedURLs.append(url) }
        return true
    }

    var openCount: Int {
        lock.withLock { openedURLs.count }
    }
}

final class RecordingGoogleConnectionController: GoogleConnectionControlling, @unchecked Sendable {
    private let lock = NSLock()
    /// Which scope set each connect attempt asked Google for — this is what proves a reconnect
    /// for writes actually requests write access rather than silently re-asking for read-only.
    private(set) var requestedCapabilities: [GoogleGrantedCapability] = []
    private let browser: RecordingSystemBrowser
    private let binding = try! GoogleIdentityBinding(normalizing: "reader@example.test")
    private var presenceStorage: GoogleCredentialPresence
    private var recordedActions: [GoogleModelAction] = []
    private var credentialPresenceReads = 0
    private let beginGate: SuspendedGoogleBegin?

    init(
        presence: GoogleCredentialPresence,
        browser: RecordingSystemBrowser,
        beginGate: SuspendedGoogleBegin? = nil
    ) {
        presenceStorage = presence
        self.browser = browser
        self.beginGate = beginGate
    }

    func saveClientConfiguration(_ value: GoogleOAuthClientConfiguration) throws {
        lock.withLock {
            recordedActions.append(.save)
            presenceStorage = .clientOnly
        }
    }

    func credentialPresence() throws -> GoogleCredentialPresence {
        lock.withLock {
            credentialPresenceReads += 1
            return presenceStorage
        }
    }

    func begin(
        capability: GoogleGrantedCapability,
        progress: @escaping @Sendable (GoogleConnectionProgress) async -> Void
    ) async throws -> GooglePendingIdentity {
        lock.withLock {
            recordedActions.append(.begin)
            requestedCapabilities.append(capability)
        }
        if let beginGate {
            try await beginGate.waitForResolution()
        }
        await progress(.connecting)
        await progress(.awaitingConsent)
        _ = await browser.open(URL(string: "https://auth.example.test/consent")!)
        return GooglePendingIdentity(displayEmail: "reader@example.test", binding: binding)
    }

    func confirmPendingIdentity() async throws -> GoogleConnectionReceipt {
        lock.withLock {
            recordedActions.append(.confirm)
            presenceStorage = .complete
        }
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

    func cancelPendingConnection() async {
        lock.withLock { recordedActions.append(.cancel) }
        beginGate?.cancel()
    }

    func disconnect() async throws {
        lock.withLock {
            recordedActions.append(.disconnect)
            presenceStorage = .none
        }
    }

    /// Mirrors the real controller: the grant goes, the client configuration stays, so the
    /// connection is left ready to consent again rather than needing reconfiguration.
    func disconnectForReconsent() async throws {
        lock.withLock {
            recordedActions.append(.disconnect)
            presenceStorage = .clientOnly
        }
    }

    var actions: [GoogleModelAction] {
        lock.withLock { recordedActions }
    }

    var beginCount: Int {
        lock.withLock { recordedActions.filter { $0 == .begin }.count }
    }

    var cancelCount: Int {
        lock.withLock { recordedActions.filter { $0 == .cancel }.count }
    }

    var credentialPresenceCount: Int {
        lock.withLock { credentialPresenceReads }
    }
}

final class SuspendedGoogleBegin: @unchecked Sendable {
    private struct State {
        var isEntered = false
        var cancellationResult: Bool?
        var beginContinuation: CheckedContinuation<Bool, Never>?
    }

    private let lock = NSLock()
    private var state = State()

    func waitForResolution() async throws {
        let wasCancelled = await withCheckedContinuation {
            (continuation: CheckedContinuation<Bool, Never>) in
            let immediateResult: Bool? = lock.withLock {
                state.isEntered = true
                if let cancellationResult = state.cancellationResult {
                    return cancellationResult
                }
                state.beginContinuation = continuation
                return nil
            }
            if let immediateResult { continuation.resume(returning: immediateResult) }
        }
        if wasCancelled {
            throw GoogleConnectionControllerError.cancelled
        }
    }

    func waitUntilEntered() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !lock.withLock({ state.isEntered }), clock.now < deadline {
            await Task.yield()
        }
        return lock.withLock { state.isEntered }
    }

    func cancel() {
        resolve(wasCancelled: true)
    }

    func release() {
        resolve(wasCancelled: false)
    }

    private func resolve(wasCancelled: Bool) {
        let continuation: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard state.cancellationResult == nil else { return nil }
            state.cancellationResult = wasCancelled
            defer { state.beginContinuation = nil }
            return state.beginContinuation
        }
        continuation?.resume(returning: wasCancelled)
    }
}
