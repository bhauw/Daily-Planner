import Foundation

public enum GoogleAccessTokenError: Error, Equatable, Sendable {
    case invalidValue
}

public struct GoogleAccessToken: Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let rawValue: String

    public init(validating rawValue: String) throws {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 8_192 else {
            throw GoogleAccessTokenError.invalidValue
        }

        var reachedPadding = false
        var hasNonPaddingScalar = false
        for scalar in rawValue.unicodeScalars {
            if scalar.value == 0x3D {
                reachedPadding = true
                continue
            }
            guard !reachedPadding,
                  (0x30...0x39).contains(scalar.value)
                    || (0x41...0x5A).contains(scalar.value)
                    || (0x61...0x7A).contains(scalar.value)
                    || [0x2D, 0x2E, 0x5F, 0x7E, 0x2B, 0x2F].contains(scalar.value) else {
                throw GoogleAccessTokenError.invalidValue
            }
            hasNonPaddingScalar = true
        }
        guard hasNonPaddingScalar else { throw GoogleAccessTokenError.invalidValue }
        self.rawValue = rawValue
    }

    public func withUnsafeRawValue<T>(_ body: (String) throws -> T) rethrows -> T {
        try body(rawValue)
    }

    public var description: String { "GoogleAccessToken(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection()) }
}

public protocol GoogleAccessTokenProviding: Sendable {
    func accessToken() async throws -> GoogleAccessToken
}

public protocol GmailReading: Sendable {
    func messages(
        receivedAfter: Date, pageToken: GmailPageToken?, accessToken: GoogleAccessToken
    ) async throws -> GmailMessagePage
    func message(
        id: GmailMessageID, format: GmailMessageFormat, accessToken: GoogleAccessToken
    ) async throws -> GmailMessageRecord
    func changes(
        after historyID: GmailHistoryID, pageToken: GmailPageToken?, accessToken: GoogleAccessToken
    ) async throws -> GmailHistoryPage
}

public protocol GoogleCalendarReading: Sendable {
    func primaryCalendar(accessToken: GoogleAccessToken) async throws -> GoogleCalendarRecord
    /// Every readable calendar, primary and secondary alike, each carrying its Google
    /// colour. Secondary calendars are not dropped — their colours drive categorisation —
    /// while role assignment stays fail-closed (an unassigned calendar is Excluded reference,
    /// see `CalendarRolePolicy`), so a returned calendar is merely displayable, never
    /// silently promoted into planning.
    func calendars(accessToken: GoogleAccessToken) async throws -> [GoogleCalendarRecord]
    func events(
        calendarID: CalendarID, interval: DateInterval, syncToken: CalendarSyncToken?,
        pageToken: CalendarPageToken?, accessToken: GoogleAccessToken
    ) async throws -> CalendarEventPage
}

public protocol GoogleColorsReading: Sendable {
    func palette(accessToken: GoogleAccessToken) async throws -> GoogleColorPalette
}

public protocol GoogleTasksReading: Sendable {
    func taskLists(
        pageToken: GoogleTasksPageToken?, accessToken: GoogleAccessToken
    ) async throws -> GoogleTaskListPage
    func tasks(
        listID: GoogleTaskListID, updatedSince: Date?, pageToken: GoogleTasksPageToken?,
        accessToken: GoogleAccessToken
    ) async throws -> GoogleTasksPage
}

public protocol GoogleSnapshotCaching: Sendable {
    func loadState(for binding: GoogleIdentityBinding) async throws -> GoogleCommittedCacheState?
    func replaceState(_ state: GoogleCommittedCacheState, for binding: GoogleIdentityBinding) async throws
    func purge(for binding: GoogleIdentityBinding) async throws
}

public protocol GoogleContentClassifying: Sendable {
    func classify(_ input: GoogleContentClassificationInput) -> SourcePrivacyClass
}

public protocol EmailBodySanitizing: Sendable {
    func sanitize(kind: EmailBodyKind, decodedBody: String) throws -> SanitizedEmailBody
}
