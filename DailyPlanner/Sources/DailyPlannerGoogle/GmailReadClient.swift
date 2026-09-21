import DailyPlannerDomain
import Foundation

public enum GmailReadClientError: Error, Equatable, CaseIterable, Sendable {
    case expiredHistory
    case cancelled
    case offline
    case providerUnavailable
    case malformedResponse
    case limitViolation
}

public struct GmailReadClient: GmailReading, Sendable {
    public let transport: any GoogleHTTPTransport

    public init(transport: any GoogleHTTPTransport) {
        self.transport = transport
    }

    public func messages(
        receivedAfter: Date,
        pageToken: GmailPageToken?,
        accessToken: GoogleAccessToken
    ) async throws -> GmailMessagePage {
        do {
            let url = try GmailURL.messages(receivedAfter: receivedAfter, pageToken: pageToken)
            return try await decodePage(GmailMessagePage.self, from: sendGET(url, accessToken: accessToken))
        } catch {
            throw map(error)
        }
    }

    public func message(
        id: GmailMessageID,
        format: GmailMessageFormat,
        accessToken: GoogleAccessToken
    ) async throws -> GmailMessageRecord {
        do {
            let url = try GmailURL.message(id: id, format: format)
            let wire = try await decodePage(GmailWireMessage.self, from: sendGET(url, accessToken: accessToken))
            return try GmailWireDecoder.record(from: wire, format: format)
        } catch {
            throw map(error)
        }
    }

    public func changes(
        after historyID: GmailHistoryID,
        pageToken: GmailPageToken?,
        accessToken: GoogleAccessToken
    ) async throws -> GmailHistoryPage {
        do {
            let url = try GmailURL.history(after: historyID, pageToken: pageToken)
            let response = try await sendGET(url, accessToken: accessToken)
            guard response.statusCode != 404 else { throw GmailReadClientError.expiredHistory }
            return try decodePage(GmailHistoryPage.self, from: response)
        } catch {
            throw map(error)
        }
    }

    private func sendGET(_ url: URL, accessToken: GoogleAccessToken) async throws -> GoogleHTTPResponse {
        do {
            try Task.checkCancellation()
            let request = try GoogleRequestBuilder.get(url: url, accessToken: accessToken)
            return try await transport.send(request)
        } catch {
            throw map(error)
        }
    }
}

private enum GmailURL {
    static func messages(receivedAfter: Date, pageToken: GmailPageToken?) throws -> URL {
        let seconds = Int64(receivedAfter.timeIntervalSince1970)
        guard seconds > 0 else { throw GmailReadClientError.malformedResponse }
        var items = [
            URLQueryItem(name: "q", value: "after:\(seconds)"),
            URLQueryItem(name: "maxResults", value: "100"),
        ]
        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: try safeQueryValue(pageToken)))
        }
        return try url(path: "/gmail/v1/users/me/messages", items: items)
    }

    static func message(id: GmailMessageID, format: GmailMessageFormat) throws -> URL {
        let rawID = try GmailProviderValue.rawMessageID(id)
        var items = [URLQueryItem(name: "format", value: format.rawValue)]
        if format == .metadata {
            items.append(URLQueryItem(name: "metadataHeaders", value: "From"))
            items.append(URLQueryItem(name: "metadataHeaders", value: "Subject"))
        }
        return try url(path: "/gmail/v1/users/me/messages/\(rawID)", items: items)
    }

    static func history(after historyID: GmailHistoryID, pageToken: GmailPageToken?) throws -> URL {
        let rawHistoryID = try GmailProviderValue.rawHistoryID(historyID)
        var items = [
            URLQueryItem(name: "startHistoryId", value: rawHistoryID),
            URLQueryItem(name: "historyTypes", value: "messageAdded"),
            URLQueryItem(name: "historyTypes", value: "messageDeleted"),
            URLQueryItem(name: "maxResults", value: "100"),
        ]
        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: try safeQueryValue(pageToken)))
        }
        return try url(path: "/gmail/v1/users/me/history", items: items)
    }

    private static func url(path: String, items: [URLQueryItem]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "gmail.googleapis.com"
        components.path = path
        components.queryItems = items
        guard let url = components.url else { throw GmailReadClientError.malformedResponse }
        return url
    }

    private static func safeQueryValue(_ token: GmailPageToken) throws -> String {
        try GmailProviderValue.rawPageToken(token)
    }
}

