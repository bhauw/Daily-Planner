import DailyPlannerDomain
import Foundation
import XCTest
@testable import DailyPlannerGoogle

final class GoogleTasksReadClientTests: XCTestCase {
    func testTaskListsAndIncompleteTasksDecodeDateOnlyDueValues() async throws {
        let harness = TasksHarness(results: [
            .response(data: fixture("task-lists")),
            .response(data: fixture("tasks")),
        ])

        let lists = try await harness.client.taskLists(pageToken: nil, accessToken: harness.token)
        let page = try await harness.client.tasks(
            listID: lists.lists[0].id,
            updatedSince: nil,
            pageToken: nil,
            accessToken: harness.token
        )

        XCTAssertEqual(lists.lists.count, 2)
        XCTAssertEqual(lists.lists[0].title, "Personal")
        XCTAssertEqual(lists.nextPageToken, try GoogleTasksPageToken(validating: "lists-page-2"))
        XCTAssertEqual(page.tasks.filter { !$0.isCompleted && !$0.isDeleted }.count, 2)
        XCTAssertEqual(page.tasks[0].dueDate, DateComponents(year: 2026, month: 9, day: 12))
        XCTAssertEqual(page.tasks[0].listID, lists.lists[0].id)
        XCTAssertEqual(page.tasks[0].listTitle, "")
        XCTAssertEqual(page.nextPageToken, try GoogleTasksPageToken(validating: "tasks-page-2"))
        XCTAssertEqual(harness.requests[0].httpMethod, "GET")
        XCTAssertEqual(harness.requests[0].url?.path, "/tasks/v1/users/@me/lists")
        XCTAssertEqual(harness.queries[0], ["maxResults": ["50"]])
        XCTAssertEqual(harness.requests[1].url?.path, "/tasks/v1/lists/personal-list/tasks")
        XCTAssertEqual(harness.taskQuery["showCompleted"], ["false"])
        XCTAssertEqual(harness.taskQuery["showDeleted"], ["false"])
        XCTAssertEqual(harness.taskQuery["showHidden"], ["false"])
        XCTAssertEqual(harness.taskQuery["maxResults"], ["100"])
        XCTAssertEqual(harness.sendCount, 2)
    }

    func testReconciliationRequestIncludesRemovalStatesAndCanonicalUpdatedMin() async throws {
        let harness = TasksHarness(results: [.response(data: taskPageJSON())])
        let updatedSince = Date(timeIntervalSince1970: 1_789_056_123.456)

        _ = try await harness.client.tasks(
            listID: harness.listID,
            updatedSince: updatedSince,
            pageToken: nil,
            accessToken: harness.token
        )

        XCTAssertEqual(harness.taskQuery["showCompleted"], ["true"])
        XCTAssertEqual(harness.taskQuery["showDeleted"], ["true"])
        XCTAssertEqual(harness.taskQuery["showHidden"], ["true"])
        XCTAssertEqual(harness.taskQuery["updatedMin"], ["2026-09-10T16:02:03.456Z"])
        XCTAssertEqual(harness.sendCount, 1)
    }

    func testPaginationQueriesRemainStableAndListIDIsExactlyOneEncodedSegment() async throws {
        let listToken = try GoogleTasksPageToken(validating: "list-next")
        let taskToken = try GoogleTasksPageToken(validating: "task-next")
        let listHarness = TasksHarness(results: [.response(data: listPageJSON())])
        _ = try await listHarness.client.taskLists(pageToken: listToken, accessToken: listHarness.token)
        XCTAssertEqual(listHarness.listQuery, ["maxResults": ["50"], "pageToken": ["list-next"]])

        let taskHarness = TasksHarness(
            results: [.response(data: taskPageJSON())],
            listID: try GoogleTaskListID(validating: "team#one@example.test")
        )
        _ = try await taskHarness.client.tasks(
            listID: taskHarness.listID,
            updatedSince: nil,
            pageToken: taskToken,
            accessToken: taskHarness.token
        )
        let components = try XCTUnwrap(taskHarness.requests[0].urlComponents)
        XCTAssertEqual(components.path, "/tasks/v1/lists/team#one@example.test/tasks")
        XCTAssertTrue(components.percentEncodedPath.contains("team%23one@example.test"))
        XCTAssertEqual(taskHarness.taskQuery, [
            "showCompleted": ["false"], "showDeleted": ["false"], "showHidden": ["false"],
            "maxResults": ["100"], "pageToken": ["task-next"],
        ])
        XCTAssertEqual(taskHarness.sendCount, 1)
    }

