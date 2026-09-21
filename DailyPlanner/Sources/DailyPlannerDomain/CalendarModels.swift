import Foundation

public struct CalendarID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum CalendarRole: String, Codable, Hashable, Sendable {
    case planning
    case excludedReference
}

public enum PlannerCategory: Int, Codable, CaseIterable, Hashable, Sendable {
    case school = 0
    case career = 1
    case finance = 2
    case personal = 3
    case other = 4
    /// A commute already present in the calendar. Scheduling must not add its own
    /// travel buffer on top of an adjacent commute block — that would double-count.
    case commute = 5
    /// A real job. Treated as a hard scheduling conflict, like a class or interview.
    case work = 6
}

public enum PlannerItemKind: String, Codable, Hashable, Sendable {
    case event, deadline, task, extracurricular, advertisement
}

public struct CalendarDescriptor: Hashable, Sendable {
    public let id: CalendarID
    public let displayName: String

    public init(id: CalendarID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct PlannerEvent: Hashable, Sendable {
    public let id: String
    public let calendarID: CalendarID
    public let title: String
    public let category: PlannerCategory
    public let kind: PlannerItemKind
    public let start: Date
    public let end: Date
    public let due: Date?

    public init(
        id: String,
        calendarID: CalendarID,
        title: String,
        category: PlannerCategory,
        kind: PlannerItemKind,
        start: Date,
        end: Date,
        due: Date?
    ) {
        self.id = id
        self.calendarID = calendarID
        self.title = title
        self.category = category
        self.kind = kind
        self.start = start
        self.end = end
        self.due = due
    }
}
