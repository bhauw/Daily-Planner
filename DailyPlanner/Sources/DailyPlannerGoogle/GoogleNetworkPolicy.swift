import Foundation

public enum GoogleNetworkPolicy {
    public static func validate(_ request: URLRequest) throws {
        guard let method = request.httpMethod, !method.isEmpty,
              let url = request.url,
              url.baseURL == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              components.percentEncodedHost?.lowercased() == host,
              components.port == nil || components.port == 443,
              components.user == nil,
              components.password == nil,
              components.percentEncodedFragment == nil,
              !hasAmbiguousPathEncoding(components.percentEncodedPath),
              let endpoint = Endpoint(
                  method: method,
                  host: host,
                  path: components.path,
                  query: try Query(components: components)
              ),
              endpoint.permits(request) else {
            throw GoogleNetworkPolicyError.rejectedRequest
        }
    }

    private static func hasAmbiguousPathEncoding(_ path: String) -> Bool {
        let lowercasePath = path.lowercased()
        return lowercasePath.contains("%2e")
            || lowercasePath.contains("%2f")
            || lowercasePath.contains("%5c")
            || lowercasePath.contains("%25")
            || path.split(separator: "/", omittingEmptySubsequences: false).contains { segment in
                segment == "." || segment == ".."
            }
    }
}

private struct Query {
    let values: [String: [String]]

    init(components: URLComponents) throws {
        guard let rawQuery = components.percentEncodedQuery else {
            values = [:]
            return
        }
        let rawItems = rawQuery.split(separator: "&", omittingEmptySubsequences: false)
        guard !rawQuery.isEmpty,
              !rawItems.contains(where: \.isEmpty),
              let items = components.queryItems,
              items.count == rawItems.count else {
            throw GoogleNetworkPolicyError.rejectedRequest
        }

        var multimap: [String: [String]] = [:]
        for item in items {
            guard !item.name.isEmpty,
                  !item.name.contains("%"),
                  let value = item.value,
                  !value.isEmpty,
                  Self.isSafeQueryValue(value) else {
                throw GoogleNetworkPolicyError.rejectedRequest
            }
            multimap[item.name, default: []].append(value)
        }
        values = multimap
    }

    func exactly(_ names: Set<String>) -> Bool {
        Set(values.keys).isSubset(of: names)
    }

    func value(_ name: String) -> String? {
        guard let values = values[name], values.count == 1 else { return nil }
        return values[0]
    }

    func hasOnlySingletons(except repeated: Set<String> = []) -> Bool {
        values.allSatisfy { name, entries in repeated.contains(name) || entries.count == 1 }
    }

    func hasValue(_ name: String) -> Bool {
        values[name] != nil
    }

    func allValues(_ name: String, areAllowed allowed: Set<String>) -> Bool {
        guard let values = values[name], !values.isEmpty,
              Set(values).count == values.count else { return false }
        return values.allSatisfy(allowed.contains)
    }

    /// `=` is permitted because Google's opaque page and sync tokens carry base64 padding, and
    /// this policy would otherwise refuse to send back a token Google itself issued. It cannot
    /// smuggle an extra parameter: the value here has already been split out of the query by
    /// `URLComponents`, which divides each pair on its first `=`.
    ///
    /// `&` and `%` remain forbidden — those are the two that could actually alter the request.
    private static func isSafeQueryValue(_ value: String) -> Bool {
        value.utf8.count <= 4_096
            && !value.unicodeScalars.contains { scalar in
                CharacterSet.controlCharacters.contains(scalar)
                    || scalar == "&"
                    || scalar == "%"
            }
    }
}

private enum Endpoint {
    case oauth
    case provider
    /// The three write endpoints, and only those three. Everything about `.provider` still
    /// holds — exact host, exact path, no query — with the body and the JSON content type
    /// added, and nothing else permitted to accompany them.
    case providerWrite

    /// The largest request body this policy will let out. The loopback server already caps what
    /// a composer can submit; this is the independent bound on what actually reaches Google, so
    /// a bug on one side of the app cannot turn into an unbounded upload on the other.
    static let maxWriteBodyBytes = 512 * 1024

    init?(method: String, host: String, path: String, query: Query) {
        if method == "POST", host == "oauth2.googleapis.com", ["/token", "/revoke"].contains(path), query.values.isEmpty {
            self = .oauth
            return
        }
        if method == "POST" || method == "PATCH" {
            // No query parameters on a write. `sendUpdates` in particular is how a calendar
            // insert or update mails every attendee — that is a separate, deliberate feature,
            // and it cannot be reached by accident from here.
            //
            // The verb is matched inside `WriteRoute` rather than tested here, so each path is
            // bound to exactly one method: a PATCH cannot reach the events COLLECTION (which
            // would be a create), and a POST cannot reach a single event.
            guard WriteRoute(method: method, host: host, path: path) != nil,
                  query.values.isEmpty else { return nil }
            self = .providerWrite
            return
        }
        guard method == "GET", let route = Route(host: host, path: path), route.permits(query) else {
            return nil
        }
        self = .provider
    }