    func testUnsafeRequestedIDsTokensAndInvalidUpdatedDatesFailBeforeTransport() async {
        let invalidTokens = ["unsafe&token", "unsafe%token", String(repeating: "x", count: 4_097)]
        for raw in invalidTokens {
            let harness = TasksHarness(results: [])
            let token = try! GoogleTasksPageToken(validating: raw)
            await assertFiniteError(harness.listOperation(pageToken: token), expected: .malformedRequest)
            XCTAssertEqual(harness.sendCount, 0)
        }

        for raw in [".", "..", "unsafe/id", "unsafe%2Fid", String(repeating: "x", count: 1_025)] {
            let harness = TasksHarness(results: [], listID: try! GoogleTaskListID(validating: raw))
            await assertFiniteError(harness.tasksOperation(), expected: .malformedRequest)
            XCTAssertEqual(harness.sendCount, 0)
        }

        for date in [
            Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity),
            Date(timeIntervalSince1970: -62_135_596_801), Date(timeIntervalSince1970: 253_402_300_800),
        ] {
            let harness = TasksHarness(results: [])
            await assertFiniteError(harness.tasksOperation(updatedSince: date), expected: .malformedRequest)
            XCTAssertEqual(harness.sendCount, 0)
        }
    }

    func testProviderIDsAndPageTokensAreStrictAndBounded() async {
        let invalidListPages = [
            listPageJSON(items: [["id": "", "title": "List"]]),
            listPageJSON(items: [["id": "unsafe/id", "title": "List"]]),
            listPageJSON(items: [["id": String(repeating: "x", count: 1_025), "title": "List"]]),
            listPageJSON(nextPageToken: ""),
            listPageJSON(nextPageToken: String(repeating: "x", count: 4_097)),
        ]
        for response in invalidListPages {
            let harness = TasksHarness(results: [.response(data: response)])
            await assertFiniteError(harness.listOperation(), expected: .malformedResponse)
            XCTAssertEqual(harness.sendCount, 1)
        }

        let invalidTaskPages = [
            taskPageJSON(items: [taskItem(id: "")]),
            taskPageJSON(items: [taskItem(id: "unsafe/id")]),
            taskPageJSON(items: [taskItem(id: String(repeating: "x", count: 1_025))]),
            taskPageJSON(nextPageToken: ""),
            taskPageJSON(nextPageToken: String(repeating: "x", count: 4_097)),
        ]
        for response in invalidTaskPages {
            let harness = TasksHarness(results: [.response(data: response)])
            await assertFiniteError(harness.tasksOperation(), expected: .malformedResponse)
            XCTAssertEqual(harness.sendCount, 1)
        }
    }

    func testTasksRejectMissingOrOversizedTextAndInvalidUpdatedOrDueValues() async {
        let oversizedTitle = String(repeating: "x", count: 513)
        let oversizedNotes = String(repeating: "x", count: 65_537)
        let malformedItems: [[String: Any]] = [
            taskItem(removing: "title"),
            taskItem(removing: "updated"),
            taskItem(updated: "2026-09-10 08:00:00Z"),
            taskItem(updated: "2026-02-30T08:00:00Z"),
            taskItem(due: "2026-02-30T00:00:00.000Z"),
            taskItem(due: "2026-09-12"),
        ]
        for item in malformedItems {
            await assertFiniteError(
                TasksHarness(results: [.response(data: taskPageJSON(items: [item]))]).tasksOperation(),
                expected: .malformedResponse
            )
        }
        for item in [taskItem(title: oversizedTitle), taskItem(notes: oversizedNotes)] {
            await assertFiniteError(
                TasksHarness(results: [.response(data: taskPageJSON(items: [item]))]).tasksOperation(),
                expected: .limitViolation
            )
        }

        let missingListTitle = listPageJSON(items: [["id": "list-one"]])
        await assertFiniteError(
            TasksHarness(results: [.response(data: missingListTitle)]).listOperation(),
            expected: .malformedResponse
        )
        let oversizedListTitle = listPageJSON(items: [["id": "list-one", "title": oversizedTitle]])
        await assertFiniteError(
            TasksHarness(results: [.response(data: oversizedListTitle)]).listOperation(),
            expected: .limitViolation
        )
    }

    func testStatusAndDeletedStateMustBeRecognizedAndNonConflicting() async {
        for item in [
            taskItem(status: "unknown"),
            taskItem(removing: "status"),
            taskItem(status: "completed", deleted: true),
        ] {
            await assertFiniteError(
                TasksHarness(results: [.response(data: taskPageJSON(items: [item]))]).tasksOperation(),
                expected: .malformedResponse
            )
        }

        let harness = TasksHarness(results: [.response(data: taskPageJSON(items: [
            taskItem(id: "open", status: "needsAction"),
            taskItem(id: "done", status: "completed"),
            taskItem(id: "deleted", status: "needsAction", deleted: true),
        ]))])
        let page = try? await harness.client.tasks(
            listID: harness.listID, updatedSince: Date(timeIntervalSince1970: 1_789_056_000),
            pageToken: nil, accessToken: harness.token
        )
        XCTAssertEqual(page?.tasks.map(\.isCompleted), [false, true])
        XCTAssertEqual(page?.tasks.map(\.isDeleted), [false, false])
        XCTAssertEqual(page?.deletedTaskIDs, [try GoogleTaskID(validating: "deleted")])
    }

    func testSparseDeletedTombstonePreservesIdentityWithoutFabricatedContent() async throws {
        let harness = TasksHarness(results: [.response(data: fixture("task-deleted-tombstone"))])

        let page = try await harness.client.tasks(
            listID: harness.listID,
            updatedSince: Date(timeIntervalSince1970: 1_789_056_000),
            pageToken: nil,
            accessToken: harness.token
        )

        XCTAssertTrue(page.tasks.isEmpty)
        XCTAssertEqual(page.deletedTaskIDs, [try GoogleTaskID(validating: "deleted-task")])
        XCTAssertEqual(harness.sendCount, 1)

        let oversizedTitle = String(repeating: "x", count: 513)
        let oversizedNotes = String(repeating: "x", count: 65_537)
        for item in [
            deletedTaskItem(id: "unsafe/id"),
            deletedTaskItem(status: "completed"),
            deletedTaskItem(title: oversizedTitle),
            deletedTaskItem(notes: oversizedNotes),
        ] {
            await assertFiniteError(
                TasksHarness(results: [.response(data: taskPageJSON(items: [item]))]).tasksOperation(),
                expected: item["title"] != nil || item["notes"] != nil
                    ? .limitViolation
                    : .malformedResponse
            )
        }
    }

    func testDuplicateAndActiveDeletedTaskIdentityConflictsFailClosed() async {
        let duplicateTombstones = taskPageJSON(items: [
            deletedTaskItem(id: "duplicate"),
            deletedTaskItem(id: "duplicate"),
        ])
        let activeDeletedConflict = taskPageJSON(items: [
            taskItem(id: "same-task"),
            deletedTaskItem(id: "same-task"),
        ])

        for response in [duplicateTombstones, activeDeletedConflict] {
            await assertFiniteError(
                TasksHarness(results: [.response(data: response)]).tasksOperation(),
                expected: .malformedResponse
            )
        }
    }

    func testPageItemCapsAreEnforced() async {
        let lists = Array(repeating: ["id": "list", "title": "List"], count: 51)
        let tasks = (0..<101).map { taskItem(id: "task-\($0)") }
        await assertFiniteError(
            TasksHarness(results: [.response(data: listPageJSON(items: lists))]).listOperation(),
            expected: .limitViolation
        )
        await assertFiniteError(
            TasksHarness(results: [.response(data: taskPageJSON(items: tasks))]).tasksOperation(),
            expected: .limitViolation
        )
    }

    func testCancellationTransportAndProviderFailuresMapToFiniteRedactedErrors() async {
        let expected: [(TasksHarness.Result, GoogleTasksReadClientError)] = [
            (.failure(CancellationError()), .cancelled),
            (.failure(GoogleHTTPTransportError.cancelled), .cancelled),
            (.failure(GoogleHTTPTransportError.requestFailed), .offline),
            (.failure(GoogleHTTPTransportError.nonHTTPResponse), .providerUnavailable),
            (.response(status: 503, data: Data("private provider body".utf8)), .providerUnavailable),
            (.response(data: Data("private malformed body".utf8)), .malformedResponse),
        ]
        for (result, error) in expected {
            let harness = TasksHarness(results: [result])
            await assertFiniteError(harness.tasksOperation(), expected: error)
            XCTAssertEqual(harness.sendCount, 1)
            XCTAssertFalse(String(describing: error).contains("private"))
        }

        let cancelled = TasksHarness(results: [])
        let result: GoogleTasksReadClientError? = await Task { () -> GoogleTasksReadClientError? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await cancelled.client.taskLists(pageToken: nil, accessToken: cancelled.token)
                return nil
            } catch {
                return error as? GoogleTasksReadClientError
            }
        }.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(cancelled.sendCount, 0)
    }

    private func assertFiniteError(
        _ operation: @escaping @Sendable () async throws -> Void,
        expected: GoogleTasksReadClientError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("expected finite Tasks client error", file: file, line: line)
        } catch let error as GoogleTasksReadClientError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("raw error escaped the Tasks client", file: file, line: line)
        }
    }
}

