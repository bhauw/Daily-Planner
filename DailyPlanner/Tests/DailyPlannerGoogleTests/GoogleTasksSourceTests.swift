import XCTest
import DailyPlannerDomain
@testable import DailyPlannerGoogle

/// Covers the adapter that turns live Google Tasks into the planner's task lists. The rules under
/// test are the ones that would fail silently: a deleted task reappearing, a due date sliding a
/// day because it was parsed as UTC, or a task acquiring a time-of-day it must never have.
final class GoogleTasksSourceTests: XCTestCase {
    private struct FakeTokens: GoogleAccessTokenProviding {
        func accessToken() async throws -> GoogleAccessToken {
            try GoogleAccessToken(validating: "test-token")
        }
    }

    private struct FakeTasks: GoogleTasksReading {
        var lists: [GoogleTaskList] = []
        var pagesByList: [String: [GoogleTasksPage]] = [:]
        final class Calls: @unchecked Sendable {
            var taskCallCount = 0
        }
        var calls = Calls()

        func taskLists(
            pageToken: GoogleTasksPageToken?, accessToken: GoogleAccessToken
        ) async throws -> GoogleTaskListPage {
            GoogleTaskListPage(lists: lists, nextPageToken: nil)
        }

        func tasks(
            listID: GoogleTaskListID, updatedSince: Date?, pageToken: GoogleTasksPageToken?,
            accessToken: GoogleAccessToken
        ) async throws -> GoogleTasksPage {
            let key = listID.withUnsafeRawValue { $0 }
            let pages = pagesByList[key] ?? []
            let index = calls.taskCallCount
            calls.taskCallCount += 1
            // Serve pages in order for this list; an exhausted list returns an empty final page.
            let local = pages.indices.contains(index) ? pages[index] : nil
            return local ?? GoogleTasksPage(tasks: [], deletedTaskIDs: [], nextPageToken: nil)
        }
    }

    private func record(
        id: String,
        listID: GoogleTaskListID,
        listTitle: String,
        title: String = "Task",
        due: DateComponents? = nil,
        completed: Bool = false,
        deleted: Bool = false
    ) throws -> GoogleTaskRecord {
        GoogleTaskRecord(
            id: try GoogleTaskID(validating: id),
            listID: listID,
            listTitle: listTitle,
            title: title,
            notes: nil,
            dueDate: due,
            updatedAt: Date(timeIntervalSince1970: 1_757_800_000),
            isCompleted: completed,
            isDeleted: deleted,
            privacyClass: .ordinary
        )
    }

    private func makeSource(_ fake: FakeTasks) -> GoogleTasksSource {
        GoogleTasksSource(client: fake, tokens: FakeTokens())
    }

    // MARK: - Tests

    func testDeletedTasksAreDroppedButCompletedOnesAreKept() async throws {
        let listID = try GoogleTaskListID(validating: "list-1")
        var fake = FakeTasks()
        fake.lists = [GoogleTaskList(id: listID, title: "School")]
        fake.pagesByList = [
            "list-1": [
                GoogleTasksPage(
                    tasks: [
                        try record(id: "t1", listID: listID, listTitle: "School"),
                        try record(
                            id: "t2", listID: listID, listTitle: "School", completed: true
                        ),
                        try record(
                            id: "t3", listID: listID, listTitle: "School", deleted: true
                        ),
                    ],
                    deletedTaskIDs: [],
                    nextPageToken: nil
                )
            ]
        ]

        let lists = try await makeSource(fake).taskLists()

        XCTAssertEqual(lists.count, 1)
        XCTAssertEqual(lists[0].items.map(\.id), ["t1", "t2"], "deleted tombstone must not show")
        XCTAssertEqual(lists[0].items[1].isCompleted, true, "completed tasks stay, struck through")
    }

    func testListNameDrivesCategoryAndUnknownFallsBackToOther() {
        XCTAssertEqual(GoogleTasksSource.category(forListNamed: "School"), .school)
        XCTAssertEqual(GoogleTasksSource.category(forListNamed: "  career "), .career)
        XCTAssertEqual(GoogleTasksSource.category(forListNamed: "Finance"), .finance)
        XCTAssertEqual(GoogleTasksSource.category(forListNamed: "Personal"), .personal)
        XCTAssertEqual(GoogleTasksSource.category(forListNamed: "Work"), .work)
        XCTAssertEqual(
            GoogleTasksSource.category(forListNamed: "Reading list"), .other,
            "an unrecognised list must not be assigned a guessed category"
        )
    }

    func testDueDateAnchorsToLocalStartOfDayAndNeverCarriesATime() throws {
        let due = DateComponents(year: 2026, month: 9, day: 14)
        let instant = try XCTUnwrap(GoogleTasksSource.dueInstant(from: due))

        var vancouver = Calendar(identifier: .gregorian)
        vancouver.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Vancouver"))
        let parts = vancouver.dateComponents([.year, .month, .day, .hour, .minute], from: instant)

        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 9)
        XCTAssertEqual(parts.day, 14, "must not slide a day — a bare date parsed as UTC would")
        XCTAssertEqual(parts.hour, 0, "a task carries a date, never a time-of-day")
        XCTAssertEqual(parts.minute, 0)
    }

    func testMissingDueStaysNil() {
        XCTAssertNil(GoogleTasksSource.dueInstant(from: nil))
    }

    func testListTitleIsPreservedForDisplay() async throws {
        let listID = try GoogleTaskListID(validating: "list-1")
        var fake = FakeTasks()
        fake.lists = [GoogleTaskList(id: listID, title: "Career")]
        fake.pagesByList = [
            "list-1": [
                GoogleTasksPage(
                    tasks: [try record(id: "t1", listID: listID, listTitle: "Career")],
                    deletedTaskIDs: [],
                    nextPageToken: nil
                )
            ]
        ]

        let lists = try await makeSource(fake).taskLists()

        XCTAssertEqual(lists[0].name, "Career")
        XCTAssertEqual(lists[0].items[0].category, .career)
    }

    func testNoListsMeansNoTaskReadsAtAll() async throws {
        let fake = FakeTasks()
        let lists = try await makeSource(fake).taskLists()

        XCTAssertTrue(lists.isEmpty)
        XCTAssertEqual(fake.calls.taskCallCount, 0)
    }
}
