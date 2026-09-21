import Foundation

public enum CalendarRolePolicy {
    public static func role(
        for id: CalendarID,
        assignments: [CalendarID: CalendarRole]?
    ) -> CalendarRole {
        assignments?[id] ?? .excludedReference
    }

    public static func planningCalendarIDs(
        catalog: [CalendarDescriptor],
        assignments: [CalendarID: CalendarRole]?
    ) -> Set<CalendarID> {
        Set(catalog.lazy.filter { role(for: $0.id, assignments: assignments) == .planning }.map(\.id))
    }
}
