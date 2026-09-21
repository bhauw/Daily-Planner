import DailyPlannerDomain
import Foundation
import XCTest
@testable import DailyPlannerGoogle

final class GmailReadClientTests: XCTestCase {
    func testMessagesBuildsBoundedThirtyDayQueryAndDecodesOpaqueIDs() async throws {
        let harness = GmailHarness(response: fixture("gmail-list"))

        let page = try await harness.client.messages(
            receivedAfter: Date(timeIntervalSince1970: 1_788_112_800),
            pageToken: nil,
            accessToken: harness.token
        )

        XCTAssertEqual(page.messages.count, 2)
        XCTAssertEqual(harness.request.httpMethod, "GET")
        XCTAssertEqual(harness.query["maxResults"], ["100"])
        XCTAssertEqual(harness.query["q"], ["after:1788112800"])
    }

    func testFullMessageDecodesPreferredPlainPartBoundsFieldsAndNeverRequestsAttachment() async throws {
        let harness = GmailHarness(response: fixture("gmail-message-multipart"))

        let record = try await harness.client.message(
            id: harness.messageID,
            format: .full,
            accessToken: harness.token
        )

        XCTAssertEqual(record.bodyKind, .plainText)
        XCTAssertEqual(record.decodedBody, "Plain text body.")
        XCTAssertEqual(record.attachments.map(\.filename), ["statement.pdf"])
        XCTAssertFalse(harness.request.url!.path.contains("attachments"))
        XCTAssertEqual(harness.sendCount, 1)
    }

    func testMetadataMessageStaysOrdinarySoTheSnippetIsNotWithheld() async throws {
        // Exactly what Gmail returns for `format=metadata`: headers and a snippet, with a payload
        // carrying no body and no parts. The classifier used to read that missing body as "could
        // not understand this message" and fail closed to `.private`, so EVERY triage row on the
        // real inbox rendered "Hidden — this message is marked private." The absence of a body is
        // our own request shape here, not a property of the message.
        for payload in [
            part(mimeType: "multipart/alternative"),
            part(mimeType: "text/html"),
            part(mimeType: "text/plain"),
        ] {
            let harness = GmailHarness(
                response: messageJSON(snippet: "a real snippet", payload: payload)
            )

            let record = try await harness.client.message(
                id: harness.messageID,
                format: .metadata,
                accessToken: harness.token
            )

            XCTAssertEqual(record.summary.privacyClass, .ordinary)
            XCTAssertEqual(record.summary.snippet, "a real snippet")
            XCTAssertNil(record.decodedBody, "metadata format must never carry a body")
        }
    }

    func testMessageFailsClosedForAmbiguousOrUncertainMIMETraversal() async throws {
        let duplicatePlain = part(mimeType: "multipart/mixed", parts: [
            part(mimeType: "text/plain", data: "cGxhaW4"),
            part(mimeType: "text/plain", data: "b3RoZXI"),
        ])
        let missingHTMLAlongsidePlain = part(mimeType: "multipart/alternative", parts: [
            part(mimeType: "text/html"),
            part(mimeType: "text/plain", data: "cGxhaW4"),
        ])

        for payload in [duplicatePlain, missingHTMLAlongsidePlain] {
            let record = try await GmailHarness(response: messageJSON(payload: payload)).client.message(
                id: try GmailMessageID(validating: "message-one"),
                format: .full,
                accessToken: try GoogleAccessToken(validating: "synthetic-access-token")
            )
            XCTAssertEqual(record.bodyKind, .unsupported)
            XCTAssertNil(record.decodedBody)
            XCTAssertEqual(record.summary.privacyClass, .private)
        }
    }

    func testMessageClassifiesUnsupportedNoCandidateMIMEAsPrivate() async throws {
        let harness = GmailHarness(response: messageJSON(payload: part(mimeType: "multipart/mixed")))
        let record = try await harness.client.message(
            id: harness.messageID,
            format: .full,
            accessToken: harness.token
        )

        XCTAssertEqual(record.bodyKind, .unsupported)
        XCTAssertNil(record.decodedBody)
        XCTAssertEqual(record.summary.privacyClass, .private)
    }

