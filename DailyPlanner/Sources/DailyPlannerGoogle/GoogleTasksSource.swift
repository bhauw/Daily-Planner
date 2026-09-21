import Foundation
import DailyPlannerDomain

/// Adapts the live Google Tasks read client to the planner's task-list port, so `/api/tasks`
/// serves the user's real lists instead of synthetic content.
///
/// Read-only by construction: it holds only a read client, so there is no write path to call.
/// Nothing here can complete, create, or reorder a task.
public struct GoogleTasksSource: PlannerTaskListReading, Sendable {
    private let client: any GoogleTasksReading
    private let tokens: any GoogleAccessTokenProviding

    public init(client: any GoogleTasksReading, tokens: any GoogleAccessTokenProviding) {
        self.client = client
        self.tokens = tokens
    }

    public func taskLists() async throws -> [PlannerTaskList] {
        let token = try await tokens.accessToken()
        let lists = try await allLists(accessToken: token)

        var out: [PlannerTaskList] = []
        var total = 0
        for list in lists.prefix(GoogleSyncLimits.taskLists) {
            let records = try await allTasks(listID: list.id, accessToken: token)
            let items = records
                // A deleted task is a tombstone, not something to show. Completed tasks are kept:
                // the UI renders them struck through, which is how a list reads as "done today".
                .filter { !$0.isDeleted }
                .map { record in
                    PlannerTaskItem(
                        // Opaque by design so it cannot be logged by accident; unwrapping here is
                        // the sanctioned path. It becomes the item's identity for the loopback UI
                        // and never leaves 127.0.0.1.
                        id: record.id.withUnsafeRawValue { $0 },
                        title: record.title,
                        category: Self.category(forListNamed: list.title),
                        due: Self.dueInstant(from: record.dueDate),
                        isCompleted: record.isCompleted
                    )
                }
            total += items.count
            out.append(PlannerTaskList(name: list.title, items: items))
            if total >= GoogleSyncLimits.tasksTotal { break }
        }
        return out
    }

    // MARK: - Internals

    private func allLists(accessToken: GoogleAccessToken) async throws -> [GoogleTaskList] {
        var out: [GoogleTaskList] = []
        var pageToken: GoogleTasksPageToken?
        for _ in 0..<GoogleSyncLimits.taskPagesPerList {
            try Task.checkCancellation()
            let page = try await client.taskLists(pageToken: pageToken, accessToken: accessToken)
            out.append(contentsOf: page.lists)
            guard let next = page.nextPageToken, out.count < GoogleSyncLimits.taskLists else {
                break
            }
            pageToken = next
        }
        return out
    }

    private func allTasks(
        listID: GoogleTaskListID,
        accessToken: GoogleAccessToken
    ) async throws -> [GoogleTaskRecord] {
        var out: [GoogleTaskRecord] = []
        var pageToken: GoogleTasksPageToken?
        for _ in 0..<GoogleSyncLimits.taskPagesPerList {
            try Task.checkCancellation()
            let page = try await client.tasks(
                listID: listID,
                updatedSince: nil,
                pageToken: pageToken,
                accessToken: accessToken
            )
            out.append(contentsOf: page.tasks)
            guard let next = page.nextPageToken, out.count < GoogleSyncLimits.tasksPerList else {
                break
            }
            pageToken = next
        }
        return out
    }

    /// Google Tasks carries no colour, so a list's own name is the only category signal there is.
    /// An unrecognised list falls back to `.other` rather than guessing.
    static func category(forListNamed name: String) -> PlannerCategory {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "school", "classes", "academics": return .school
        case "career", "recruiting", "co-op", "coop": return .career
        case "finance", "financials", "money": return .finance
        case "personal", "life": return .personal
        case "work", "job": return .work
        default: return .other
        }
    }

    private static let zone = TimeZone(identifier: "America/Vancouver") ?? .gmt

    /// Google Tasks due values are dates, not instants. Anchor at local start-of-day so the UI
    /// shows the day the user actually set — parsing a bare date as UTC midnight would shift it
    /// backwards in Vancouver.
    static func dueInstant(from components: DateComponents?) -> Date? {
        guard let components else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var anchored = components
        anchored.timeZone = zone
        anchored.hour = 0
        anchored.minute = 0
        anchored.second = 0
        return calendar.date(from: anchored)
    }
}
