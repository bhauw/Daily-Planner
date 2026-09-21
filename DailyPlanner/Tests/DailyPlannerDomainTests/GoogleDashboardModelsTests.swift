import DailyPlannerDomain
import Foundation
import XCTest

final class GoogleDashboardModelsTests: XCTestCase {
    func testM2BLimitsAreExact() {
        XCTAssertEqual(GoogleSyncLimits.gmailDays, 30)
        XCTAssertEqual(GoogleSyncLimits.gmailMessages, 200)
        XCTAssertEqual(GoogleSyncLimits.gmailPages, 10)
        XCTAssertEqual(GoogleSyncLimits.calendarDays, 7)
        XCTAssertEqual(GoogleSyncLimits.calendarEvents, 500)
        XCTAssertEqual(GoogleSyncLimits.calendarPages, 10)
        XCTAssertEqual(GoogleSyncLimits.taskLists, 50)
        XCTAssertEqual(GoogleSyncLimits.tasksPerList, 100)
        XCTAssertEqual(GoogleSyncLimits.tasksTotal, 500)
        XCTAssertEqual(GoogleSyncLimits.taskPagesPerList, 10)
        XCTAssertEqual(GoogleSyncLimits.taskOverlap, 300)
        XCTAssertEqual(GoogleSyncLimits.displayScalars, 512)
        XCTAssertEqual(GoogleSyncLimits.decodedBodyBytes, 512 * 1_024)
        XCTAssertEqual(GoogleSyncLimits.retention, 90 * 24 * 60 * 60)
    }

    func testAccessTokenNeverReflectsItsSecret() throws {
        let token = try GoogleAccessToken(validating: "synthetic-secret-token")

        XCTAssertEqual(String(describing: token), "GoogleAccessToken(redacted)")
        XCTAssertFalse(String(reflecting: token).contains("synthetic-secret-token"))
        XCTAssertEqual(token.withUnsafeRawValue { $0 }, "synthetic-secret-token")
    }

    func testAccessTokenEnforcesProviderBearerGrammar() throws {
        XCTAssertNoThrow(try GoogleAccessToken(validating: "Az09-._~+/=="))

        for invalid in ["", "=", "abc=def", "abc ", "abc\n", "abc:", String(repeating: "a", count: 8_193)] {
            XCTAssertThrowsError(try GoogleAccessToken(validating: invalid), "Accepted \(String(reflecting: invalid))")
        }
    }

    func testOpaqueIdentifiersValidateAndStayRedacted() throws {
        let id = try GmailMessageID(validating: "message/opaque-value")

        XCTAssertEqual(id.withUnsafeRawValue { $0 }, "message/opaque-value")
        XCTAssertEqual(String(describing: id), "GmailMessageID(redacted)")
        XCTAssertFalse(String(reflecting: id).contains("message/opaque-value"))
        XCTAssertThrowsError(try GmailMessageID(validating: ""))
        XCTAssertThrowsError(try GmailMessageID(validating: "message\u{7F}"))
        XCTAssertThrowsError(try JSONDecoder().decode(GmailMessageID.self, from: Data("\"\"".utf8)))
    }

    func testPublicConsumerCanConstructEveryRecordAndCapability() throws {
        let fixture = try PublicGoogleDomainFixture()

        XCTAssertEqual(fixture.cache.snapshot.calendarEvents, [fixture.event])
        XCTAssertEqual(fixture.cache.snapshot.tasks, [fixture.task])
        XCTAssertEqual(fixture.cache.snapshot.emails, [fixture.summary])
        XCTAssertEqual(fixture.messagePage.messages, [fixture.reference])
        XCTAssertEqual(fixture.historyPage.deletedMessageIDs, [fixture.messageID])
        XCTAssertEqual(fixture.eventPage.events, [fixture.event])
        XCTAssertEqual(fixture.taskListPage.lists, [fixture.taskList])
        XCTAssertEqual(fixture.tasksPage.tasks, [fixture.task])
        XCTAssertEqual(fixture.messageRecord.attachments, [fixture.attachment])
        XCTAssertEqual(fixture.calendar.displayName, "Primary")
        XCTAssertEqual(fixture.sanitizedBody, SanitizedEmailBody(kind: .plainText, value: "Body"))

        let _: any GoogleAccessTokenProviding = FakeAccessTokenProvider(token: fixture.accessToken)
        let _: any GmailReading = FakeGmailReader(fixture: fixture)
        let _: any GoogleCalendarReading = FakeCalendarReader(fixture: fixture)
        let _: any GoogleTasksReading = FakeTasksReader(fixture: fixture)
        let _: any GoogleSnapshotCaching = FakeSnapshotCache(state: fixture.cache)
        let _: any GoogleContentClassifying = FakeClassifier()
        let _: any EmailBodySanitizing = FakeSanitizer()
    }
}