private final class TasksHarness: @unchecked Sendable {
    enum Result: @unchecked Sendable {
        case response(status: Int = 200, data: Data)
        case failure(any Error)
    }

    final class Transport: GoogleHTTPTransport, @unchecked Sendable {
        private var results: [Result]
        private(set) var requests: [URLRequest] = []

        init(results: [Result]) { self.results = results }

        func send(_ request: URLRequest) async throws -> GoogleHTTPResponse {
            requests.append(request)
            let result = results.removeFirst()
            switch result {
            case let .response(status, data): return GoogleHTTPResponse(statusCode: status, data: data)
            case let .failure(error): throw error
            }
        }
    }

    let token = try! GoogleAccessToken(validating: "synthetic-access-token")
    let listID: GoogleTaskListID
    let transport: Transport
    let client: GoogleTasksReadClient

    init(results: [Result], listID: GoogleTaskListID = try! GoogleTaskListID(validating: "list-one")) {
        self.listID = listID
        transport = Transport(results: results)
        client = GoogleTasksReadClient(transport: transport)
    }

    var requests: [URLRequest] { transport.requests }
    var sendCount: Int { requests.count }
    var queries: [[String: [String]]] { requests.map(requestQuery(from:)) }
    var listQuery: [String: [String]] { queries[0] }
    var taskQuery: [String: [String]] { queries.last! }

