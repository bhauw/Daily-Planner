import XCTest
@testable import DailyPlannerApplication
@testable import DailyPlannerDomain
@testable import DailyPlannerPersistence
@testable import DailyPlannerPlatform

@MainActor
final class M1SafetyAcceptanceTests: XCTestCase {
    func testPersistedCanaryCheckDetectsActualLocalUserActorBytesWhenInjected() async throws {
        let harness = try M1AcceptanceHarness.makeGenerated()
        defer { harness.cleanup() }

        let onboardingResult = await harness.chooseGeneratedVaultRoot()
        XCTAssertEqual(onboardingResult, .selected)
        try harness.assign(.planning, to: harness.schoolCalendarID)
        XCTAssertFalse(harness.persistedBytesContainPrivateCanaries)

        try harness.injectActualPersistedActorBytesForMutationProof()

        XCTAssertTrue(harness.persistedBytesContainPrivateCanaries)
    }

    func testGeneratedConstructionFailureRemovesOnlyItsOwnedRoot() throws {
        let sibling = FileManager.default.temporaryDirectory
            .appendingPathComponent("daily-planner-m1-acceptance-sibling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: sibling) }
        var ownedRoot: URL?

        XCTAssertThrowsError(
            try M1AcceptanceHarness.makeGeneratedForBookmarkFailureProbe { root in
                ownedRoot = root
            }
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(ownedRoot).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    }

    func testM1EndToEndKeepsReferenceCanaryAndVaultContentsOutsidePlanning() async throws {
        let harness = try M1AcceptanceHarness.makeGenerated()
        defer { harness.cleanup() }

        let onboardingResult = await harness.chooseGeneratedVaultRoot()
        XCTAssertEqual(onboardingResult, .selected)
        try harness.assign(.planning, to: harness.schoolCalendarID)
        let preview = try await harness.refresh()
        let referenceView = try await harness.viewReferenceCalendar()

        XCTAssertTrue(preview.queue.contains { $0.category == .school })
        XCTAssertFalse(preview.allSourceIDs.contains(harness.referenceCanaryID))
        XCTAssertEqual(referenceView.events.map(\.id), [harness.referenceCanaryID])
        XCTAssertEqual(harness.folderPickerCallCount, 1)
        XCTAssertEqual(harness.settingsReplaceCount, 2)
        XCTAssertFalse(harness.persistedBytesContainPrivateCanaries)

        let finiteFailure = await harness.exerciseInjectedPathError()
        XCTAssertEqual(finiteFailure, .settingsUnavailable)
        XCTAssertFalse(String(describing: finiteFailure).contains(harness.pathShapedCanary))
    }
}

@MainActor
final class M1AcceptanceHarness {
    let schoolCalendarID: CalendarID
    let referenceCanaryID: String
    let pathShapedCanary: String

    private let generatedRoot: URL
    private let encryptedSettingsURL: URL
    private let syntheticBookmark: Data
    private let picker: AcceptanceFolderPicker
    private let settingsStore: AcceptanceRecordingSettingsStore
    private let source: AcceptanceCalendarSource
    private let onboarding: VaultOnboardingWorkflow
    private let roles: CalendarRoleWorkflow
    private let planning: PlanningPreviewWorkflow
    private let reference: ReferenceCalendarWorkflow
    private let previewInterval: DateInterval
    private var didCleanup = false

    private init(
        generatedRoot: URL,
        encryptedSettingsURL: URL,
        syntheticBookmark: Data,
        schoolCalendarID: CalendarID,
        referenceCanaryID: String,
        pathShapedCanary: String,
        picker: AcceptanceFolderPicker,
        settingsStore: AcceptanceRecordingSettingsStore,
        source: AcceptanceCalendarSource,
        onboarding: VaultOnboardingWorkflow,
        roles: CalendarRoleWorkflow,
        planning: PlanningPreviewWorkflow,
        reference: ReferenceCalendarWorkflow,
        previewInterval: DateInterval
    ) {
        self.generatedRoot = generatedRoot
        self.encryptedSettingsURL = encryptedSettingsURL
        self.syntheticBookmark = syntheticBookmark
        self.schoolCalendarID = schoolCalendarID
        self.referenceCanaryID = referenceCanaryID
        self.pathShapedCanary = pathShapedCanary
        self.picker = picker
        self.settingsStore = settingsStore
        self.source = source
        self.onboarding = onboarding
        self.roles = roles
        self.planning = planning
        self.reference = reference
        self.previewInterval = previewInterval
    }

    static func makeGenerated() throws -> M1AcceptanceHarness {
        try makeGenerated { root in
            try root.bookmarkData(options: [.withSecurityScope])
        }
    }

    fileprivate static func makeGeneratedForBookmarkFailureProbe(
        _ recordOwnedRoot: (URL) -> Void
    ) throws -> M1AcceptanceHarness {
        try makeGenerated { root in
            recordOwnedRoot(root)
            throw AcceptanceFixtureError.bookmarkCreationFailure
        }
    }

    private static func makeGenerated(
        bookmarkFactory: (URL) throws -> Data
    ) throws -> M1AcceptanceHarness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daily-planner-m1-acceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

        do {
            let encryptedSettingsURL = root.appendingPathComponent("private-settings-v1.envelope")
            let schoolCalendarID = CalendarID(rawValue: "synthetic-opaque-school-calendar-canary")
            let referenceCalendarID = CalendarID(rawValue: "synthetic-opaque-reference-calendar-canary")
            let referenceCanaryID = "synthetic-opaque-reference-event-canary"
            let syntheticBookmark = try bookmarkFactory(root)
            let pathShapedCanary = "/synthetic/private/canary"
            let fixedNow = Date(timeIntervalSince1970: 1_788_112_800)
            let interval = DateInterval(start: fixedNow, duration: 24 * 60 * 60)
            let source = AcceptanceCalendarSource(
                catalog: [
                    CalendarDescriptor(id: schoolCalendarID, displayName: "Synthetic School"),
                    CalendarDescriptor(id: referenceCalendarID, displayName: "Synthetic Reference"),
                ],
                events: [
                    PlannerEvent(
                        id: "synthetic-opaque-school-event-canary",
                        calendarID: schoolCalendarID,
                        title: "Synthetic school fixture",
                        category: .school,
                        kind: .deadline,
                        start: fixedNow.addingTimeInterval(9 * 60 * 60),
                        end: fixedNow.addingTimeInterval(10 * 60 * 60),
                        due: fixedNow.addingTimeInterval(16 * 60 * 60)
                    ),
                    PlannerEvent(
                        id: referenceCanaryID,
                        calendarID: referenceCalendarID,
                        title: "Synthetic reference fixture",
                        category: .personal,
                        kind: .event,
                        start: fixedNow.addingTimeInterval(11 * 60 * 60),
                        end: fixedNow.addingTimeInterval(12 * 60 * 60),
                        due: nil
                    ),
                ]
            )
            let picker = AcceptanceFolderPicker(result: syntheticBookmark)
            let keyProvider = AcceptanceKeyProvider(keyMaterial: Data(repeating: 0x5A, count: 32))
            let encryptedStore = EncryptedPrivateSettingsStore(
                storageURL: encryptedSettingsURL,
                keyProvider: keyProvider
            )
            let settingsStore = AcceptanceRecordingSettingsStore(store: encryptedStore)
            let onboarding = VaultOnboardingWorkflow(picker: picker, settingsStore: settingsStore)
            let roles = CalendarRoleWorkflow(settingsStore: settingsStore, catalogReader: source)
            let planning = PlanningPreviewWorkflow(
                catalogReader: source,
                planningReader: source,
                settingsReader: settingsStore,
                clock: AcceptanceFixedClock(now: fixedNow)
            )
            let reference = ReferenceCalendarWorkflow(referenceReader: source, settingsReader: settingsStore)

            return M1AcceptanceHarness(
                generatedRoot: root,
                encryptedSettingsURL: encryptedSettingsURL,
                syntheticBookmark: syntheticBookmark,
                schoolCalendarID: schoolCalendarID,
                referenceCanaryID: referenceCanaryID,
                pathShapedCanary: pathShapedCanary,
                picker: picker,
                settingsStore: settingsStore,
                source: source,
                onboarding: onboarding,
                roles: roles,
                planning: planning,
                reference: reference,
                previewInterval: interval
            )
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func chooseGeneratedVaultRoot() async -> VaultOnboardingState {
        await onboarding.chooseVaultRoot()
    }

    func assign(_ role: CalendarRole, to calendarID: CalendarID) throws {
        _ = try roles.setRole(role, for: calendarID, at: AcceptanceFixedClock.now)
    }

    func refresh() async throws -> PlanningPreview {
        let slots = try LocalSchedulePolicy.v1.scanSlots(on: AcceptanceFixedClock.now)
        guard slots.count == 3,
              LocalSchedulePolicy.v1.midnightEligibility(
                usageSincePreviousMidnight: true,
                eligibleSourceCount: 1
              ) == .eligible(sourceCount: 1) else {
            throw AcceptanceFixtureError.schedulePolicyUnavailable
        }
        return try await planning.refresh(interval: previewInterval)
    }

    func viewReferenceCalendar() async throws -> ReferenceCalendarView {
        let referenceCalendarID = try source.referenceCalendarID()
        return try await reference.view(calendarID: referenceCalendarID, interval: previewInterval)
    }

    func exerciseInjectedPathError() async -> PlanningWorkflowError {
        let workflow = PlanningPreviewWorkflow(
            catalogReader: source,
            planningReader: source,
            settingsReader: AcceptanceFailingSettingsReader(pathCanary: pathShapedCanary),
            clock: AcceptanceFixedClock(now: AcceptanceFixedClock.now)
        )
        do {
            _ = try await workflow.refresh(interval: previewInterval)
            return .settingsUnavailable
        } catch let error as PlanningWorkflowError {
            return error
        } catch {
            return .settingsUnavailable
        }
    }

    func cleanup() {
        guard !didCleanup else { return }
        didCleanup = true
        try? FileManager.default.removeItem(at: generatedRoot)
    }

    var folderPickerCallCount: Int { picker.callCount }

    var settingsReplaceCount: Int { settingsStore.replaceCount }

    fileprivate func injectActualPersistedActorBytesForMutationProof() throws {
        var persisted = try Data(contentsOf: encryptedSettingsURL)
        persisted.append(Data(CalendarRoleChangeActor.localUser.rawValue.utf8))
        try persisted.write(to: encryptedSettingsURL, options: .atomic)
    }

    var persistedBytesContainPrivateCanaries: Bool {
        guard let persisted = try? Data(contentsOf: encryptedSettingsURL) else { return false }
        let canaries = [
            syntheticBookmark,
            Data(schoolCalendarID.rawValue.utf8),
            Data(CalendarRoleChangeActor.localUser.rawValue.utf8),
            Data(pathShapedCanary.utf8),
        ]
        return canaries.contains { persisted.range(of: $0) != nil }
    }
}

private enum AcceptanceFixtureError: Error {
    case schedulePolicyUnavailable
    case injectedPath(String)
    case bookmarkCreationFailure
}

private struct AcceptanceFixedClock: PlannerClock, Sendable {
    static let now = Date(timeIntervalSince1970: 1_788_112_800)
    let now: Date
}

private final class AcceptanceKeyProvider: SettingsKeyMaterialProviding, @unchecked Sendable {
    private let keyMaterial: Data

    init(keyMaterial: Data) {
        self.keyMaterial = keyMaterial
    }

    func existingKeyMaterial() throws -> Data? { keyMaterial }
    func keyMaterialForWrite() throws -> Data { keyMaterial }
}

@MainActor
private final class AcceptanceFolderPicker: VaultFolderSelecting, @unchecked Sendable {
    private let result: Data
    private(set) var callCount = 0

    init(result: Data) {
        self.result = result
    }

    func selectRootBookmark() async throws -> Data? {
        callCount += 1
        return result
    }
}

private final class AcceptanceCalendarSource:
    CalendarCatalogReading,
    PlanningCalendarReading,
    ExcludedReferenceViewing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let catalog: [CalendarDescriptor]
    private let events: [PlannerEvent]

    init(catalog: [CalendarDescriptor], events: [PlannerEvent]) {
        self.catalog = catalog
        self.events = events
    }

    func calendars() async throws -> [CalendarDescriptor] { catalog }

    func planningEvents(
        calendarIDs: Set<CalendarID>,
        interval: DateInterval
    ) async throws -> [PlannerEvent] {
        events.filter { calendarIDs.contains($0.calendarID) && $0.start < interval.end && $0.end > interval.start }
    }

    func referenceEvents(
        calendarID: CalendarID,
        interval: DateInterval
    ) async throws -> [PlannerEvent] {
        events.filter { $0.calendarID == calendarID && $0.start < interval.end && $0.end > interval.start }
    }

    func referenceCalendarID() throws -> CalendarID {
        try lock.withLock {
            guard let id = catalog.first(where: { $0.displayName == "Synthetic Reference" })?.id else {
                throw AcceptanceFixtureError.schedulePolicyUnavailable
            }
            return id
        }
    }

}

private final class AcceptanceRecordingSettingsStore: PrivateSettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private let store: EncryptedPrivateSettingsStore
    private var replacements = 0

    init(store: EncryptedPrivateSettingsStore) {
        self.store = store
    }

    func load() throws -> PrivateSettings {
        try store.load()
    }

    func replace(_ settings: PrivateSettings) throws {
        try store.replace(settings)
        lock.withLock { replacements += 1 }
    }

    var replaceCount: Int {
        lock.withLock { replacements }
    }
}

private struct AcceptanceFailingSettingsReader: PrivateSettingsReading, Sendable {
    let pathCanary: String

    func load() throws -> PrivateSettings {
        throw AcceptanceFixtureError.injectedPath(pathCanary)
    }
}
