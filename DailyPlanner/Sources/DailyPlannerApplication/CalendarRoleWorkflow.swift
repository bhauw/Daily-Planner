import Foundation
import DailyPlannerDomain

public enum CalendarRoleChangeResult: Equatable, Sendable {
    case unchanged
    case saved(requiresValidatedRefresh: Bool)
}

public struct CalendarRoleRow: Equatable, Sendable {
    public let calendarID: CalendarID
    public let displayName: String
    public let role: CalendarRole

    public init(calendarID: CalendarID, displayName: String, role: CalendarRole) {
        self.calendarID = calendarID
        self.displayName = displayName
        self.role = role
    }
}

public struct CalendarRoleWorkflow: Sendable {
    private let settingsStore: any PrivateSettingsStore
    private let catalogReader: any CalendarCatalogReading

    public init(
        settingsStore: any PrivateSettingsStore,
        catalogReader: any CalendarCatalogReading
    ) {
        self.settingsStore = settingsStore
        self.catalogReader = catalogReader
    }

    public func rows() async throws -> [CalendarRoleRow] {
        let catalog: [CalendarDescriptor]
        do {
            catalog = try await catalogReader.calendars()
        } catch {
            throw PlanningWorkflowError.catalogUnavailable
        }

        let settings: PrivateSettings
        do {
            settings = try settingsStore.load()
        } catch {
            throw PlanningWorkflowError.settingsUnavailable
        }

        return catalog.map { calendar in
            CalendarRoleRow(
                calendarID: calendar.id,
                displayName: calendar.displayName,
                role: CalendarRolePolicy.role(
                    for: calendar.id,
                    assignments: settings.calendarRoles
                )
            )
        }.sorted { lhs, rhs in
            if lhs.displayName != rhs.displayName {
                return lhs.displayName < rhs.displayName
            }
            return lhs.calendarID.rawValue < rhs.calendarID.rawValue
        }
    }

    public func role(for calendarID: CalendarID) throws -> CalendarRole {
        let settings: PrivateSettings
        do {
            settings = try settingsStore.load()
        } catch {
            throw PlanningWorkflowError.settingsUnavailable
        }
        return CalendarRolePolicy.role(for: calendarID, assignments: settings.calendarRoles)
    }

    public func setRole(
        _ role: CalendarRole,
        for calendarID: CalendarID,
        at changedAt: Date
    ) throws -> CalendarRoleChangeResult {
        var settings: PrivateSettings
        do {
            settings = try settingsStore.load()
        } catch {
            throw PlanningWorkflowError.settingsUnavailable
        }

        let oldRole = CalendarRolePolicy.role(
            for: calendarID,
            assignments: settings.calendarRoles
        )
        guard oldRole != role else {
            return .unchanged
        }

        settings.calendarRoles[calendarID] = role
        settings.calendarRoleAudit.append(CalendarRoleAuditEntry(
            calendarID: calendarID,
            oldRole: oldRole,
            newRole: role,
            actor: .localUser,
            changedAt: changedAt
        ))

        do {
            try settingsStore.replace(settings)
        } catch {
            throw PlanningWorkflowError.settingsUnavailable
        }
        return .saved(requiresValidatedRefresh: true)
    }
}
