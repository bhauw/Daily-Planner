import Foundation

public protocol CalendarCatalogReading: Sendable {
    func calendars() async throws -> [CalendarDescriptor]
}

public protocol PlanningCalendarReading: Sendable {
    func planningEvents(calendarIDs: Set<CalendarID>, interval: DateInterval) async throws -> [PlannerEvent]
}

public protocol ExcludedReferenceViewing: Sendable {
    func referenceEvents(calendarID: CalendarID, interval: DateInterval) async throws -> [PlannerEvent]
}

public protocol PlannerClock: Sendable {
    var now: Date { get }
}

/// The Google colours actually in use in the connected account, each with its real swatch.
/// Colour data is non-content metadata — safe to display — unlike a calendar title.
public protocol ColorCatalogReading: Sendable {
    func colorsInUse() async throws -> [ColorCatalogEntry]
}

// MARK: - Task lists

/// One task as the planner understands it. A task carries a DATE, never a time-of-day — the
/// clock time belongs to the focus block that schedules the work, not to the task itself.
public struct PlannerTaskItem: Hashable, Sendable {
    public let id: String
    public let title: String
    public let category: PlannerCategory
    public let due: Date?
    public let isCompleted: Bool

    public init(
        id: String,
        title: String,
        category: PlannerCategory,
        due: Date?,
        isCompleted: Bool
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.due = due
        self.isCompleted = isCompleted
    }
}

public struct PlannerTaskList: Hashable, Sendable {
    public let name: String
    public let items: [PlannerTaskItem]

    public init(name: String, items: [PlannerTaskItem]) {
        self.name = name
        self.items = items
    }
}

/// Reads the user's task lists. Implemented over Google Tasks in production; the API falls back
/// to synthetic content when no account is connected.
public protocol PlannerTaskListReading: Sendable {
    func taskLists() async throws -> [PlannerTaskList]
}

// MARK: - Mail triage

/// One inbox item as the planner shows it. This round is read-only triage: the planner surfaces
/// threads that may need a reply, and never invents a draft body — nothing is generated and
/// nothing is sent.
public struct PlannerMailItem: Hashable, Sendable {
    public let id: String
    /// The message subject.
    public let title: String
    /// A short snippet. Redacted when the source classified the message as private.
    public let summary: String
    public let sender: String
    public let receivedAt: Date
    public let category: PlannerCategory
    /// True when the classifier marked the source private; the UI must not show its content.
    public let isPrivate: Bool
    /// Still unread at the provider. Triage can be narrowed to these — the question a digest
    /// answers is what still needs attention, not what arrived.
    public let isUnread: Bool
    /// A promotion, a social notification, or spam: mail that is delivered TO you rather than
    /// written FOR you. Hidden from triage rather than ranked last, because a list you have to
    /// scroll past is not a list that got triaged.
    ///
    /// Decided by the mail source from the provider's own classification, so the domain never
    /// learns a provider's label names.
    public let isBulk: Bool
    /// The provider thread this belongs to.
    ///
    /// Read all the way through from Gmail and then dropped here, which meant a reply composed
    /// from this row would have started a NEW conversation beside the one it answered. Carrying
    /// it is the difference between a reply and a stray message with a matching subject.
    public let threadID: String?

    public init(
        id: String,
        title: String,
        summary: String,
        sender: String,
        receivedAt: Date,
        category: PlannerCategory,
        isPrivate: Bool,
        isUnread: Bool = false,
        isBulk: Bool = false,
        threadID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.sender = sender
        self.receivedAt = receivedAt
        self.category = category
        self.isPrivate = isPrivate
        self.isUnread = isUnread
        self.isBulk = isBulk
        self.threadID = threadID
    }
}

/// Reads recent inbox items for triage. Implemented over Gmail in production; the API falls back
/// to synthetic content when no account is connected.
public protocol PlannerMailReading: Sendable {
    func mailItems(limit: Int) async throws -> [PlannerMailItem]
}
