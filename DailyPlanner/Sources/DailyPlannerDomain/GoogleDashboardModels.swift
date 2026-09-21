import Foundation

public enum GoogleSyncLimits {
    public static let gmailDays = 30
    public static let gmailMessages = 200
    public static let gmailPages = 10
    public static let calendarDays = 7
    public static let calendarEvents = 500
    public static let calendarPages = 10
    public static let taskLists = 50
    public static let tasksPerList = 100
    public static let tasksTotal = 500
    public static let taskPagesPerList = 10
    public static let taskOverlap: TimeInterval = 5 * 60
    public static let displayScalars = 512
    public static let decodedBodyBytes = 512 * 1_024
    public static let retention: TimeInterval = 90 * 24 * 60 * 60
}

private enum GoogleOpaqueIdentifierError: Error {
    case invalidValue
}

private enum GoogleOpaqueIdentifierValidation {
    static func validate(_ value: String) throws -> String {
        guard !value.isEmpty,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw GoogleOpaqueIdentifierError.invalidValue
        }
        return value
    }
}

public struct GmailMessageID: Codable, Hashable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let rawValue: String
    public init(validating rawValue: String) throws { self.rawValue = try GoogleOpaqueIdentifierValidation.validate(rawValue) }
    public init(from decoder: Decoder) throws { try self.init(validating: decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public func withUnsafeRawValue<T>(_ body: (String) throws -> T) rethrows -> T { try body(rawValue) }
    public var description: String { "GmailMessageID(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection()) }
}

public struct GmailThreadID: Codable, Hashable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let rawValue: String
    public init(validating rawValue: String) throws { self.rawValue = try GoogleOpaqueIdentifierValidation.validate(rawValue) }
    public init(from decoder: Decoder) throws { try self.init(validating: decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public func withUnsafeRawValue<T>(_ body: (String) throws -> T) rethrows -> T { try body(rawValue) }
    public var description: String { "GmailThreadID(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection()) }
}

public struct GmailHistoryID: Codable, Hashable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let rawValue: String
    public init(validating rawValue: String) throws { self.rawValue = try GoogleOpaqueIdentifierValidation.validate(rawValue) }
    public init(from decoder: Decoder) throws { try self.init(validating: decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public func withUnsafeRawValue<T>(_ body: (String) throws -> T) rethrows -> T { try body(rawValue) }
    public var description: String { "GmailHistoryID(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection()) }
}

public struct GmailPageToken: Codable, Hashable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let rawValue: String
    public init(validating rawValue: String) throws { self.rawValue = try GoogleOpaqueIdentifierValidation.validate(rawValue) }
    public init(from decoder: Decoder) throws { try self.init(validating: decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public func withUnsafeRawValue<T>(_ body: (String) throws -> T) rethrows -> T { try body(rawValue) }
    public var description: String { "GmailPageToken(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection()) }
}

public struct CalendarSyncToken: Codable, Hashable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let rawValue: String
    public init(validating rawValue: String) throws { self.rawValue = try GoogleOpaqueIdentifierValidation.validate(rawValue) }
    public init(from decoder: Decoder) throws { try self.init(validating: decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public func withUnsafeRawValue<T>(_ body: (String) throws -> T) rethrows -> T { try body(rawValue) }
    public var description: String { "CalendarSyncToken(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection()) }
}

public struct CalendarPageToken: Codable, Hashable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let rawValue: String
    public init(validating rawValue: String) throws { self.rawValue = try GoogleOpaqueIdentifierValidation.validate(rawValue) }
    public init(from decoder: Decoder) throws { try self.init(validating: decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public func withUnsafeRawValue<T>(_ body: (String) throws -> T) rethrows -> T { try body(rawValue) }
    public var description: String { "CalendarPageToken(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection()) }
}

public struct GoogleTaskListID: Codable, Hashable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let rawValue: String
    public init(validating rawValue: String) throws { self.rawValue = try GoogleOpaqueIdentifierValidation.validate(rawValue) }
    public init(from decoder: Decoder) throws { try self.init(validating: decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public func withUnsafeRawValue<T>(_ body: (String) throws -> T) rethrows -> T { try body(rawValue) }
    public var description: String { "GoogleTaskListID(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection()) }
}

public struct GoogleTaskID: Codable, Hashable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let rawValue: String
    public init(validating rawValue: String) throws { self.rawValue = try GoogleOpaqueIdentifierValidation.validate(rawValue) }
    public init(from decoder: Decoder) throws { try self.init(validating: decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public func withUnsafeRawValue<T>(_ body: (String) throws -> T) rethrows -> T { try body(rawValue) }
    public var description: String { "GoogleTaskID(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection()) }
}

public struct GoogleTasksPageToken: Codable, Hashable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let rawValue: String
    public init(validating rawValue: String) throws { self.rawValue = try GoogleOpaqueIdentifierValidation.validate(rawValue) }
    public init(from decoder: Decoder) throws { try self.init(validating: decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public func withUnsafeRawValue<T>(_ body: (String) throws -> T) rethrows -> T { try body(rawValue) }
    public var description: String { "GoogleTasksPageToken(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection()) }
}

public struct GoogleCalendarEventID: Codable, Hashable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let rawValue: String
    public init(validating rawValue: String) throws { self.rawValue = try GoogleOpaqueIdentifierValidation.validate(rawValue) }
    public init(from decoder: Decoder) throws { try self.init(validating: decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public func withUnsafeRawValue<T>(_ body: (String) throws -> T) rethrows -> T { try body(rawValue) }
    public var description: String { "GoogleCalendarEventID(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection()) }
}

public enum SourcePrivacyClass: String, Codable, Equatable, Sendable {
    case ordinary, `private`
}

public enum EmailBodyKind: String, Codable, Equatable, Sendable {
    case plainText, html, unsupported
}

public struct SanitizedEmailBody: Equatable, Sendable {
    public let kind: EmailBodyKind
    public let value: String
    public init(kind: EmailBodyKind, value: String) {
        self.kind = kind
        self.value = value
    }
}

public enum GoogleContentClassificationInput: Equatable, Sendable {
    case email(subject: String, sender: String, body: String?, bodyKind: EmailBodyKind)
    case event(title: String, description: String?, location: String?)
    case task(title: String, notes: String?)
    case unknown
}

public struct GmailMessageReference: Codable, Equatable, Sendable {
    public let id: GmailMessageID
    public let threadID: GmailThreadID
    public init(id: GmailMessageID, threadID: GmailThreadID) {
        self.id = id
        self.threadID = threadID
    }
}

public struct GmailMessageSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: GmailMessageID
    public let threadID: GmailThreadID
    public let sender: String
    public let subject: String
    public let receivedAt: Date
    public let labels: [String]
    public let snippet: String
    public let historyID: GmailHistoryID
    public let privacyClass: SourcePrivacyClass
    public init(
        id: GmailMessageID, threadID: GmailThreadID, sender: String, subject: String,
        receivedAt: Date, labels: [String], snippet: String, historyID: GmailHistoryID,
        privacyClass: SourcePrivacyClass
    ) {
        self.id = id
        self.threadID = threadID
        self.sender = sender
        self.subject = subject
        self.receivedAt = receivedAt
        self.labels = labels
        self.snippet = snippet
        self.historyID = historyID
        self.privacyClass = privacyClass
    }
}

public struct GmailMessageRecord: Codable, Equatable, Sendable {
    public let summary: GmailMessageSummary
    public let bodyKind: EmailBodyKind
    public let decodedBody: String?
    public let attachments: [EmailAttachmentMetadata]
    public init(
        summary: GmailMessageSummary, bodyKind: EmailBodyKind, decodedBody: String?,
        attachments: [EmailAttachmentMetadata]
    ) {
        self.summary = summary
        self.bodyKind = bodyKind
        self.decodedBody = decodedBody
        self.attachments = attachments
    }
}

public struct GmailMessagePage: Equatable, Sendable {
    public let messages: [GmailMessageReference]
    public let nextPageToken: GmailPageToken?
    public init(messages: [GmailMessageReference], nextPageToken: GmailPageToken?) {
        self.messages = messages
        self.nextPageToken = nextPageToken
    }
}

public enum GmailMessageFormat: String, Equatable, Sendable {
    case metadata, full
}

public struct EmailAttachmentMetadata: Codable, Equatable, Sendable {
    public let filename: String
    public let mimeType: String
    public let size: Int
    public init(filename: String, mimeType: String, size: Int) {
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
    }
}

public struct GmailHistoryPage: Equatable, Sendable {
    public let changedMessageIDs: [GmailMessageID]
    public let deletedMessageIDs: [GmailMessageID]
    public let nextPageToken: GmailPageToken?
    public let newestHistoryID: GmailHistoryID
    public init(
        changedMessageIDs: [GmailMessageID], deletedMessageIDs: [GmailMessageID],
        nextPageToken: GmailPageToken?, newestHistoryID: GmailHistoryID
    ) {
        self.changedMessageIDs = changedMessageIDs
        self.deletedMessageIDs = deletedMessageIDs
        self.nextPageToken = nextPageToken
        self.newestHistoryID = newestHistoryID
    }
}

public struct GoogleCalendarRecord: Codable, Equatable, Sendable {
    public let id: CalendarID
    public let displayName: String
    public let isPrimary: Bool
    /// The calendar's Google `colorId`, if any. Events on this calendar with no colour
    /// of their own inherit it (see `GoogleColorCategory.effectiveColorID`).
    public let colorId: String?
    public let backgroundColor: String?
    public let foregroundColor: String?
    public init(
        id: CalendarID,
        displayName: String,
        isPrimary: Bool,
        colorId: String? = nil,
        backgroundColor: String? = nil,
        foregroundColor: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.isPrimary = isPrimary
        self.colorId = colorId
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
    }
}

public enum GoogleEventTime: Codable, Equatable, Sendable {
    case date(DateComponents)
    /// `timeZoneIdentifier` is nil when the provider sent none — the common case. The instant is
    /// already absolute; the identifier is only the event's declared zone when it has one.
    case dateTime(Date, timeZoneIdentifier: String?)
}

public enum GoogleEventStatus: String, Codable, Equatable, Sendable {
    case confirmed, tentative, cancelled
}

public struct CalendarEventRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: GoogleCalendarEventID
    public let calendarID: CalendarID
    public let title: String
    public let description: String?
    public let location: String?
    public let start: GoogleEventTime?
    public let end: GoogleEventTime?
    public let status: GoogleEventStatus
    public let updatedAt: Date?
    public let privacyClass: SourcePrivacyClass
    /// The event's own Google `colorId`, if it overrides its calendar's colour.
    /// Nil means the event inherits its calendar's colour.
    public let colorId: String?
    public init(
        id: GoogleCalendarEventID, calendarID: CalendarID, title: String,
        description: String?, location: String?, start: GoogleEventTime?,
        end: GoogleEventTime?, status: GoogleEventStatus, updatedAt: Date?,
        privacyClass: SourcePrivacyClass, colorId: String? = nil
    ) {
        self.id = id
        self.calendarID = calendarID
        self.title = title
        self.description = description
        self.location = location
        self.start = start
        self.end = end
        self.status = status
        self.updatedAt = updatedAt
        self.privacyClass = privacyClass
        self.colorId = colorId
    }
}

public struct CalendarEventPage: Equatable, Sendable {
    public let events: [CalendarEventRecord]
    public let nextPageToken: CalendarPageToken?
    public let nextSyncToken: CalendarSyncToken?
    public init(
        events: [CalendarEventRecord], nextPageToken: CalendarPageToken?,
        nextSyncToken: CalendarSyncToken?
    ) {
        self.events = events
        self.nextPageToken = nextPageToken
        self.nextSyncToken = nextSyncToken
    }
}

public struct GoogleTaskList: Codable, Equatable, Sendable, Identifiable {
    public let id: GoogleTaskListID
    public let title: String
    public init(id: GoogleTaskListID, title: String) {
        self.id = id
        self.title = title
    }
}

public struct GoogleTaskRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: GoogleTaskID
    public let listID: GoogleTaskListID
    public let listTitle: String
    public let title: String
    public let notes: String?
    public let dueDate: DateComponents?
    public let updatedAt: Date
    public let isCompleted: Bool
    public let isDeleted: Bool
    public let privacyClass: SourcePrivacyClass
    public init(
        id: GoogleTaskID, listID: GoogleTaskListID, listTitle: String, title: String,
        notes: String?, dueDate: DateComponents?, updatedAt: Date, isCompleted: Bool,
        isDeleted: Bool, privacyClass: SourcePrivacyClass
    ) {
        self.id = id
        self.listID = listID
        self.listTitle = listTitle
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.updatedAt = updatedAt
        self.isCompleted = isCompleted
        self.isDeleted = isDeleted
        self.privacyClass = privacyClass
    }
}

public struct GoogleTaskListPage: Equatable, Sendable {
    public let lists: [GoogleTaskList]
    public let nextPageToken: GoogleTasksPageToken?
    public init(lists: [GoogleTaskList], nextPageToken: GoogleTasksPageToken?) {
        self.lists = lists
        self.nextPageToken = nextPageToken
    }
}

public struct GoogleTasksPage: Equatable, Sendable {
    public let tasks: [GoogleTaskRecord]
    public let deletedTaskIDs: [GoogleTaskID]
    public let nextPageToken: GoogleTasksPageToken?
    public init(
        tasks: [GoogleTaskRecord],
        deletedTaskIDs: [GoogleTaskID] = [],
        nextPageToken: GoogleTasksPageToken?
    ) {
        self.tasks = tasks
        self.deletedTaskIDs = deletedTaskIDs
        self.nextPageToken = nextPageToken
    }
}

public struct GoogleResultCaps: Codable, Equatable, Sendable {
    public let calendar: Bool
    public let tasks: Bool
    public let gmail: Bool
    public init(calendar: Bool, tasks: Bool, gmail: Bool) {
        self.calendar = calendar
        self.tasks = tasks
        self.gmail = gmail
    }
}

public struct GoogleDashboardSnapshot: Codable, Equatable, Sendable {
    public let calendarEvents: [CalendarEventRecord]
    public let tasks: [GoogleTaskRecord]
    public let emails: [GmailMessageSummary]
    public let syncedAt: Date
    public let caps: GoogleResultCaps
    public init(
        calendarEvents: [CalendarEventRecord], tasks: [GoogleTaskRecord],
        emails: [GmailMessageSummary], syncedAt: Date, caps: GoogleResultCaps
    ) {
        self.calendarEvents = calendarEvents
        self.tasks = tasks
        self.emails = emails
        self.syncedAt = syncedAt
        self.caps = caps
    }
}

public struct GoogleSyncCursors: Codable, Equatable, Sendable {
    public let gmailHistoryID: GmailHistoryID?
    public let calendarSyncToken: CalendarSyncToken?
    public let taskPollTime: Date?
    public init(
        gmailHistoryID: GmailHistoryID? = nil,
        calendarSyncToken: CalendarSyncToken? = nil,
        taskPollTime: Date? = nil
    ) {
        self.gmailHistoryID = gmailHistoryID
        self.calendarSyncToken = calendarSyncToken
        self.taskPollTime = taskPollTime
    }
}

public struct GoogleCommittedCacheState: Codable, Equatable, Sendable {
    public let snapshot: GoogleDashboardSnapshot
    public let cursors: GoogleSyncCursors
    public init(snapshot: GoogleDashboardSnapshot, cursors: GoogleSyncCursors) {
        self.snapshot = snapshot
        self.cursors = cursors
    }
}
