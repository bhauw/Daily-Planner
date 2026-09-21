import Foundation
import XCTest
@testable import DailyPlannerDomain
@testable import DailyPlannerApplication

final class CalendarRoleWorkflowTests: XCTestCase {
    private let planningCalendar = CalendarDescriptor(
        id: CalendarID(rawValue: "synthetic-planning-fixture"),
        displayName: "Synthetic Planning Fixture"
    )
    private let referenceCalendar = CalendarDescriptor(
        id: CalendarID(rawValue: "synthetic-reference-fixture"),
        displayName: "Synthetic Reference Fixture"
    )
    private let unknownCalendar = CalendarDescriptor(
        id: CalendarID(rawValue: "synthetic-unknown-fixture"),
        displayName: "Synthetic Unknown Fixture"
    )
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private var planningEvent: PlannerEvent {
        PlannerEvent(
            id: "synthetic-planning-event",
            calendarID: planningCalendar.id,
            title: "Synthetic planning item",
            category: .school,
            kind: .task,
            start: fixedNow,
            end: fixedNow.addingTimeInterval(1_800),
            due: fixedNow.addingTimeInterval(3_600)
        )
    }

    private var referenceCanaryEvent: PlannerEvent {
        PlannerEvent(
            id: "synthetic-reference-canary",
            calendarID: referenceCalendar.id,
            title: "Synthetic excluded canary",
            category: .personal,
            kind: .event,
            start: fixedNow,
            end: fixedNow.addingTimeInterval(1_800),
            due: nil
        )
    }

    func testRoleChangeAppendsEncryptedAuditAndInvalidatesPreview() throws {
        let store = RecordingSettingsStore(initial: PrivateSettings(
            vaultBookmark: nil,
            calendarRoles: [planningCalendar.id: .planning],
            calendarRoleAudit: []
        ))
        let source = RecordingCalendarSource(catalog: [planningCalendar], events: [planningEvent])
        let workflow = CalendarRoleWorkflow(settingsStore: store, catalogReader: source)

        let result = try workflow.setRole(.excludedReference, for: planningCalendar.id, at: fixedNow)

        XCTAssertEqual(result, .saved(requiresValidatedRefresh: true))
        XCTAssertEqual(store.replaceCount, 1)
        XCTAssertEqual(store.lastReplacement?.calendarRoleAudit.count, 1)
        XCTAssertEqual(store.lastReplacement?.calendarRoleAudit.last?.newRole, .excludedReference)
        XCTAssertEqual(store.lastReplacement?.calendarRoleAudit.last?.actor, .localUser)
    }

    func testUnknownCalendarIsReportedAsExcludedReference() throws {
        let store = RecordingSettingsStore(initial: .empty)
        let source = RecordingCalendarSource(catalog: [], events: [])
        let workflow = CalendarRoleWorkflow(settingsStore: store, catalogReader: source)

        XCTAssertEqual(try workflow.role(for: unknownCalendar.id), .excludedReference)
    }

    func testSettingsRowsLoadCatalogInMemoryAndDefaultMissingRoleToExcluded() async throws {
        let store = RecordingSettingsStore(initial: .empty)
        let source = RecordingCalendarSource(catalog: [referenceCalendar], events: [])
        let workflow = CalendarRoleWorkflow(settingsStore: store, catalogReader: source)

        let rows = try await workflow.rows()

        XCTAssertEqual(rows, [CalendarRoleRow(
            calendarID: referenceCalendar.id,
            displayName: referenceCalendar.displayName,
            role: .excludedReference
        )])
        XCTAssertEqual(store.replaceCount, 0)
    }

    func testRowsSortByDisplayNameThenOpaqueIdentifier() async throws {
        let firstID = CalendarID(rawValue: "synthetic-sort-a")
        let secondID = CalendarID(rawValue: "synthetic-sort-b")
        let source = RecordingCalendarSource(catalog: [
            CalendarDescriptor(id: secondID, displayName: "Synthetic Same"),
            CalendarDescriptor(id: referenceCalendar.id, displayName: "Synthetic Zeta"),
            CalendarDescriptor(id: firstID, displayName: "Synthetic Same"),
        ], events: [])
        let workflow = CalendarRoleWorkflow(
            settingsStore: RecordingSettingsStore(initial: .empty),
            catalogReader: source
        )

        let rows = try await workflow.rows()

        XCTAssertEqual(rows.map(\.calendarID), [firstID, secondID, referenceCalendar.id])
    }

