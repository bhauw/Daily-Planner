import Foundation
@testable import DailyPlannerDomain
@testable import DailyPlannerApplication

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
    private let callRecorder: WorkflowCallRecorder?
    private let failingLoadNumbers: Set<Int>
    private var replacements: [PrivateSettings] = []
    private var loads = 0
    private var replaceAttempts = 0

    init(
        initial: PrivateSettings,
        mode: TestStoreMode = .working,
        callRecorder: WorkflowCallRecorder? = nil,
        failingLoadNumbers: Set<Int> = []
    ) {
        self.current = initial
        self.mode = mode
        self.callRecorder = callRecorder
        self.failingLoadNumbers = failingLoadNumbers
    }

    func load() throws -> PrivateSettings {
        try lock.withLock {
            loads += 1
            callRecorder?.append("settings.load")
            guard mode != .failLoad, !failingLoadNumbers.contains(loads) else {
                throw TestFixtureError.injected
            }
            return current
        }
    }

    func replace(_ settings: PrivateSettings) throws {
        try lock.withLock {
            replaceAttempts += 1
            callRecorder?.append("settings.replace")
            guard mode != .failReplace else {
                throw TestFixtureError.injected
            }
            current = settings
            replacements.append(settings)
        }
    }

    var loadCount: Int {
        lock.withLock { loads }
    }

    var replaceCount: Int {
        lock.withLock { replacements.count }
    }

    var replaceAttemptCount: Int {
        lock.withLock { replaceAttempts }
    }

    var lastReplacement: PrivateSettings? {
        lock.withLock { replacements.last }
    }

    var storedSettings: PrivateSettings {
        lock.withLock { current }
    }
}

enum TestGoogleControllerOperation: Hashable, Sendable {
    case saveClientConfiguration
    case credentialPresence
    case begin
    case confirm
    case disconnect
}

