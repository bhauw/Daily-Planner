import Foundation
import DailyPlannerDomain

public struct ReferenceCalendarView: Equatable, Sendable {
    public let events: [PlannerEvent]

    public init(events: [PlannerEvent]) {
        self.events = events
    }
}

public struct ReferenceCalendarWorkflow: Sendable {
    private let referenceReader: any ExcludedReferenceViewing
    private let settingsReader: any PrivateSettingsReading

    public init(
        referenceReader: any ExcludedReferenceViewing,
        settingsReader: any PrivateSettingsReading
    ) {
        self.referenceReader = referenceReader
        self.settingsReader = settingsReader
    }

    public func view(
        calendarID: CalendarID,
        interval: DateInterval
    ) async throws -> ReferenceCalendarView {
        let settings: PrivateSettings
        do {
            settings = try settingsReader.load()
        } catch {
            throw PlanningWorkflowError.settingsUnavailable
        }

        guard CalendarRolePolicy.role(
            for: calendarID,
            assignments: settings.calendarRoles
        ) == .excludedReference else {
            throw PlanningWorkflowError.calendarIsNotExcludedReference
        }

        let returnedEvents: [PlannerEvent]
        do {
            returnedEvents = try await referenceReader.referenceEvents(
                calendarID: calendarID,
                interval: interval
            )
        } catch {
            throw PlanningWorkflowError.referenceViewUnavailable
        }

        return ReferenceCalendarView(
            events: returnedEvents.filter { $0.calendarID == calendarID }
        )
    }
}