private enum GmailProviderValue {
    static func messageID(_ value: String) throws -> GmailMessageID {
        guard isSafePathComponent(value) else { throw GmailReadClientError.malformedResponse }
        do {
            return try GmailMessageID(validating: value)
        } catch {
            throw GmailReadClientError.malformedResponse
        }
    }

    static func rawMessageID(_ value: GmailMessageID) throws -> String {
        try value.withUnsafeRawValue { rawValue in
            guard isSafePathComponent(rawValue) else { throw GmailReadClientError.malformedResponse }
            return rawValue
        }
    }

    static func historyID(_ value: String) throws -> GmailHistoryID {
        guard isPositiveInteger(value) else { throw GmailReadClientError.malformedResponse }
        do {
            return try GmailHistoryID(validating: value)
        } catch {
            throw GmailReadClientError.malformedResponse
        }
    }

    static func rawHistoryID(_ value: GmailHistoryID) throws -> String {
        try value.withUnsafeRawValue { rawValue in
            guard isPositiveInteger(rawValue) else { throw GmailReadClientError.malformedResponse }
            return rawValue
        }
    }

    static func pageToken(_ value: String?) throws -> GmailPageToken? {
        guard let value else { return nil }
        guard isSafeQueryValue(value) else { throw GmailReadClientError.malformedResponse }
        do {
            return try GmailPageToken(validating: value)
        } catch {
            throw GmailReadClientError.malformedResponse
        }
    }

    static func rawPageToken(_ value: GmailPageToken) throws -> String {
        try value.withUnsafeRawValue { rawValue in
            guard isSafeQueryValue(rawValue) else { throw GmailReadClientError.malformedResponse }
            return rawValue
        }
    }

    private static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_024 && value != "." && value != ".."
            && !value.unicodeScalars.contains { scalar in
                CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == "\\" || scalar == "%"
            }
    }

    private static func isSafeQueryValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4_096
            && !value.unicodeScalars.contains { scalar in
                CharacterSet.controlCharacters.contains(scalar) || scalar == "&" || scalar == "=" || scalar == "%"
            }
    }

    private static func isPositiveInteger(_ value: String) -> Bool {
        guard let integer = UInt64(value) else { return false }
        return integer > 0 && String(integer) == value
    }
}

private func decodePage(_ type: GmailWireMessage.Type, from response: GoogleHTTPResponse) throws -> GmailWireMessage {
    try decoded(GmailWireMessage.self, from: response)
}

private func decodePage(_ type: GmailMessagePage.Type, from response: GoogleHTTPResponse) throws -> GmailMessagePage {
    try GmailWireDecoder.messagePage(from: decoded(GmailWireList.self, from: response))
}

private func decodePage(_ type: GmailHistoryPage.Type, from response: GoogleHTTPResponse) throws -> GmailHistoryPage {
    try GmailWireDecoder.historyPage(from: decoded(GmailWireHistoryPage.self, from: response))
}

private func decoded<T: Decodable>(_ type: T.Type, from response: GoogleHTTPResponse) throws -> T {
    guard (200...299).contains(response.statusCode) else { throw GmailReadClientError.providerUnavailable }
    do {
        return try JSONDecoder().decode(T.self, from: response.data)
    } catch {
        throw GmailReadClientError.malformedResponse
    }
}