actor TestAsyncGate {
    private var entered = false
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

final class RecordingGoogleConnectionController: GoogleConnectionControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var presenceStorage: GoogleCredentialPresence
    private let pendingIdentity: GooglePendingIdentity
    private let confirmationReceipt: GoogleConnectionReceipt
    private let progressEvents: [GoogleConnectionProgress]
    private let failures: [TestGoogleControllerOperation: GoogleConnectionControllerError]
    private let callRecorder: WorkflowCallRecorder?
    private let beginGate: TestAsyncGate?
    private let confirmGate: TestAsyncGate?
    private var saves = 0
    private var presenceReads = 0
    private var begins = 0
    private var confirms = 0
    private var cancels = 0
    private var disconnects = 0

    init(
        presence: GoogleCredentialPresence,
        pendingIdentity: GooglePendingIdentity,
        confirmationReceipt: GoogleConnectionReceipt,
        progressEvents: [GoogleConnectionProgress] = [.connecting, .awaitingConsent],
        failures: [TestGoogleControllerOperation: GoogleConnectionControllerError] = [:],
        callRecorder: WorkflowCallRecorder? = nil,
        beginGate: TestAsyncGate? = nil,
        confirmGate: TestAsyncGate? = nil
    ) {
        self.presenceStorage = presence
        self.pendingIdentity = pendingIdentity
        self.confirmationReceipt = confirmationReceipt
        self.progressEvents = progressEvents
        self.failures = failures
        self.callRecorder = callRecorder
        self.beginGate = beginGate
        self.confirmGate = confirmGate
    }

    func saveClientConfiguration(_ value: GoogleOAuthClientConfiguration) throws {
        let failure = lock.withLock { () -> GoogleConnectionControllerError? in
            saves += 1
            callRecorder?.append("controller.saveClientConfiguration")
            return failures[.saveClientConfiguration]
        }
        if let failure { throw failure }
        lock.withLock { presenceStorage = .clientOnly }
    }

    func credentialPresence() throws -> GoogleCredentialPresence {
        let result = lock.withLock { () -> Result<GoogleCredentialPresence, GoogleConnectionControllerError> in
            presenceReads += 1
            callRecorder?.append("controller.credentialPresence")
            if let failure = failures[.credentialPresence] {
                return .failure(failure)
            }
            return .success(presenceStorage)
        }
        return try result.get()
    }

    func begin(
        capability: GoogleGrantedCapability = .readOnly,
        progress: @escaping @Sendable (GoogleConnectionProgress) async -> Void
    ) async throws -> GooglePendingIdentity {
        let failure = lock.withLock { () -> GoogleConnectionControllerError? in
            begins += 1
            callRecorder?.append("controller.begin")
            return failures[.begin]
        }
        for event in progressEvents {
            await progress(event)
        }
        await beginGate?.wait()
        if let failure { throw failure }
        return pendingIdentity
    }

    func confirmPendingIdentity() async throws -> GoogleConnectionReceipt {
        let (confirmationNumber, failure) = lock.withLock {
            () -> (Int, GoogleConnectionControllerError?) in
            confirms += 1
            callRecorder?.append("controller.confirm")
            return (confirms, failures[.confirm])
        }
        if confirmationNumber == 1 {
            await confirmGate?.wait()
        }
        if let failure { throw failure }
        lock.withLock { presenceStorage = .complete }
        return confirmationReceipt
    }

    func cancelPendingConnection() async {
        lock.withLock {
            cancels += 1
            callRecorder?.append("controller.cancel")
        }
    }

    func disconnect() async throws {
        let failure = lock.withLock { () -> GoogleConnectionControllerError? in
            disconnects += 1
            callRecorder?.append("controller.disconnect")
            return failures[.disconnect]
        }
        if let failure { throw failure }
        lock.withLock { presenceStorage = .none }
    }

    func disconnectForReconsent() async throws {
        let failure = lock.withLock { () -> GoogleConnectionControllerError? in
            disconnects += 1
            callRecorder?.append("controller.disconnect")
            return failures[.disconnect]
        }
        if let failure { throw failure }
        lock.withLock { presenceStorage = .none }
    }

    var saveCount: Int {
        lock.withLock { saves }
    }

    var credentialPresenceCount: Int {
        lock.withLock { presenceReads }
    }

    var beginCount: Int {
        lock.withLock { begins }
    }

    var confirmCount: Int {
        lock.withLock { confirms }
    }

    var cancelCount: Int {
        lock.withLock { cancels }
    }

    var disconnectCount: Int {
        lock.withLock { disconnects }
    }
}

struct ConnectionWorkflowHarness {
    let controller: RecordingGoogleConnectionController
    let store: RecordingSettingsStore
    let recorder: WorkflowCallRecorder
    let initialSettings: PrivateSettings
    let workflow: GoogleConnectionWorkflow

    init(
        presence: GoogleCredentialPresence,
        pending: String = "owner@example.test",
        binding: String? = nil,
        receiptBinding: String? = nil,
        settingsMode: TestStoreMode = .working,
        failingLoadNumbers: Set<Int> = [],
        controllerFailures: [TestGoogleControllerOperation: GoogleConnectionControllerError] = [:],
        progressEvents: [GoogleConnectionProgress] = [.connecting, .awaitingConsent],
        beginGate: TestAsyncGate? = nil,
        confirmGate: TestAsyncGate? = nil
    ) {
        let pendingBinding = try! GoogleIdentityBinding(normalizing: pending)
        let receiptBinding = try! GoogleIdentityBinding(normalizing: receiptBinding ?? pending)
        let storedBinding = binding.map { try! GoogleIdentityBinding(normalizing: $0) }
        let calendarID = CalendarID(rawValue: "calendar-fixture")
        let audit = CalendarRoleAuditEntry(
            calendarID: calendarID,
            oldRole: .excludedReference,
            newRole: .planning,
            actor: .localUser,
            changedAt: Date(timeIntervalSince1970: 123_456)
        )
        let settings = PrivateSettings(
            schemaVersion: PrivateSettings.currentSchemaVersion,
            vaultBookmark: Data([0x01, 0x02, 0x03]),
            googleAccountBinding: storedBinding,
            calendarRoles: [calendarID: .planning],
            calendarRoleAudit: [audit]
        )
        let recorder = WorkflowCallRecorder()
        let store = RecordingSettingsStore(
            initial: settings,
            mode: settingsMode,
            callRecorder: recorder,
            failingLoadNumbers: failingLoadNumbers
        )
        let controller = RecordingGoogleConnectionController(
            presence: presence,
            pendingIdentity: GooglePendingIdentity(
                displayEmail: pending,
                binding: pendingBinding
            ),
            confirmationReceipt: GoogleConnectionReceipt(
                scopes: ["gmail.readonly", "calendar.readonly", "tasks.readonly"],
                refreshSucceeded: true,
                gmailProfileRead: true,
                calendarListRead: true,
                taskListsRead: true,
                binding: receiptBinding
            ),
            progressEvents: progressEvents,
            failures: controllerFailures,
            callRecorder: recorder,
            beginGate: beginGate,
            confirmGate: confirmGate
        )
        self.controller = controller
        self.store = store
        self.recorder = recorder
        self.initialSettings = settings
        self.workflow = GoogleConnectionWorkflow(
            controller: controller,
            settingsStore: store
        )
    }
}