    func testDecodedProviderIdentifiersAndTokensRejectUnsafeAndOverlongValues() async {
        let overlongToken = String(repeating: "t", count: 4_097)
        for response in [
            listJSON(messages: [["id": "unsafe/id", "threadId": "thread-one"]]),
            listJSON(messages: [["id": "unsafe%id", "threadId": "thread-one"]]),
            listJSON(messages: [], nextPageToken: overlongToken),
        ] {
            await assertFiniteError(GmailHarness(response: response).messagesOperation(), expected: .malformedResponse)
        }
        for id in ["unsafe/id", "unsafe%id"] {
            await assertFiniteError(
                GmailHarness(response: messageJSON(id: id)).messageOperation(),
                expected: .malformedResponse
            )
        }
    }

    func testDecodedHistoryIdentifiersAndTokensRejectNoncanonicalValues() async {
        let overlongToken = String(repeating: "t", count: 4_097)
        for historyID in ["0", "01", "-1", "history-101"] {
            await assertFiniteError(
                GmailHarness(response: historyJSON(historyID: historyID)).historyOperation(),
                expected: .malformedResponse
            )
            await assertFiniteError(
                GmailHarness(response: messageJSON(historyID: historyID)).messageOperation(),
                expected: .malformedResponse
            )
        }
        await assertFiniteError(
            GmailHarness(response: historyJSON(nextPageToken: overlongToken)).historyOperation(),
            expected: .malformedResponse
        )
    }

    func testHistoryDecodesOnePageAndBuildsExactRequest() async throws {
        let harness = GmailHarness(response: fixture("gmail-history"))
        let page = try await harness.client.changes(
            after: harness.historyID,
            pageToken: nil,
            accessToken: harness.token
        )

        XCTAssertEqual(page.changedMessageIDs, [try GmailMessageID(validating: "message-one")])
        XCTAssertEqual(page.deletedMessageIDs, [try GmailMessageID(validating: "message-two")])
        XCTAssertEqual(page.nextPageToken, try GmailPageToken(validating: "history-page-2"))
        XCTAssertEqual(page.newestHistoryID, try GmailHistoryID(validating: "102"))
        XCTAssertEqual(harness.request.url?.path, "/gmail/v1/users/me/history")
        XCTAssertEqual(harness.query["startHistoryId"], ["100"])
        XCTAssertEqual(harness.query["historyTypes"], ["messageAdded", "messageDeleted"])
        XCTAssertEqual(harness.query["maxResults"], ["100"])
        XCTAssertEqual(harness.sendCount, 1)
    }

    func testHistory404MapsExactlyToExpiredHistoryAfterOneSend() async {
        let harness = GmailHarness(result: .response(status: 404, data: Data()))
        do {
            _ = try await harness.client.changes(after: harness.historyID, pageToken: nil, accessToken: harness.token)
            XCTFail("expected expired history")
        } catch {
            XCTAssertEqual(error as? GmailReadClientError, .expiredHistory)
            XCTAssertEqual(harness.sendCount, 1)
        }
    }

    func testMessageRejectsNoncanonicalBase64URLTerminalQuanta() async {
        for encoded in ["Zh", "Zm9"] {
            await assertFiniteError(
                GmailHarness(response: messageJSON(payload: part(mimeType: "text/plain", data: encoded))).messageOperation(),
                expected: .malformedResponse
            )
        }
    }

    func testHistoryMaps404ToExpiredHistoryAndRejectsMalformedResponses() async {
        for invalidCase in GmailHarness.invalidCases {
            do {
                try await invalidCase.operation()
                XCTFail("invalid Gmail response was accepted")
            } catch let error as GmailReadClientError {
                XCTAssertTrue([.expiredHistory, .malformedResponse, .limitViolation].contains(error))
            } catch {
                XCTFail("raw error escaped the Gmail client")
            }
        }
    }

    func testMessageRejectsAbsentOrDuplicateRequiredHeadersAndInvalidInternalDate() async {
        for response in [
            messageJSON(headers: [["name": "Subject", "value": "subject"]]),
            messageJSON(headers: [["name": "From", "value": "sender@example.test"]]),
            messageJSON(headers: [
                ["name": "From", "value": "first@example.test"],
                ["name": "From", "value": "second@example.test"],
                ["name": "Subject", "value": "subject"],
            ]),
            messageJSON(headers: [
                ["name": "From", "value": "sender@example.test"],
                ["name": "Subject", "value": "first subject"],
                ["name": "Subject", "value": "second subject"],
            ]),
            messageJSON(internalDate: "not-a-date"),
        ] {
            await assertFiniteError(GmailHarness(response: response).messageOperation())
        }
    }