    func testEventContentCannotChangeStoredRole() throws {
        let store = RecordingSettingsStore(initial: PrivateSettings(
            vaultBookmark: nil,
            calendarRoles: [referenceCalendar.id: .excludedReference],
            calendarRoleAudit: []
        ))
        let source = RecordingCalendarSource(catalog: [referenceCalendar], events: [referenceCanaryEvent])
        let workflow = CalendarRoleWorkflow(settingsStore: store, catalogReader: source)
        let before = try workflow.role(for: referenceCalendar.id)

        source.replaceTitle(with: "Synthetic planning-like title", for: referenceCanaryEvent.id)

        XCTAssertEqual(try workflow.role(for: referenceCalendar.id), before)
    }

    func testChangingToPlanningRequiresASeparateValidatedRefresh() throws {
        let store = RecordingSettingsStore(initial: PrivateSettings(
            vaultBookmark: nil,
            calendarRoles: [referenceCalendar.id: .excludedReference],
            calendarRoleAudit: []
        ))
        let source = RecordingCalendarSource(catalog: [referenceCalendar], events: [referenceCanaryEvent])
        let workflow = CalendarRoleWorkflow(settingsStore: store, catalogReader: source)
        let existingPreview = PlanningPreview.build(eligibleEvents: [], now: fixedNow)

        XCTAssertEqual(
            try workflow.setRole(.planning, for: referenceCalendar.id, at: fixedNow),
            .saved(requiresValidatedRefresh: true)
        )
        XCTAssertFalse(existingPreview.allSourceIDs.contains(referenceCanaryEvent.id))
    }

    func testSettingExistingRoleIsUnchangedWithoutAuditOrReplacement() throws {
        let store = RecordingSettingsStore(initial: PrivateSettings(
            vaultBookmark: nil,
            calendarRoles: [planningCalendar.id: .planning],
            calendarRoleAudit: []
        ))
        let workflow = CalendarRoleWorkflow(
            settingsStore: store,
            catalogReader: RecordingCalendarSource(catalog: [planningCalendar], events: [])
        )

        XCTAssertEqual(
            try workflow.setRole(.planning, for: planningCalendar.id, at: fixedNow),
            .unchanged
        )
        XCTAssertEqual(store.replaceCount, 0)
    }

    func testRoleLoadFailureMapsToFiniteSettingsError() {
        let workflow = CalendarRoleWorkflow(
            settingsStore: RecordingSettingsStore(initial: .empty, mode: .failLoad),
            catalogReader: RecordingCalendarSource(catalog: [], events: [])
        )

        XCTAssertThrowsError(try workflow.role(for: unknownCalendar.id)) { error in
            XCTAssertEqual(error as? PlanningWorkflowError, .settingsUnavailable)
        }
    }

    func testRoleReplaceFailureMapsToFiniteSettingsError() {
        let store = RecordingSettingsStore(initial: .empty, mode: .failReplace)
        let workflow = CalendarRoleWorkflow(
            settingsStore: store,
            catalogReader: RecordingCalendarSource(catalog: [], events: [])
        )

        XCTAssertThrowsError(
            try workflow.setRole(.planning, for: unknownCalendar.id, at: fixedNow)
        ) { error in
            XCTAssertEqual(error as? PlanningWorkflowError, .settingsUnavailable)
        }
        XCTAssertEqual(store.replaceCount, 0)
    }

    func testRowsCatalogFailureMapsToFiniteCatalogError() async {
        let workflow = CalendarRoleWorkflow(
            settingsStore: RecordingSettingsStore(initial: .empty),
            catalogReader: RecordingCalendarSource(catalog: [], events: [], mode: .failCatalog)
        )

        do {
            _ = try await workflow.rows()
            XCTFail("Expected catalogUnavailable")
        } catch {
            XCTAssertEqual(error as? PlanningWorkflowError, .catalogUnavailable)
        }
    }
}
