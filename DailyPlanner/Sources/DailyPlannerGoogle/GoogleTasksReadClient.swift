import DailyPlannerDomain
import Foundation

public enum GoogleTasksReadClientError: Error, Equatable, CaseIterable, Sendable {
    case malformedRequest
    case cancelled
    case offline
    case providerUnavailable
    case malformedResponse
    case limitViolation
}

public struct GoogleTasksReadClient: GoogleTasksReading, Sendable {
    public let transport: any GoogleHTTPTransport

    public init(transport: any GoogleHTTPTransport) {
        self.transport = transport
    }

    public func taskLists(
        pageToken: GoogleTasksPageToken?,
        accessToken: GoogleAccessToken
    ) async throws -> GoogleTaskListPage {
        do {
            let url = try TasksURL.lists(pageToken: pageToken)
            try Task.checkCancellation()
            let request = try GoogleRequestBuilder.get(url: url, accessToken: accessToken)
            let response = try await transport.send(request)
            return try TasksWireDecoder.listPage(from: response)
        } catch {
            throw mapTasksError(error)
        }
    }

    public func tasks(
        listID: GoogleTaskListID,
        updatedSince: Date?,
        pageToken: GoogleTasksPageToken?,
        accessToken: GoogleAccessToken
    ) async throws -> GoogleTasksPage {
        do {
            let url = try TasksURL.tasks(
                listID: listID,
                updatedSince: updatedSince,
                pageToken: pageToken
            )
            try Task.checkCancellation()
            let request = try GoogleRequestBuilder.get(url: url, accessToken: accessToken)
            let response = try await transport.send(request)
            return try TasksWireDecoder.taskPage(from: response, listID: listID)
        } catch {
            throw mapTasksError(error)
        }
    }
}

private enum TasksURL {
    static func lists(pageToken: GoogleTasksPageToken?) throws -> URL {
        var items = [URLQueryItem(name: "maxResults", value: "50")]
        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: try TasksProviderValue.raw(pageToken)))
        }
        return try url(path: "/tasks/v1/users/@me/lists", items: items)
    }

    static func tasks(
        listID: GoogleTaskListID,
        updatedSince: Date?,
        pageToken: GoogleTasksPageToken?
    ) throws -> URL {
        let reconciliation = updatedSince != nil
        let stateValue = reconciliation ? "true" : "false"
        var items = [
            URLQueryItem(name: "showCompleted", value: stateValue),
            URLQueryItem(name: "showDeleted", value: stateValue),
            URLQueryItem(name: "showHidden", value: stateValue),
        ]
        if let updatedSince {
            items.append(URLQueryItem(
                name: "updatedMin",
                value: try TasksRFC3339.requestString(from: updatedSince)
            ))
        }
        items.append(URLQueryItem(name: "maxResults", value: "100"))
        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: try TasksProviderValue.raw(pageToken)))
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "tasks.googleapis.com"
        components.percentEncodedPath = "/tasks/v1/lists/\(try TasksProviderValue.encodedPathSegment(listID))/tasks"
        components.queryItems = items
        guard let result = components.url else { throw GoogleTasksReadClientError.malformedRequest }
        return result
    }

    private static func url(path: String, items: [URLQueryItem]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "tasks.googleapis.com"
        components.path = path
        components.queryItems = items
        guard let result = components.url else { throw GoogleTasksReadClientError.malformedRequest }
        return result
    }
}

private enum TasksProviderValue {
    private static let maximumIDBytes = 1_024
    private static let maximumTokenBytes = 4_096

    static func listID(_ value: String) throws -> GoogleTaskListID {
        guard isSafeID(value) else { throw GoogleTasksReadClientError.malformedResponse }
        do {
            return try GoogleTaskListID(validating: value)
        } catch {
            throw GoogleTasksReadClientError.malformedResponse
        }
    }

    static func taskID(_ value: String) throws -> GoogleTaskID {
        guard isSafeID(value) else { throw GoogleTasksReadClientError.malformedResponse }
        do {
            return try GoogleTaskID(validating: value)
        } catch {
            throw GoogleTasksReadClientError.malformedResponse
        }
    }