    func testMessageMapsTransportCancellationOfflineAndProviderFailureToFiniteErrors() async {
        let expected: [(GmailHarness.Result, GmailReadClientError)] = [
            (.failure(CancellationError()), .cancelled),
            (.failure(GoogleHTTPTransportError.cancelled), .cancelled),
            (.failure(GoogleHTTPTransportError.requestFailed), .offline),
            (.failure(GoogleHTTPTransportError.nonHTTPResponse), .providerUnavailable),
            (.response(status: 503, data: fixture("gmail-list")), .providerUnavailable),
        ]

        for (result, expectedError) in expected {
            let harness = GmailHarness(result: result)
            do {
                try await harness.messageOperation()()
                XCTFail("expected finite client error")
            } catch {
                XCTAssertEqual(error as? GmailReadClientError, expectedError)
            }
        }
    }

    func testMessageRejectsDisplayAndStructuralLimits() async {
        let tooLong = String(repeating: "x", count: 513)
        let tooDeep = nestedPart(depth: 33)
        let tooManyParts = (0..<513).map { _ in part(mimeType: "application/octet-stream") }
        let oversizedPlain = Data(repeating: 65, count: 512 * 1_024 + 1).base64EncodedString()

        for response in [
            messageJSON(sender: tooLong),
            messageJSON(subject: tooLong),
            messageJSON(snippet: tooLong),
            messageJSON(labels: Array(repeating: "INBOX", count: 101)),
            messageJSON(payload: tooDeep),
            messageJSON(payload: part(mimeType: "multipart/mixed", parts: tooManyParts)),
            messageJSON(payload: part(mimeType: "text/plain", data: oversizedPlain)),
        ] {
            await assertFiniteError(GmailHarness(response: response).messageOperation(), expected: .limitViolation)
        }
    }

    func testMalformedPageTokensAreMappedToFiniteErrors() async {
        let malformedList = Data("{\"messages\":[],\"nextPageToken\":\"\"}".utf8)
        let malformedHistory = Data("{\"historyId\":\"history-1\",\"nextPageToken\":\"\"}".utf8)
        await assertFiniteError(GmailHarness(response: malformedList).messagesOperation())
        await assertFiniteError(GmailHarness(response: malformedHistory).historyOperation())
    }

    private func assertFiniteError(
        _ operation: @escaping @Sendable () async throws -> Void,
        expected: GmailReadClientError? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("expected finite client error", file: file, line: line)
        } catch let error as GmailReadClientError {
            if let expected { XCTAssertEqual(error, expected, file: file, line: line) }
        } catch {
            XCTFail("raw error escaped the Gmail client", file: file, line: line)
        }
    }
}

private final class GmailHarness: @unchecked Sendable {
    struct InvalidCase: @unchecked Sendable {
        let operation: @Sendable () async throws -> Void
    }

    enum Result: @unchecked Sendable {
        case response(status: Int = 200, data: Data)
        case failure(any Error)
    }

    final class Transport: GoogleHTTPTransport, @unchecked Sendable {
        private let result: Result
        private var sent: [URLRequest] = []

        init(result: Result) { self.result = result }

        func send(_ request: URLRequest) async throws -> GoogleHTTPResponse {
            sent.append(request)
            switch result {
            case let .response(status, data): return GoogleHTTPResponse(statusCode: status, data: data)
            case let .failure(error): throw error
            }
        }

        var requests: [URLRequest] { sent }
    }

    let token = try! GoogleAccessToken(validating: "synthetic-access-token")
    let messageID = try! GmailMessageID(validating: "message-one")
    let historyID = try! GmailHistoryID(validating: "100")
    let transport: Transport
    let client: GmailReadClient

    convenience init(response: Data) { self.init(result: .response(data: response)) }
    init(result: Result) {
        transport = Transport(result: result)
        client = GmailReadClient(transport: transport)
    }

