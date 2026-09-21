import Foundation
import XCTest
@testable import DailyPlannerDomain
@testable import DailyPlannerApplication

final class ReferenceCalendarWorkflowTests: XCTestCase {
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

    func testManualReferenceViewDoesNotPersistOrRefreshPlanningState() async throws {
        let store = RecordingSettingsStore(initial: PrivateSettings(
            vaultBookmark: nil,
            calendarRoles: [referenceCalendar.id: .excludedReference],
            calendarRoleAudit: []
        ))
        let source = RecordingCalendarSource(
            catalog: [referenceCalendar],
            events: [referenceCanaryEvent]
        )
        let workflow = ReferenceCalendarWorkflow(referenceReader: source, settingsReader: store)

        let view = try await workflow.view(calendarID: referenceCalendar.id, interval: interval)

        XCTAssertEqual(view.events.map(\.id), [referenceCanaryEvent.id])
        XCTAssertEqual(store.replaceCount, 0)
        XCTAssertEqual(source.planningReadCallCount, 0)
    }

    func testPlanningCalendarCannotBeViewedThroughReferenceWorkflow() async {
        let store = RecordingSettingsStore(initial: PrivateSettings(
            vaultBookmark: nil,
            calendarRoles: [planningCalendar.id: .planning],
            calendarRoleAudit: []
        ))
        let source = RecordingCalendarSource(catalog: [planningCalendar], events: [])
        let workflow = ReferenceCalendarWorkflow(referenceReader: source, settingsReader: store)

        do {
            _ = try await workflow.view(calendarID: planningCalendar.id, interval: interval)
            XCTFail("Expected calendarIsNotExcludedReference")
        } catch {
            XCTAssertEqual(error as? PlanningWorkflowError, .calendarIsNotExcludedReference)
        }
        XCTAssertEqual(source.referenceViewCallCount, 0)
    }

    func testMissingRoleDefaultsToExcludedForManualReferenceView() async throws {
        let source = RecordingCalendarSource(
            catalog: [referenceCalendar],
            events: [referenceCanaryEvent]
        )
        let workflow = ReferenceCalendarWorkflow(
            referenceReader: source,
            settingsReader: RecordingSettingsStore(initial: .empty)
        )

        let view = try await workflow.view(calendarID: referenceCalendar.id, interval: interval)

        XCTAssertEqual(view.events.map(\.id), [referenceCanaryEvent.id])
    }

    func testSettingsFailureMapsToFiniteErrorBeforeReferenceRead() async {
        let source = RecordingCalendarSource(catalog: [referenceCalendar], events: [referenceCanaryEvent])
        let workflow = ReferenceCalendarWorkflow(
            referenceReader: source,
            settingsReader: RecordingSettingsStore(initial: .empty, mode: .failLoad)
        )

        do {
            _ = try await workflow.view(calendarID: referenceCalendar.id, interval: interval)
            XCTFail("Expected settingsUnavailable")
        } catch {
            XCTAssertEqual(error as? PlanningWorkflowError, .settingsUnavailable)
        }
        XCTAssertEqual(source.referenceViewCallCount, 0)
    }

    func testReferenceReaderFailureMapsToFiniteError() async {
        let source = RecordingCalendarSource(
            catalog: [referenceCalendar],
            events: [referenceCanaryEvent],
            mode: .failReferenceView
        )
        let workflow = ReferenceCalendarWorkflow(
            referenceReader: source,
            settingsReader: RecordingSettingsStore(initial: .empty)
        )

        do {
            _ = try await workflow.view(calendarID: referenceCalendar.id, interval: interval)
            XCTFail("Expected referenceViewUnavailable")
        } catch {
            XCTAssertEqual(error as? PlanningWorkflowError, .referenceViewUnavailable)
        }
    }
}