private struct PublicGoogleDomainFixture: Sendable {
    let accessToken: GoogleAccessToken
    let messageID: GmailMessageID
    let reference: GmailMessageReference
    let summary: GmailMessageSummary
    let messageRecord: GmailMessageRecord
    let messagePage: GmailMessagePage
    let historyPage: GmailHistoryPage
    let attachment: EmailAttachmentMetadata
    let calendar: GoogleCalendarRecord
    let event: CalendarEventRecord
    let eventPage: CalendarEventPage
    let taskList: GoogleTaskList
    let task: GoogleTaskRecord
    let taskListPage: GoogleTaskListPage
    let tasksPage: GoogleTasksPage
    let sanitizedBody: SanitizedEmailBody
    let cache: GoogleCommittedCacheState

    init() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let messageID = try GmailMessageID(validating: "message-id")
        let threadID = try GmailThreadID(validating: "thread-id")
        let historyID = try GmailHistoryID(validating: "123")
        let gmailPageToken = try GmailPageToken(validating: "gmail-page")
        let calendarSyncToken = try CalendarSyncToken(validating: "calendar-sync")
        let calendarPageToken = try CalendarPageToken(validating: "calendar-page")
        let taskListID = try GoogleTaskListID(validating: "task-list-id")
        let taskID = try GoogleTaskID(validating: "task-id")
        let tasksPageToken = try GoogleTasksPageToken(validating: "tasks-page")
        let eventID = try GoogleCalendarEventID(validating: "event-id")
        let calendarID = CalendarID(rawValue: "primary")
        let summary = GmailMessageSummary(
            id: messageID,
            threadID: threadID,
            sender: "sender@example.com",
            subject: "Subject",
            receivedAt: now,
            labels: ["INBOX"],
            snippet: "Snippet",
            historyID: historyID,
            privacyClass: .ordinary
        )
        let attachment = EmailAttachmentMetadata(filename: "agenda.pdf", mimeType: "application/pdf", size: 42)
        let event = CalendarEventRecord(
            id: eventID,
            calendarID: calendarID,
            title: "Event",
            description: "Description",
            location: "Room 1",
            start: .dateTime(now, timeZoneIdentifier: "America/Vancouver"),
            end: .date(DateComponents(year: 2026, month: 9, day: 11)),
            status: .confirmed,
            updatedAt: now,
            privacyClass: .private
        )
        let taskList = GoogleTaskList(id: taskListID, title: "Tasks")
        let task = GoogleTaskRecord(
            id: taskID,
            listID: taskListID,
            listTitle: "Tasks",
            title: "Task",
            notes: "Notes",
            dueDate: DateComponents(year: 2026, month: 9, day: 12),
            updatedAt: now,
            isCompleted: false,
            isDeleted: false,
            privacyClass: .ordinary
        )
        let caps = GoogleResultCaps(calendar: false, tasks: true, gmail: false)
        let snapshot = GoogleDashboardSnapshot(
            calendarEvents: [event],
            tasks: [task],
            emails: [summary],
            syncedAt: now,
            caps: caps
        )
        let cursors = GoogleSyncCursors(
            gmailHistoryID: historyID,
            calendarSyncToken: calendarSyncToken,
            taskPollTime: now
        )