private func map(_ error: any Error) -> GmailReadClientError {
    if let error = error as? GmailReadClientError { return error }
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

private struct GmailWireList: Decodable {
    let messages: [GmailWireReference]?
    let nextPageToken: String?
}

private struct GmailWireReference: Decodable {
    let id: String
    let threadID: String

    enum CodingKeys: String, CodingKey {
        case id
        case threadID = "threadId"
    }
}

private struct GmailWireMessage: Decodable {
    let id: String
    let threadID: String
    let labelIDs: [String]?
    let snippet: String
    let internalDate: String
    let historyID: String
    let payload: GmailWirePart

    enum CodingKeys: String, CodingKey {
        case id, snippet, internalDate, payload
        case threadID = "threadId"
        case labelIDs = "labelIds"
        case historyID = "historyId"
    }
}

private struct GmailWirePart: Decodable {
    let mimeType: String
    let filename: String?
    let headers: [GmailWireHeader]?
    let body: GmailWireBody?
    let parts: [GmailWirePart]?
}

private struct GmailWireHeader: Decodable {
    let name: String
    let value: String
}

private struct GmailWireBody: Decodable {
    let data: String?
    let size: Int?
}

private struct GmailWireHistoryPage: Decodable {
    let historyID: String
    let nextPageToken: String?
    let history: [GmailWireHistory]?

    enum CodingKeys: String, CodingKey {
        case history, nextPageToken
        case historyID = "historyId"
    }
}

private struct GmailWireHistory: Decodable {
    let messagesAdded: [GmailWireHistoryMessage]?
    let messagesDeleted: [GmailWireHistoryMessage]?
}

private struct GmailWireHistoryMessage: Decodable {
    let message: GmailWireHistoryMessageID
}

private struct GmailWireHistoryMessageID: Decodable {
    let id: String
}

private enum GmailWireDecoder {
    private static let maximumParts = 512
    private static let maximumNesting = 32
    private static let maximumMetadata = 100

    static func messagePage(from wire: GmailWireList) throws -> GmailMessagePage {
        let messages = wire.messages ?? []
        guard messages.count <= 100 else { throw GmailReadClientError.limitViolation }
        return GmailMessagePage(
            messages: try messages.map { reference in
                try GmailMessageReference(
                    id: GmailProviderValue.messageID(reference.id),
                    threadID: GmailThreadID(validating: reference.threadID)
                )
            },
            nextPageToken: try GmailProviderValue.pageToken(wire.nextPageToken)
        )
    }

    static func historyPage(from wire: GmailWireHistoryPage) throws -> GmailHistoryPage {
        let entries = wire.history ?? []
        guard entries.count <= 100 else { throw GmailReadClientError.limitViolation }
        var changed: [GmailMessageID] = []
        var deleted: [GmailMessageID] = []
        for entry in entries {
            for message in entry.messagesAdded ?? [] {
                changed.append(try GmailProviderValue.messageID(message.message.id))
            }
            for message in entry.messagesDeleted ?? [] {
                deleted.append(try GmailProviderValue.messageID(message.message.id))
            }
        }
        guard changed.count <= 100, deleted.count <= 100 else { throw GmailReadClientError.limitViolation }
        return try GmailHistoryPage(
            changedMessageIDs: changed,
            deletedMessageIDs: deleted,
            nextPageToken: GmailProviderValue.pageToken(wire.nextPageToken),
            newestHistoryID: GmailProviderValue.historyID(wire.historyID)
        )
    }

    /// The privacy class for a decoded message.
    ///
    /// Under `.metadata` this client deliberately never asks for a body, so there is nothing to
    /// understand and nothing to fail closed about: the absence of a body is our own request
    /// shape, not a property of the message. The snippet Gmail returns alongside the metadata is
    /// itself non-content metadata, and showing it is the whole point of the triage surface.
    /// Classifying it `.private` withheld every snippet on the inbox and made every row read
    /// "Hidden — this message is marked private."
    ///
    /// Under `.full` a body *was* fetched, so an ambiguous traversal or an unsupported body means
    /// we genuinely could not understand the message — that still fails closed to `.private`.
    private static func privacyClass(
        format: GmailMessageFormat,
        traversal: MIMETraversal,
        body: SelectedBody
    ) -> SourcePrivacyClass {
        switch format {
        case .metadata:
            return .ordinary
        case .full:
            return traversal.isUncertain || body.kind == .unsupported ? .private : .ordinary
        }
    }

    static func record(from wire: GmailWireMessage, format: GmailMessageFormat) throws -> GmailMessageRecord {
        let labels = wire.labelIDs ?? []
        guard labels.count <= maximumMetadata else { throw GmailReadClientError.limitViolation }
        try labels.forEach(validateDisplay)
        try validateDisplay(wire.snippet)

        let sender = try requiredHeader("From", in: wire.payload.headers ?? [])
        let subject = try requiredHeader("Subject", in: wire.payload.headers ?? [])
        try validateDisplay(sender)
        try validateDisplay(subject)
        guard let milliseconds = Int64(wire.internalDate), milliseconds >= 0 else {
            throw GmailReadClientError.malformedResponse
        }

        var traversal = MIMETraversal()
        try traversal.visit(wire.payload, depth: 1)
        let body = try traversal.selectedBody()
        let summary = try GmailMessageSummary(
            id: GmailProviderValue.messageID(wire.id),
            threadID: GmailThreadID(validating: wire.threadID),
            sender: sender,
            subject: subject,
            receivedAt: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000),
            labels: labels,
            snippet: wire.snippet,
            historyID: GmailProviderValue.historyID(wire.historyID),
            privacyClass: privacyClass(format: format, traversal: traversal, body: body)
        )
        return GmailMessageRecord(
            summary: summary,
            bodyKind: body.kind,
            decodedBody: body.value,
            attachments: traversal.attachments
        )
    }

    private static func requiredHeader(_ name: String, in headers: [GmailWireHeader]) throws -> String {
        let matches = headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard matches.count == 1 else { throw GmailReadClientError.malformedResponse }
        return matches[0].value
    }

    private static func validateDisplay(_ value: String) throws {
        guard value.unicodeScalars.count <= GoogleSyncLimits.displayScalars else {
            throw GmailReadClientError.limitViolation
        }
    }

    private struct SelectedBody {
        let kind: EmailBodyKind
        let value: String?
    }

    private struct MIMETraversal {
        var partCount = 0
        var attachments: [EmailAttachmentMetadata] = []
        var plainData: String?
        var htmlData: String?
        var isUncertain = false

        mutating func visit(_ part: GmailWirePart, depth: Int) throws {
            guard depth <= maximumNesting else { throw GmailReadClientError.limitViolation }
            partCount += 1
            guard partCount <= maximumParts else { throw GmailReadClientError.limitViolation }
            try validateDisplay(part.mimeType)
            if let filename = part.filename {
                try validateDisplay(filename)
                if !filename.isEmpty {
                    guard attachments.count < maximumMetadata,
                          let size = part.body?.size,
                          size >= 0 else { throw GmailReadClientError.limitViolation }
                    attachments.append(EmailAttachmentMetadata(filename: filename, mimeType: part.mimeType, size: size))
                }
            }
            for child in part.parts ?? [] {
                try visit(child, depth: depth + 1)
            }

            guard part.filename?.isEmpty != false else { return }
            let mimeType = part.mimeType.lowercased()
            if mimeType == "text/plain" || mimeType == "text/html" {
                guard let encoded = part.body?.data else {
                    isUncertain = true
                    return
                }
                if mimeType == "text/plain" {
                    if plainData == nil { plainData = encoded } else { isUncertain = true }
                }
                if mimeType == "text/html" {
                    if htmlData == nil { htmlData = encoded } else { isUncertain = true }
                }
            } else if !mimeType.hasPrefix("multipart/") {
                isUncertain = true
            }
        }

        mutating func selectedBody() throws -> SelectedBody {
            guard !isUncertain else { return SelectedBody(kind: .unsupported, value: nil) }
            let selected: (kind: EmailBodyKind, data: String)?
            if let plainData {
                selected = (.plainText, plainData)
            } else if let htmlData {
                selected = (.html, htmlData)
            } else {
                selected = nil
            }
            guard let selected else { return SelectedBody(kind: .unsupported, value: nil) }
            let decoded = try decodeBase64URL(selected.data)
            guard let value = String(data: decoded, encoding: .utf8) else {
                isUncertain = true
                return SelectedBody(kind: .unsupported, value: nil)
            }
            return SelectedBody(kind: selected.kind, value: value)
        }

        private func decodeBase64URL(_ encoded: String) throws -> Data {
            let maximumEncodedBytes = ((GoogleSyncLimits.decodedBodyBytes + 2) / 3) * 4
            guard encoded.utf8.count <= maximumEncodedBytes else { throw GmailReadClientError.limitViolation }
            guard encoded.unicodeScalars.allSatisfy({ scalar in
                      (0x41...0x5A).contains(scalar.value)
                          || (0x61...0x7A).contains(scalar.value)
                          || (0x30...0x39).contains(scalar.value)
                          || scalar == "-" || scalar == "_"
                  }) else { throw GmailReadClientError.malformedResponse }
            let remainder = encoded.utf8.count % 4
            guard remainder != 1 else { throw GmailReadClientError.malformedResponse }
            let base64 = encoded.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
                + String(repeating: "=", count: (4 - remainder) % 4)
            guard let data = Data(base64Encoded: base64) else { throw GmailReadClientError.malformedResponse }
            guard data.count <= GoogleSyncLimits.decodedBodyBytes else { throw GmailReadClientError.limitViolation }
            let canonical = data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
            guard canonical == encoded else { throw GmailReadClientError.malformedResponse }
            return data
        }
    }
}