    func listOperation(pageToken: GoogleTasksPageToken? = nil) -> @Sendable () async throws -> Void {
        { _ = try await self.client.taskLists(pageToken: pageToken, accessToken: self.token) }
    }

    func tasksOperation(updatedSince: Date? = nil) -> @Sendable () async throws -> Void {
        {
            _ = try await self.client.tasks(
                listID: self.listID, updatedSince: updatedSince, pageToken: nil,
                accessToken: self.token
            )
        }
    }
}

private func fixture(_ name: String) -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "json")!
    return try! Data(contentsOf: url)
}

private func requestQuery(from request: URLRequest) -> [String: [String]] {
    let items = request.urlComponents.queryItems ?? []
    return Dictionary(grouping: items, by: \.name).mapValues { $0.compactMap(\.value) }
}

private func listPageJSON(
    items: [[String: Any]] = [], nextPageToken: String? = nil
) -> Data {
    var object: [String: Any] = ["items": items]
    if let nextPageToken { object["nextPageToken"] = nextPageToken }
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func taskPageJSON(
    items: [[String: Any]] = [], nextPageToken: String? = nil
) -> Data {
    var object: [String: Any] = ["items": items]
    if let nextPageToken { object["nextPageToken"] = nextPageToken }
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func taskItem(
    id: String = "task-one",
    title: String = "Task",
    notes: String? = nil,
    due: String? = nil,
    updated: String = "2026-09-10T08:00:00Z",
    status: String = "needsAction",
    deleted: Bool? = nil,
    removing key: String? = nil
) -> [String: Any] {
    var item: [String: Any] = ["id": id, "title": title, "updated": updated, "status": status]
    if let notes { item["notes"] = notes }
    if let due { item["due"] = due }
    if let deleted { item["deleted"] = deleted }
    if let key { item.removeValue(forKey: key) }
    return item
}

private func deletedTaskItem(
    id: String = "deleted-task",
    title: String? = nil,
    notes: String? = nil,
    updated: String? = nil,
    status: String? = nil
) -> [String: Any] {
    var item: [String: Any] = ["id": id, "deleted": true]
    if let title { item["title"] = title }
    if let notes { item["notes"] = notes }
    if let updated { item["updated"] = updated }
    if let status { item["status"] = status }
    return item
}

private extension URLRequest {
    var urlComponents: URLComponents { URLComponents(url: url!, resolvingAgainstBaseURL: false)! }
}