    static func pageToken(_ value: String?) throws -> GoogleTasksPageToken? {
        guard let value else { return nil }
        guard isSafeToken(value) else { throw GoogleTasksReadClientError.malformedResponse }
        do {
            return try GoogleTasksPageToken(validating: value)
        } catch {
            throw GoogleTasksReadClientError.malformedResponse
        }
    }

    static func raw(_ value: GoogleTasksPageToken) throws -> String {
        try value.withUnsafeRawValue { rawValue in
            guard isSafeToken(rawValue) else { throw GoogleTasksReadClientError.malformedRequest }
            return rawValue
        }
    }

    static func encodedPathSegment(_ value: GoogleTaskListID) throws -> String {
        try value.withUnsafeRawValue { rawValue in
            guard isSafeID(rawValue) else { throw GoogleTasksReadClientError.malformedRequest }
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "/%\\")
            guard let encoded = rawValue.addingPercentEncoding(withAllowedCharacters: allowed),
                  !encoded.isEmpty else {
                throw GoogleTasksReadClientError.malformedRequest
            }
            return encoded
        }
    }

    private static func isSafeID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumIDBytes && value != "." && value != ".."
            && !value.unicodeScalars.contains { scalar in
                CharacterSet.controlCharacters.contains(scalar)
                    || scalar == "/" || scalar == "\\" || scalar == "%"
            }
    }

    private static func isSafeToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumTokenBytes
            && !value.unicodeScalars.contains { scalar in
                CharacterSet.controlCharacters.contains(scalar)
                    || scalar == "&" || scalar == "=" || scalar == "%"
            }
    }
}

private struct TasksWireListPage: Decodable {
    let items: [TasksWireList]?
    let nextPageToken: String?
}

private struct TasksWireList: Decodable {
    let id: String
    let title: String
}

private struct TasksWireTaskPage: Decodable {
    let items: [TasksWireTask]?
    let nextPageToken: String?
}

private struct TasksWireTask: Decodable {
    let id: String
    let title: String?
    let notes: String?
    let due: String?
    let updated: String?
    let status: String?
    let deleted: Bool?
}

private enum TasksWireDecoder {
    private static let maximumListItems = 50
    private static let maximumTaskItems = 100
    private static let maximumNotesScalars = 65_536

    static func listPage(from response: GoogleHTTPResponse) throws -> GoogleTaskListPage {
        let wire: TasksWireListPage = try decode(TasksWireListPage.self, from: response)
        let items = wire.items ?? []
        guard items.count <= maximumListItems else {
            throw GoogleTasksReadClientError.limitViolation
        }
        return GoogleTaskListPage(
            lists: try items.map { item in
                guard item.title.unicodeScalars.count <= GoogleSyncLimits.displayScalars else {
                    throw GoogleTasksReadClientError.limitViolation
                }
                return GoogleTaskList(id: try TasksProviderValue.listID(item.id), title: item.title)
            },
            nextPageToken: try TasksProviderValue.pageToken(wire.nextPageToken)
        )
    }

    static func taskPage(
        from response: GoogleHTTPResponse,
        listID: GoogleTaskListID
    ) throws -> GoogleTasksPage {
        let wire: TasksWireTaskPage = try decode(TasksWireTaskPage.self, from: response)
        let items = wire.items ?? []
        guard items.count <= maximumTaskItems else {
            throw GoogleTasksReadClientError.limitViolation
        }
        var tasks: [GoogleTaskRecord] = []
        var deletedTaskIDs: [GoogleTaskID] = []
        var seenTaskIDs = Set<GoogleTaskID>()
        for item in items {
            let decoded = try record(from: item, listID: listID)
            guard seenTaskIDs.insert(decoded.id).inserted else {
                throw GoogleTasksReadClientError.malformedResponse
            }
            switch decoded {
            case let .task(task): tasks.append(task)
            case let .deleted(id): deletedTaskIDs.append(id)
            }
        }
        return GoogleTasksPage(
            tasks: tasks,
            deletedTaskIDs: deletedTaskIDs,
            nextPageToken: try TasksProviderValue.pageToken(wire.nextPageToken)
        )
    }

