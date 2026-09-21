import Foundation
import XCTest
@testable import DailyPlannerDomain
@testable import DailyPlannerApplication

final class PlanningPreviewWorkflowTests: XCTestCase {
    private let planningCalendar = CalendarDescriptor(
        id: CalendarID(rawValue: "synthetic-planning-fixture"),
        displayName: "Synthetic Planning Fixture"
    )
    private let referenceCalendar = CalendarDescriptor(
        id: CalendarID(rawValue: "synthetic-reference-fixture"),
        displayName: "Synthetic Reference Fixture"
    )
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private var interval: DateInterval {
        DateInterval(start: fixedNow, duration: 86_400)
    }

    private var planningEvent: PlannerEvent {
        PlannerEvent(
            id: "synthetic-planning-event",
            calendarID: planningCalendar.id,
            title: "Synthetic planning item",
            category: .school,
            kind: .task,
            start: fixedNow.addingTimeInterval(3_600),
            end: fixedNow.addingTimeInterval(5_400),
            due: fixedNow.addingTimeInterval(7_200)
        )
    }

    private var referenceCanaryEvent: PlannerEvent {
        PlannerEvent(
            id: "synthetic-reference-canary",
            calendarID: referenceCalendar.id,
            title: "Synthetic excluded canary",
            category: .personal,
            kind: .event,
            start: fixedNow.addingTimeInterval(1_800),
            end: fixedNow.addingTimeInterval(2_700),
            due: nil
        )
    }

    func testRefreshRequestsOnlyPlanningIDsAndExcludedCanaryInfluencesNothing() async throws {
        let source = RecordingCalendarSource(
            catalog: [planningCalendar, referenceCalendar],
            events: [planningEvent, referenceCanaryEvent]
        )
        let settings = PrivateSettings(
            vaultBookmark: nil,
            calendarRoles: [
                planningCalendar.id: .planning,
                referenceCalendar.id: .excludedReference,
            ],
            calendarRoleAudit: []
        )
        let store = RecordingSettingsStore(initial: settings)
        let workflow = PlanningPreviewWorkflow(
            catalogReader: source,
            planningReader: source,
            settingsReader: store,
            clock: FixedClock(now: fixedNow)
        )

        let preview = try await workflow.refresh(interval: interval)

        XCTAssertEqual(source.requestedPlanningIDs, Set([planningCalendar.id]))
        XCTAssertFalse(preview.allSourceIDs.contains(referenceCanaryEvent.id))
        XCTAssertFalse(preview.influence.contains(referenceCanaryEvent.id))
        XCTAssertFalse(preview.queue.map(\.id).contains(referenceCanaryEvent.id))
        XCTAssertEqual(preview.queue.map(\.id), [planningEvent.id])
    }

    func testUnreadableSettingsFailsClosedBeforeAnyPlanningRead() async {
        let source = RecordingCalendarSource(catalog: [planningCalendar], events: [planningEvent])
        let store = RecordingSettingsStore(initial: .empty, mode: .failLoad)
        let workflow = PlanningPreviewWorkflow(
            catalogReader: source,
            planningReader: source,
            settingsReader: store,
            clock: FixedClock(now: fixedNow)
        )

        do {
            _ = try await workflow.refresh(interval: interval)
            XCTFail("Expected settingsUnavailable")
        } catch {
            XCTAssertEqual(error as? PlanningWorkflowError, .settingsUnavailable)
        }
        XCTAssertEqual(source.planningReadCallCount, 0)
    }

    func testRefreshUsesCatalogSettingsPlanningReadOrder() async throws {
        let calls = WorkflowCallRecorder()
        let source = RecordingCalendarSource(
            catalog: [planningCalendar],
            events: [planningEvent],
            callRecorder: calls
        )
        let store = RecordingSettingsStore(
            initial: PrivateSettings(
                vaultBookmark: nil,
                calendarRoles: [planningCalendar.id: .planning],
                calendarRoleAudit: []
            ),
            callRecorder: calls
        )
        let workflow = PlanningPreviewWorkflow(
            catalogReader: source,
            planningReader: source,
            settingsReader: store,
            clock: FixedClock(now: fixedNow)
        )

        _ = try await workflow.refresh(interval: interval)

        XCTAssertEqual(calls.recordedCalls, ["catalog", "settings.load", "planning.read"])
    }

    func testCatalogFailureMapsToFiniteErrorWithoutSettingsOrPlanningRead() async {
        let source = RecordingCalendarSource(
            catalog: [planningCalendar],
            events: [planningEvent],
            mode: .failCatalog
        )
        let store = RecordingSettingsStore(initial: .empty)
        let workflow = PlanningPreviewWorkflow(
            catalogReader: source,
            planningReader: source,
            settingsReader: store,
            clock: FixedClock(now: fixedNow)
        )

        await XCTAssertPlanningWorkflowError(.catalogUnavailable) {
            try await workflow.refresh(interval: interval)
        }
        XCTAssertEqual(store.loadCount, 0)
        XCTAssertEqual(source.planningReadCallCount, 0)
    }

    func testPlanningReaderFailureMapsToFiniteError() async {
        let source = RecordingCalendarSource(
            catalog: [planningCalendar],
            events: [planningEvent],
            mode: .failPlanningRead
        )
        let store = RecordingSettingsStore(initial: PrivateSettings(
            vaultBookmark: nil,
            calendarRoles: [planningCalendar.id: .planning],
            calendarRoleAudit: []
        ))
        let workflow = PlanningPreviewWorkflow(
            catalogReader: source,
            planningReader: source,
            settingsReader: store,
            clock: FixedClock(now: fixedNow)
        )

        await XCTAssertPlanningWorkflowError(.planningReadUnavailable) {
            try await workflow.refresh(interval: interval)
        }
    }
}

private func XCTAssertPlanningWorkflowError<T>(
    _ expected: PlanningWorkflowError,
    operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? PlanningWorkflowError, expected, file: file, line: line)
    }
}