    func permits(_ request: URLRequest) -> Bool {
        let headers = request.allHTTPHeaderFields ?? [:]
        switch self {
        case .oauth:
            return headers.allSatisfy { name, value in
                name.caseInsensitiveCompare("Content-Type") == .orderedSame
                    && value == "application/x-www-form-urlencoded"
            }
        case .provider:
            guard request.httpBody == nil, request.httpBodyStream == nil else { return false }
            let authorizationHeaders = headers.filter { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }
            guard headers.count == 1, authorizationHeaders.count == 1,
                  let authorization = authorizationHeaders.first?.value else {
                return false
            }
            return isValidBearerAuthorization(authorization)
        case .providerWrite:
            // A streamed body cannot be inspected or bounded here, so it is refused outright.
            guard request.httpBodyStream == nil,
                  let body = request.httpBody,
                  !body.isEmpty, body.count <= Self.maxWriteBodyBytes else {
                return false
            }
            let authorizationHeaders = headers.filter { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }
            let contentTypeHeaders = headers.filter { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }
            guard headers.count == 2,
                  authorizationHeaders.count == 1, contentTypeHeaders.count == 1,
                  let authorization = authorizationHeaders.first?.value,
                  contentTypeHeaders.first?.value == "application/json" else {
                return false
            }
            return isValidBearerAuthorization(authorization)
        }
    }

    private func isValidBearerAuthorization(_ value: String) -> Bool {
        guard value.hasPrefix("Bearer ") else { return false }
        let token = value.unicodeScalars.dropFirst("Bearer ".count)
        guard !token.isEmpty else { return false }

        var reachedPadding = false
        var hasNonPaddingScalar = false
        for scalar in token {
            if scalar.value == 0x3D {
                reachedPadding = true
                continue
            }
            guard !reachedPadding,
                  (0x30...0x39).contains(scalar.value)
                    || (0x41...0x5A).contains(scalar.value)
                    || (0x61...0x7A).contains(scalar.value)
                    || [0x2D, 0x2E, 0x5F, 0x7E, 0x2B, 0x2F].contains(scalar.value) else {
                return false
            }
            hasNonPaddingScalar = true
        }
        return hasNonPaddingScalar
    }
}

private enum Route {
    case gmailProfile, gmailMessages, gmailMessage, gmailHistory
    case calendarList, calendarEvents, calendarColors
    case taskLists, tasks

    init?(host: String, path: String) {
        guard path.hasPrefix("/"), !path.hasSuffix("/"), !path.contains("//") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if host == "gmail.googleapis.com" {
            if components == ["gmail", "v1", "users", "me", "profile"] { self = .gmailProfile; return }
            if components == ["gmail", "v1", "users", "me", "messages"] { self = .gmailMessages; return }
            if components == ["gmail", "v1", "users", "me", "history"] { self = .gmailHistory; return }
            guard components.count == 6,
                  Array(components.prefix(5)) == ["gmail", "v1", "users", "me", "messages"],
                  Self.isOpaquePathComponent(components[5]) else { return nil }
            self = .gmailMessage
            return
        }
        if host == "www.googleapis.com" {
            if components == ["calendar", "v3", "users", "me", "calendarList"] { self = .calendarList; return }
            if components == ["calendar", "v3", "colors"] { self = .calendarColors; return }
            guard components.count == 5,
                  Array(components.prefix(3)) == ["calendar", "v3", "calendars"],
                  components[4] == "events",
                  Self.isOpaquePathComponent(components[3]) else { return nil }
            self = .calendarEvents
            return
        }
        if host == "tasks.googleapis.com" {
            if components == ["tasks", "v1", "users", "@me", "lists"] { self = .taskLists; return }
            guard components.count == 5,
                  Array(components.prefix(3)) == ["tasks", "v1", "lists"],
                  components[4] == "tasks",
                  Self.isOpaquePathComponent(components[3]) else { return nil }
            self = .tasks
            return
        }
        return nil
    }