        accessToken = try GoogleAccessToken(validating: "token-value==")
        self.messageID = messageID
        reference = GmailMessageReference(id: messageID, threadID: threadID)
        self.summary = summary
        messageRecord = GmailMessageRecord(
            summary: summary,
            bodyKind: .html,
            decodedBody: "<p>Body</p>",
            attachments: [attachment]
        )
        messagePage = GmailMessagePage(messages: [reference], nextPageToken: gmailPageToken)
        historyPage = GmailHistoryPage(
            changedMessageIDs: [messageID],
            deletedMessageIDs: [messageID],
            nextPageToken: gmailPageToken,
            newestHistoryID: historyID
        )
        self.attachment = attachment
        calendar = GoogleCalendarRecord(id: calendarID, displayName: "Primary", isPrimary: true)
        self.event = event
        eventPage = CalendarEventPage(events: [event], nextPageToken: calendarPageToken, nextSyncToken: calendarSyncToken)
        self.taskList = taskList
        self.task = task
        taskListPage = GoogleTaskListPage(lists: [taskList], nextPageToken: tasksPageToken)
        tasksPage = GoogleTasksPage(tasks: [task], nextPageToken: tasksPageToken)
        sanitizedBody = SanitizedEmailBody(kind: .plainText, value: "Body")
        cache = GoogleCommittedCacheState(snapshot: snapshot, cursors: cursors)

        _ = GoogleContentClassificationInput.email(subject: "Subject", sender: "Sender", body: "Body", bodyKind: .plainText)
        _ = GoogleContentClassificationInput.event(title: "Event", description: nil, location: nil)
        _ = GoogleContentClassificationInput.task(title: "Task", notes: nil)
        _ = GoogleContentClassificationInput.unknown
        _ = GmailMessageFormat.metadata
        _ = GmailMessageFormat.full
        _ = GoogleEventStatus.tentative
        _ = GoogleEventStatus.cancelled
    }
}

private struct FakeAccessTokenProvider: GoogleAccessTokenProviding {
    let token: GoogleAccessToken
    func accessToken() async throws -> GoogleAccessToken { token }
}

private struct FakeGmailReader: GmailReading {
    let fixture: PublicGoogleDomainFixture
    func messages(receivedAfter: Date, pageToken: GmailPageToken?, accessToken: GoogleAccessToken) async throws -> GmailMessagePage { fixture.messagePage }
    func message(id: GmailMessageID, format: GmailMessageFormat, accessToken: GoogleAccessToken) async throws -> GmailMessageRecord { fixture.messageRecord }
    func changes(after historyID: GmailHistoryID, pageToken: GmailPageToken?, accessToken: GoogleAccessToken) async throws -> GmailHistoryPage { fixture.historyPage }
}

private struct FakeCalendarReader: GoogleCalendarReading {
    let fixture: PublicGoogleDomainFixture
    func primaryCalendar(accessToken: GoogleAccessToken) async throws -> GoogleCalendarRecord { fixture.calendar }
    func calendars(accessToken: GoogleAccessToken) async throws -> [GoogleCalendarRecord] { [fixture.calendar] }
    func events(calendarID: CalendarID, interval: DateInterval, syncToken: CalendarSyncToken?, pageToken: CalendarPageToken?, accessToken: GoogleAccessToken) async throws -> CalendarEventPage { fixture.eventPage }
}

private struct FakeTasksReader: GoogleTasksReading {
    let fixture: PublicGoogleDomainFixture
    func taskLists(pageToken: GoogleTasksPageToken?, accessToken: GoogleAccessToken) async throws -> GoogleTaskListPage { fixture.taskListPage }
    func tasks(listID: GoogleTaskListID, updatedSince: Date?, pageToken: GoogleTasksPageToken?, accessToken: GoogleAccessToken) async throws -> GoogleTasksPage { fixture.tasksPage }
}

private struct FakeSnapshotCache: GoogleSnapshotCaching {
    let state: GoogleCommittedCacheState
    func loadState(for binding: GoogleIdentityBinding) async throws -> GoogleCommittedCacheState? { state }
    func replaceState(_ state: GoogleCommittedCacheState, for binding: GoogleIdentityBinding) async throws {}
    func purge(for binding: GoogleIdentityBinding) async throws {}
}

private struct FakeClassifier: GoogleContentClassifying {
    func classify(_ input: GoogleContentClassificationInput) -> SourcePrivacyClass { .ordinary }
}

private struct FakeSanitizer: EmailBodySanitizing {
    func sanitize(kind: EmailBodyKind, decodedBody: String) throws -> SanitizedEmailBody {
        SanitizedEmailBody(kind: kind, value: decodedBody)
    }
}