struct FixedClock: PlannerClock, Sendable {
    let now: Date
}

enum TestCalendarSourceMode: Sendable {
    case working
    case failCatalog
    case failPlanningRead
    case failReferenceView
}

final class WorkflowCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []

    func append(_ call: String) {
        lock.withLock { calls.append(call) }
    }

    var recordedCalls: [String] {
        lock.withLock { calls }
    }
}

final class RecordingCalendarSource:
    CalendarCatalogReading,
    PlanningCalendarReading,
    ExcludedReferenceViewing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var catalogStorage: [CalendarDescriptor]
    private var eventStorage: [PlannerEvent]
    private let mode: TestCalendarSourceMode
    private let callRecorder: WorkflowCallRecorder?
    private var planningIDs: Set<CalendarID> = []
    private var planningReads = 0
    private var referenceReads = 0

    init(
        catalog: [CalendarDescriptor],
        events: [PlannerEvent],
        mode: TestCalendarSourceMode = .working,
        callRecorder: WorkflowCallRecorder? = nil
    ) {
        self.catalogStorage = catalog
        self.eventStorage = events
        self.mode = mode
        self.callRecorder = callRecorder
    }

    func calendars() async throws -> [CalendarDescriptor] {
        try lock.withLock {
            callRecorder?.append("catalog")
            guard mode != .failCatalog else { throw TestFixtureError.injected }
            return catalogStorage
        }
    }

    func planningEvents(
        calendarIDs: Set<CalendarID>,
        interval: DateInterval
    ) async throws -> [PlannerEvent] {
        try lock.withLock {
            planningReads += 1
            planningIDs = calendarIDs
            callRecorder?.append("planning.read")
            guard mode != .failPlanningRead else { throw TestFixtureError.injected }
            return eventStorage
        }
    }

    func referenceEvents(
        calendarID: CalendarID,
        interval: DateInterval
    ) async throws -> [PlannerEvent] {
        try lock.withLock {
            referenceReads += 1
            callRecorder?.append("reference.view")
            guard mode != .failReferenceView else { throw TestFixtureError.injected }
            return eventStorage.filter { $0.calendarID == calendarID }
        }
    }

    func replaceTitle(with title: String, for eventID: String) {
        lock.withLock {
            guard let index = eventStorage.firstIndex(where: { $0.id == eventID }) else { return }
            let event = eventStorage[index]
            eventStorage[index] = PlannerEvent(
                id: event.id,
                calendarID: event.calendarID,
                title: title,
                category: event.category,
                kind: event.kind,
                start: event.start,
                end: event.end,
                due: event.due
            )
        }
    }

    var requestedPlanningIDs: Set<CalendarID> {
        lock.withLock { planningIDs }
    }

    var planningReadCallCount: Int {
        lock.withLock { planningReads }
    }

    var referenceViewCallCount: Int {
        lock.withLock { referenceReads }
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