    func permits(_ query: Query) -> Bool {
        switch self {
        case .gmailProfile:
            return query.values.isEmpty
        case .gmailMessages:
            return query.exactly(["q", "maxResults", "pageToken"])
                && query.hasOnlySingletons()
                && isGmailSearch(query.value("q") ?? "")
                && isPageSize(query.value("maxResults") ?? "")
        case .gmailMessage:
            return query.exactly(["format", "metadataHeaders"])
                && query.hasOnlySingletons(except: ["metadataHeaders"])
                && (!query.hasValue("format") || ["metadata", "full"].contains(query.value("format")!))
                && (!query.hasValue("metadataHeaders") || query.allValues("metadataHeaders", areAllowed: ["From", "Subject"]))
                && (!query.hasValue("metadataHeaders") || query.value("format") == "metadata")
        case .gmailHistory:
            return query.exactly(["startHistoryId", "historyTypes", "maxResults", "pageToken"])
                && query.hasOnlySingletons(except: ["historyTypes"])
                && Self.isPositiveInteger(query.value("startHistoryId"))
                && query.allValues("historyTypes", areAllowed: ["messageAdded", "messageDeleted"])
                && Set(query.values["historyTypes"] ?? []) == ["messageAdded", "messageDeleted"]
                && (!query.hasValue("maxResults") || isPageSize(query.value("maxResults")!))
        case .calendarColors:
            return query.values.isEmpty
        case .calendarList:
            if query.values == ["maxResults": ["1"]] { return true }
            return query.exactly(["minAccessRole", "showDeleted", "maxResults", "pageToken"])
                && query.hasOnlySingletons()
                && query.value("minAccessRole") == "reader"
                && query.value("showDeleted") == "false"
                && (!query.hasValue("maxResults") || isPageSize(query.value("maxResults")!))
        case .calendarEvents:
            guard query.exactly(["singleEvents", "showDeleted", "timeMin", "timeMax", "syncToken", "maxResults", "pageToken"]),
                  query.hasOnlySingletons(), query.value("singleEvents") == "true", query.value("showDeleted") == "true",
                  !query.hasValue("maxResults") || isPageSize(query.value("maxResults")!) else { return false }
            let usesSyncToken = query.hasValue("syncToken")
            let hasInitialBounds = query.hasValue("timeMin") && query.hasValue("timeMax")
            return usesSyncToken
                ? !query.hasValue("timeMin") && !query.hasValue("timeMax")
                : hasInitialBounds && isRFC3339(query.value("timeMin")!) && isRFC3339(query.value("timeMax")!)
        case .taskLists:
            return query.exactly(["maxResults", "pageToken"])
                && query.hasOnlySingletons()
                && isPageSize(query.value("maxResults") ?? "")
        case .tasks:
            guard query.exactly(["showCompleted", "showDeleted", "showHidden", "updatedMin", "maxResults", "pageToken"]),
                  query.hasOnlySingletons(), isPageSize(query.value("maxResults") ?? "") else { return false }
            let reconciliation = query.hasValue("updatedMin")
            guard !reconciliation || isRFC3339(query.value("updatedMin")!) else { return false }
            let requiredState = reconciliation ? "true" : "false"
            return ["showCompleted", "showDeleted", "showHidden"].allSatisfy {
                !query.hasValue($0) || query.value($0) == requiredState
            }
        }
    }

    static func isOpaquePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_024 && value != "." && value != ".."
            && !value.unicodeScalars.contains { scalar in
                CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == "\\" || scalar == "%"
            }
    }

    private func isGmailSearch(_ value: String) -> Bool {
        if value == "newer_than:30d" { return true }
        guard value.hasPrefix("after:") else { return false }
        return Self.isPositiveInteger(String(value.dropFirst("after:".count)))
    }

    private func isPageSize(_ value: String) -> Bool {
        guard let integer = Int(value) else { return false }
        return (1...100).contains(integer) && String(integer) == value
    }

    private static func isPositiveInteger(_ value: String?) -> Bool {
        guard let value, let integer = UInt64(value) else { return false }
        return integer > 0 && String(integer) == value
    }

    private func isRFC3339(_ value: String) -> Bool {
        guard value.utf8.count <= 64 else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }
}

/// The write allowlist: the exact three method+path pairs this app may write with.
///
/// Kept apart from `Route` on purpose. `Route` answers "what may we read, and with which query
/// parameters"; this answers "what may we change". Reading the two in one enum would make it
/// easy to add a path to the wrong list.
///
/// The verb is part of the match, not a separate check the caller might forget. That is what
/// makes the collection path create-only and the event path update-only: `PATCH .../events`
/// and `POST .../events/{id}` are both refused, so neither shape of mistake can reach Google.
///
/// There is still no DELETE here, and PATCH is a PARTIAL update by definition — a body naming
/// only `start` and `end` changes only the times. That is the property that makes "move it"
/// safe to ship: it cannot blank a field it does not mention.
private enum WriteRoute {
    /// `POST /gmail/v1/users/me/messages/send` — send one message.
    case gmailSend
    /// `POST /calendar/v3/calendars/{id}/events` — insert one event.
    case calendarInsert
    /// `PATCH /calendar/v3/calendars/{id}/events/{eventId}` — change one existing event.
    case calendarPatch

    init?(method: String, host: String, path: String) {
        guard path.hasPrefix("/"), !path.hasSuffix("/"), !path.contains("//") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if host == "gmail.googleapis.com" {
            guard method == "POST",
                  components == ["gmail", "v1", "users", "me", "messages", "send"] else { return nil }
            self = .gmailSend
            return
        }
        if host == "www.googleapis.com" {
            guard Array(components.prefix(3)) == ["calendar", "v3", "calendars"],
                  components.count >= 5,
                  components[4] == "events",
                  Route.isOpaquePathComponent(components[3]) else { return nil }
            if components.count == 5 {
                guard method == "POST" else { return nil }
                self = .calendarInsert
                return
            }
            guard components.count == 6, method == "PATCH",
                  Route.isOpaquePathComponent(components[5]) else { return nil }
            self = .calendarPatch
            return
        }
        return nil
    }
}

private enum GoogleNetworkPolicyError: Error, Sendable { case rejectedRequest }