    private static func record(
        from wire: TasksWireTask,
        listID: GoogleTaskListID
    ) throws -> DecodedTask {
        let id = try TasksProviderValue.taskID(wire.id)
        guard (wire.title?.unicodeScalars.count ?? 0) <= GoogleSyncLimits.displayScalars,
              (wire.notes?.unicodeScalars.count ?? 0) <= maximumNotesScalars else {
            throw GoogleTasksReadClientError.limitViolation
        }
        let isDeleted = wire.deleted ?? false
        let dueDate: DateComponents?
        if let due = wire.due {
            guard let parsed = TasksDueDate.parse(due) else {
                throw GoogleTasksReadClientError.malformedResponse
            }
            dueDate = parsed
        } else {
            dueDate = nil
        }
        if isDeleted {
            guard wire.status == nil || wire.status == "needsAction" else {
                throw GoogleTasksReadClientError.malformedResponse
            }
            if let updated = wire.updated {
                guard TasksRFC3339.responseDate(from: updated) != nil else {
                    throw GoogleTasksReadClientError.malformedResponse
                }
            }
            return .deleted(id)
        }
        guard let title = wire.title,
              let updated = wire.updated,
              let status = wire.status,
              status == "needsAction" || status == "completed",
              let updatedAt = TasksRFC3339.responseDate(from: updated) else {
            throw GoogleTasksReadClientError.malformedResponse
        }
        return .task(GoogleTaskRecord(
            id: id,
            listID: listID,
            listTitle: "",
            title: title,
            notes: wire.notes,
            dueDate: dueDate,
            updatedAt: updatedAt,
            isCompleted: status == "completed",
            isDeleted: false,
            privacyClass: .ordinary
        ))
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from response: GoogleHTTPResponse
    ) throws -> T {
        guard (200...299).contains(response.statusCode) else {
            throw GoogleTasksReadClientError.providerUnavailable
        }
        do {
            return try JSONDecoder().decode(type, from: response.data)
        } catch {
            throw GoogleTasksReadClientError.malformedResponse
        }
    }
}

private enum DecodedTask {
    case task(GoogleTaskRecord)
    case deleted(GoogleTaskID)

    var id: GoogleTaskID {
        switch self {
        case let .task(task): return task.id
        case let .deleted(id): return id
        }
    }
}

private enum TasksDueDate {
    static func parse(_ value: String) -> DateComponents? {
        guard TasksRFC3339.responseDate(from: value) != nil,
              value.utf8.count >= 10 else { return nil }
        let date = String(value.prefix(10))
        let parts = date.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var candidate = DateComponents()
        candidate.calendar = calendar
        candidate.timeZone = calendar.timeZone
        candidate.year = year
        candidate.month = month
        candidate.day = day
        candidate.hour = 12
        guard let instant = calendar.date(from: candidate),
              calendar.dateComponents([.year, .month, .day], from: instant)
                == DateComponents(year: year, month: month, day: day) else {
            return nil
        }
        return DateComponents(year: year, month: month, day: day)
    }
}

private enum TasksRFC3339 {
    private static let earliest = -62_135_596_800.0
    private static let latestExclusive = 253_402_300_800.0

    static func requestString(from date: Date) throws -> String {
        let timestamp = date.timeIntervalSince1970
        guard timestamp.isFinite, timestamp >= earliest, timestamp < latestExclusive else {
            throw GoogleTasksReadClientError.malformedRequest
        }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let value = formatter.string(from: date)
        guard responseDate(from: value) != nil else {
            throw GoogleTasksReadClientError.malformedRequest
        }
        return value
    }

    static func responseDate(from value: String) -> Date? {
        guard value.utf8.count <= 64,
              value.range(
                  of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"#,
                  options: .regularExpression
              ) != nil,
              isValidCalendarDate(String(value.prefix(10))) else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        guard let date = formatter.date(from: value), date.timeIntervalSince1970.isFinite else {
            return nil
        }
        return date
    }

    private static func isValidCalendarDate(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        guard let date = calendar.date(from: components) else { return false }
        return calendar.dateComponents([.year, .month, .day], from: date)
            == DateComponents(year: year, month: month, day: day)
    }
}

private func mapTasksError(_ error: any Error) -> GoogleTasksReadClientError {
    if let error = error as? GoogleTasksReadClientError { return error }
    if error is CancellationError { return .cancelled }
    if let error = error as? GoogleHTTPTransportError {
        switch error {
        case .cancelled: return .cancelled
        case .requestFailed: return .offline
        case .nonHTTPResponse: return .providerUnavailable
        }
    }
    return .malformedResponse
}