    var request: URLRequest { transport.requests.last! }
    var sendCount: Int { transport.requests.count }
    var query: [String: [String]] {
        Dictionary(grouping: request.urlComponents.queryItems ?? [], by: \.name).mapValues { $0.compactMap(\.value) }
    }

    func messageOperation() -> @Sendable () async throws -> Void {
        { _ = try await self.client.message(id: self.messageID, format: .full, accessToken: self.token) }
    }

    func messagesOperation() -> @Sendable () async throws -> Void {
        { _ = try await self.client.messages(receivedAfter: Date(timeIntervalSince1970: 1_788_112_800), pageToken: nil, accessToken: self.token) }
    }

    func historyOperation() -> @Sendable () async throws -> Void {
        { _ = try await self.client.changes(after: self.historyID, pageToken: nil, accessToken: self.token) }
    }

    static var invalidCases: [InvalidCase] {
        let expiredHistory = GmailHarness(result: .response(status: 404, data: Data()))
        let missingHistoryID = GmailHarness(response: Data("{\"history\":[]}".utf8))
        let invalidBase64 = GmailHarness(response: messageJSON(payload: part(mimeType: "text/plain", data: "%%not-base64%%")))
        let oversizedBody = GmailHarness(response: messageJSON(payload: part(mimeType: "text/plain", data: Data(repeating: 65, count: 512 * 1_024 + 1).base64EncodedString())))
        return [
            InvalidCase(operation: expiredHistory.historyOperation()),
            InvalidCase(operation: missingHistoryID.historyOperation()),
            InvalidCase(operation: invalidBase64.messageOperation()),
            InvalidCase(operation: oversizedBody.messageOperation()),
        ]
    }
}

private func fixture(_ name: String) -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "json")!
    return try! Data(contentsOf: url)
}

private func messageJSON(
    headers: [[String: String]] = [
        ["name": "From", "value": "sender@example.test"],
        ["name": "Subject", "value": "subject"],
    ],
    sender: String? = nil,
    subject: String? = nil,
    id: String = "message-one",
    snippet: String = "snippet",
    labels: [String] = ["INBOX"],
    internalDate: String = "1788112800000",
    historyID: String = "100",
    payload: [String: Any] = part(mimeType: "text/plain", data: "cGxhaW4"),
) -> Data {
    var resolvedHeaders = headers
    if let sender { resolvedHeaders = [["name": "From", "value": sender], ["name": "Subject", "value": "subject"]] }
    if let subject { resolvedHeaders = [["name": "From", "value": "sender@example.test"], ["name": "Subject", "value": subject]] }
    let object: [String: Any] = [
        "id": id, "threadId": "thread-one", "labelIds": labels, "snippet": snippet,
        "internalDate": internalDate, "historyId": historyID, "payload": payload.merging(["headers": resolvedHeaders]) { _, new in new },
    ]
    return try! JSONSerialization.data(withJSONObject: object)
}

private func listJSON(messages: [[String: String]], nextPageToken: String? = nil) -> Data {
    var object: [String: Any] = ["messages": messages]
    if let nextPageToken { object["nextPageToken"] = nextPageToken }
    return try! JSONSerialization.data(withJSONObject: object)
}

private func historyJSON(historyID: String = "102", nextPageToken: String? = nil) -> Data {
    var object: [String: Any] = ["historyId": historyID, "history": []]
    if let nextPageToken { object["nextPageToken"] = nextPageToken }
    return try! JSONSerialization.data(withJSONObject: object)
}

private func part(mimeType: String, data: String? = nil, parts: [[String: Any]] = []) -> [String: Any] {
    var result: [String: Any] = ["mimeType": mimeType]
    if let data { result["body"] = ["data": data] }
    if !parts.isEmpty { result["parts"] = parts }
    return result
}

private func nestedPart(depth: Int) -> [String: Any] {
    guard depth > 1 else { return part(mimeType: "text/plain", data: "cGxhaW4") }
    return part(mimeType: "multipart/mixed", parts: [nestedPart(depth: depth - 1)])
}

private extension URLRequest {
    var urlComponents: URLComponents {
        URLComponents(url: url!, resolvingAgainstBaseURL: false)!
    }
}
