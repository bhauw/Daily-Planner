import Foundation
import os
import DailyPlannerDomain

public enum PlanningWorkflowError: Equatable, Error, Sendable {
    case settingsUnavailable
    case catalogUnavailable
    case planningReadUnavailable
    case referenceViewUnavailable
    case calendarIsNotExcludedReference
}

public struct PlanningPreviewWorkflow: Sendable {
    private let catalogReader: any CalendarCatalogReading
    private let planningReader: any PlanningCalendarReading
    private let settingsReader: any PrivateSettingsReading
    private let clock: any PlannerClock

    public init(
        catalogReader: any CalendarCatalogReading,
        planningReader: any PlanningCalendarReading,
        settingsReader: any PrivateSettingsReading,
        clock: any PlannerClock
    ) {
        self.catalogReader = catalogReader
        self.planningReader = planningReader
        self.settingsReader = settingsReader
        self.clock = clock
    }

    public func refresh(interval: DateInterval) async throws -> PlanningPreview {
        let catalog: [CalendarDescriptor]
        do {
            catalog = try await catalogReader.calendars()
        } catch {
            PlanningDiagnostics.record("catalog", error)
            throw PlanningWorkflowError.catalogUnavailable
        }

        let settings: PrivateSettings
        do {
            settings = try settingsReader.load()
        } catch {
            PlanningDiagnostics.record("settings", error)
            throw PlanningWorkflowError.settingsUnavailable
        }

        let planningIDs = CalendarRolePolicy.planningCalendarIDs(
            catalog: catalog,
            assignments: settings.calendarRoles
        )

        let returnedEvents: [PlannerEvent]
        do {
            returnedEvents = try await planningReader.planningEvents(
                calendarIDs: planningIDs,
                interval: interval
            )
        } catch {
            PlanningDiagnostics.record("planningRead", error)
            throw PlanningWorkflowError.planningReadUnavailable
        }

        let eligibleEvents = returnedEvents.filter { planningIDs.contains($0.calendarID) }
        return PlanningPreview.build(eligibleEvents: eligibleEvents, now: clock.now)
    }
}

/// Records *why* a planning refresh failed.
///
/// `PlanningWorkflowError` deliberately collapses every cause into one of three finite cases so
/// no provider detail reaches the client. That is right for the response and wrong for the
/// operator: a real calendar outage surfaced as a blank "Couldn't load your day" with the cause
/// discarded at this exact line. The error's *type and case* go to the unified log — never a
/// calendar title, event summary or URL.
enum PlanningDiagnostics {
    static let log = Logger(subsystem: "com.example.dailyplanner", category: "planning")

    static func record(_ stage: String, _ error: any Error) {
        log.error(
            "\(stage, privacy: .public) failed: \(String(describing: type(of: error)), privacy: .public) \(String(describing: error), privacy: .public)"
        )
    }
}
