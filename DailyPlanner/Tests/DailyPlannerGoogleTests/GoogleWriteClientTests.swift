import Foundation
import XCTest
import DailyPlannerDomain
@testable import DailyPlannerGoogle

/// The two write clients, and the allowlist that decides whether their requests may leave at all.
///
/// `GoogleRequestBuilder.postJSON` validates against `GoogleNetworkPolicy` before returning, so
/// every success here is also an assertion that the policy permits exactly this request — and
/// every policy rejection below is one a bug in a client would hit before Google ever saw it.
final class GoogleWriteClientTests: XCTestCase {
    private final class Transport: GoogleHTTPTransport, @unchecked Sendable {
        var status = 200
        var data = Data()
        var failure: (any Error)?
        var sent: [URLRequest] = []

        func send(_ request: URLRequest) async throws -> GoogleHTTPResponse {
            sent.append(request)
            if let failure { throw failure }
            return GoogleHTTPResponse(statusCode: status, data: data)
        }
    }

    private let token = try! GoogleAccessToken(validating: "synthetic-access-token")

    private func mail(
        to: [String] = ["friend@example.com"],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String = "Lunch",
        body: String = "Thursday?",
        threadID: String? = nil,
        inReplyTo: String? = nil
    ) throws -> PlannerOutgoingMail {
        try PlannerOutgoingMail(
            to: to, cc: cc, bcc: bcc, subject: subject, body: body,
            threadID: threadID, inReplyTo: inReplyTo
        )
    }

    // MARK: - The allowlist

    func testPolicyAcceptsExactlyTheTwoWriteEndpoints() throws {
        // Break caught: a write endpoint is missing from the allowlist, so sending fails closed
        // with no explanation — or one was added with the wrong shape.
        try GoogleNetworkPolicy.validate(
            writeRequest("https://gmail.googleapis.com/gmail/v1/users/me/messages/send")
        )
        try GoogleNetworkPolicy.validate(
            writeRequest("https://www.googleapis.com/calendar/v3/calendars/primary/events")
        )
        try GoogleNetworkPolicy.validate(
            writeRequest("https://www.googleapis.com/calendar/v3/calendars/calendar@example.test/events")
        )
    }

    func testPolicyRejectsEverythingAdjacentToAWrite() {
        // Break caught: the write allowlist is looser than the read one it sits beside. Each
        // entry here is a plausible near-miss, and a real capability if it got through.
        let rejected: [URLRequest] = [
            // Mutation verbs other than POST reach nothing, anywhere.
            writeRequest("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", method: "PUT"),
            writeRequest("https://www.googleapis.com/calendar/v3/calendars/primary/events", method: "PATCH"),
            writeRequest("https://www.googleapis.com/calendar/v3/calendars/primary/events", method: "DELETE"),
            // Deleting or trashing mail is not a capability this app has.
            writeRequest("https://gmail.googleapis.com/gmail/v1/users/me/messages/abc/trash"),
            writeRequest("https://gmail.googleapis.com/gmail/v1/users/me/messages/abc/modify"),
            writeRequest("https://gmail.googleapis.com/gmail/v1/users/me/drafts"),
            // Neither is writing to Tasks.
            writeRequest("https://tasks.googleapis.com/tasks/v1/lists/abc/tasks"),
            // `sendUpdates` is how a calendar insert mails every attendee. That is a separate,
            // deliberate feature — no query is permitted on a write, so it cannot be reached.
            writeRequest("https://www.googleapis.com/calendar/v3/calendars/primary/events?sendUpdates=all"),
            // A body must be present, bounded, and JSON; the headers are exactly two.
            writeRequest("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", body: Data()),
            writeRequest("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", contentType: "text/plain"),
            writeRequest("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", extraHeader: ("X-Goog-Api-Key", "k")),
            writeRequest("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", authorization: nil),
            writeRequest("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", authorization: "Basic abc"),
            // Wrong host for the right path.
            writeRequest("https://www.googleapis.com/gmail/v1/users/me/messages/send"),
            writeRequest("https://gmail.googleapis.com/calendar/v3/calendars/primary/events"),
            // Path traversal and near misses.
            writeRequest("https://gmail.googleapis.com/gmail/v1/users/me/messages/send/"),
            writeRequest("https://www.googleapis.com/calendar/v3/calendars/primary/events/evt-1"),
            writeRequest("https://www.googleapis.com/calendar/v3/calendars//events"),
        ]
        for request in rejected {
            XCTAssertThrowsError(
                try GoogleNetworkPolicy.validate(request),
                "must be refused: \(request.httpMethod ?? "?") \(request.url?.absoluteString ?? "?")"
            )
        }
    }

    func testPolicyRejectsAnOversizeWriteBody() {
        // Break caught: the only bound on an upload is the one the loopback server happens to
        // apply. This is the independent one, on the side that actually leaves the machine.
        var request = writeRequest("https://gmail.googleapis.com/gmail/v1/users/me/messages/send")
        request.httpBody = Data(repeating: 0x41, count: 512 * 1024 + 1)
        XCTAssertThrowsError(try GoogleNetworkPolicy.validate(request))
    }

    func testReadRequestsStillMayNotCarryABody() {
        // Break caught: opening POST loosened the read case beside it.
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.withUnsafeRawValue { $0 })", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{}".utf8)
        XCTAssertThrowsError(try GoogleNetworkPolicy.validate(request))
    }

    // MARK: - The RFC 2822 message

    func testMessageHasAHeaderBlockABlankLineAndABase64Body() throws {
        // Break caught: the blank line between headers and body is missing or wrong, which turns
        // the entire message into headers and delivers nothing the user wrote.
        let rendered = RFC2822Message.render(try mail(cc: ["cc@example.com"], bcc: ["bcc@example.com"]))
        let parts = rendered.components(separatedBy: "\r\n\r\n")
        XCTAssertEqual(parts.count, 2, "exactly one header/body separator")

        let headers = parts[0].components(separatedBy: "\r\n")
        XCTAssertEqual(headers[0], "To: friend@example.com")
        XCTAssertTrue(headers.contains("Cc: cc@example.com"))
        // Gmail strips Bcc on send and delivers the blind copies; it is the documented route.
        XCTAssertTrue(headers.contains("Bcc: bcc@example.com"))
        XCTAssertTrue(headers.contains("Subject: Lunch"))
        XCTAssertTrue(headers.contains("MIME-Version: 1.0"))
        XCTAssertTrue(headers.contains(#"Content-Type: text/plain; charset="UTF-8""#))
        XCTAssertTrue(headers.contains("Content-Transfer-Encoding: base64"))
        // No From header — Gmail fills it with the authenticated account, so this app never has
        // to know or store the user's own address in order to send as them.
        XCTAssertFalse(headers.contains { $0.hasPrefix("From:") })

        let decoded = Data(base64Encoded: parts[1].replacingOccurrences(of: "\r\n", with: ""))
        XCTAssertEqual(decoded.flatMap { String(data: $0, encoding: .utf8) }, "Thursday?")
    }

    func testMultipleRecipientsAreCommaSeparatedOnOneHeaderLine() throws {
        let rendered = RFC2822Message.render(try mail(to: ["a@example.com", "b@example.com"]))
        XCTAssertTrue(rendered.hasPrefix("To: a@example.com, b@example.com\r\n"))
    }

    func testReplyCarriesBothThreadingHeaders() throws {
        // Clients differ on which they thread by, so both are written.
        let rendered = RFC2822Message.render(try mail(inReplyTo: "<abc@mail.gmail.com>"))
        XCTAssertTrue(rendered.contains("In-Reply-To: <abc@mail.gmail.com>\r\n"))
        XCTAssertTrue(rendered.contains("References: <abc@mail.gmail.com>\r\n"))
    }

    func testNonASCIISubjectsBecomeFoldedEncodedWords() {
        // Break caught: an accented or emoji subject is written raw into a header, where it is
        // not valid, and arrives as mojibake — or is split mid-character by the folding.
        let subject = "Café ☕ " + String(repeating: "naïve ", count: 20)
        let encoded = RFC2822Message.encodedSubject(subject)
        XCTAssertTrue(encoded.hasPrefix("=?UTF-8?B?"))
        for line in encoded.components(separatedBy: "\r\n ") {
            XCTAssertLessThanOrEqual(line.count, 76, "each encoded word must fit a header line")
        }

        // Round-trip: every chunk decodes, and concatenated they are the original subject.
        let decoded = encoded
            .components(separatedBy: "\r\n ")
            .compactMap { word -> String? in
                let payload = word.dropFirst("=?UTF-8?B?".count).dropLast("?=".count)
                return Data(base64Encoded: String(payload)).flatMap { String(data: $0, encoding: .utf8) }
            }
            .joined()
        XCTAssertEqual(decoded, subject, "folding must never split a UTF-8 character")
    }

    func testPlainASCIISubjectIsNotEncoded() {
        XCTAssertEqual(RFC2822Message.encodedSubject("Re: Office hours"), "Re: Office hours")
    }

    func testBodyIsWrappedSoNoLineRunsPastSeventySix() throws {
        let rendered = RFC2822Message.render(try mail(body: String(repeating: "x", count: 5_000)))
        let body = rendered.components(separatedBy: "\r\n\r\n")[1]
        for line in body.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.count, 76)
        }
    }

    // MARK: - Sending

    func testSendPostsBase64URLRawAndReturnsTheProviderIdentity() async throws {
        let transport = Transport()
        transport.data = Data(#"{"id":"m-1","threadId":"t-1"}"#.utf8)
        let sent = try await GmailSendClient(transport: transport)
            .send(try mail(threadID: "t-1"), accessToken: token)

        XCTAssertEqual(sent.id, "m-1")
        XCTAssertEqual(sent.threadID, "t-1")

        let request = try XCTUnwrap(transport.sent.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")

        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(payload["threadId"] as? String, "t-1")
        let encoded = try XCTUnwrap(payload["raw"] as? String)
        // base64url, unpadded — the encoding Gmail's `raw` field is specified in.
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))

        var padded = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        let message = try XCTUnwrap(Data(base64Encoded: padded).flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(message.hasPrefix("To: friend@example.com\r\n"))
    }

    func testProviderStatusesMapToDistinctOutcomes() async throws {
        // Break caught: a revoked grant and a Google outage produce the same message. The first
        // needs the user to reconnect; the second needs them to wait.
        for status in [400, 401, 403, 429] {
            let transport = Transport()
            transport.status = status
            transport.data = Data("{}".utf8)
            await XCTAssertThrowsErrorAsync(
                try await GmailSendClient(transport: transport).send(try mail(), accessToken: token)
            ) { error in
                XCTAssertEqual(error as? GmailSendClientError, .refused, "status \(status)")
                XCTAssertEqual((error as? GmailSendClientError)?.writeOutcome, .refused)
            }
        }
        for status in [500, 502, 503] {
            let transport = Transport()
            transport.status = status
            await XCTAssertThrowsErrorAsync(
                try await GmailSendClient(transport: transport).send(try mail(), accessToken: token)
            ) { error in
                XCTAssertEqual((error as? GmailSendClientError)?.writeOutcome, .unavailable, "status \(status)")
            }
        }
    }

    func testAnUnreadableReceiptIsNotReportedAsARefusal() async throws {
        // Break caught: a 200 whose body we cannot parse is treated as "did not send". The send
        // most likely DID happen and we simply could not read the receipt, so it is reported as
        // not-through and — deliberately — never retried automatically.
        let transport = Transport()
        transport.data = Data("not json".utf8)
        await XCTAssertThrowsErrorAsync(
            try await GmailSendClient(transport: transport).send(try mail(), accessToken: token)
        ) { error in
            XCTAssertEqual(error as? GmailSendClientError, .malformedResponse)
            XCTAssertEqual((error as? GmailSendClientError)?.writeOutcome, .unavailable)
        }
    }

    // MARK: - Scheduling

    func testCreateEventPostsTheDraftAndPrefersGooglesStoredTimes() async throws {
        let transport = Transport()
        transport.data = Data("""
        {"id":"e-1","htmlLink":"https://calendar.google.com/e/1",
         "start":{"dateTime":"2026-09-16T16:00:00Z"},"end":{"dateTime":"2026-09-16T17:00:00Z"}}
        """.utf8)
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        let draft = try PlannerEventDraft(
            title: "Study block", start: start, end: start.addingTimeInterval(3_600),
            location: "Library", notes: "Problem set 3"
        )
        let created = try await GoogleCalendarWriteClient(transport: transport).create(draft, accessToken: token)

        XCTAssertEqual(created.id, "e-1")
        XCTAssertEqual(created.link, "https://calendar.google.com/e/1")
        // Google echoes what it stored; if it moved anything, the user is shown what is actually
        // on their calendar rather than what was asked for.
        XCTAssertEqual(RFC3339.string(from: created.start), "2026-09-16T16:00:00Z")

        let request = try XCTUnwrap(transport.sent.first)
        XCTAssertEqual(request.url?.absoluteString, "https://www.googleapis.com/calendar/v3/calendars/primary/events")
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(payload["summary"] as? String, "Study block")
        XCTAssertEqual(payload["location"] as? String, "Library")
        XCTAssertEqual(payload["description"] as? String, "Problem set 3")
        XCTAssertNotNil((payload["start"] as? [String: Any])?["dateTime"])
    }

    func testNamedCalendarLandsInThePathAndFallsBackToTheDraftTimes() async throws {
        let transport = Transport()
        transport.data = Data(#"{"id":"e-2"}"#.utf8)
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        let draft = try PlannerEventDraft(
            calendarID: CalendarID(rawValue: "calendar@example.test"),
            title: "Class", start: start, end: start.addingTimeInterval(3_600)
        )
        let created = try await GoogleCalendarWriteClient(transport: transport).create(draft, accessToken: token)

        XCTAssertEqual(
            transport.sent.first?.url?.absoluteString,
            "https://www.googleapis.com/calendar/v3/calendars/calendar@example.test/events"
        )
        // No echo in the response, so the requested times stand.
        XCTAssertEqual(created.start, start)
        XCTAssertEqual(created.end, start.addingTimeInterval(3_600))
    }

    // MARK: - Helpers

    private func writeRequest(
        _ url: String,
        method: String = "POST",
        body: Data? = Data(#"{"raw":"x"}"#.utf8),
        contentType: String? = "application/json",
        authorization: String? = "Bearer synthetic-access-token",
        extraHeader: (String, String)? = nil
    ) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.httpBody = body
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        if let extraHeader { request.setValue(extraHeader.1, forHTTPHeaderField: extraHeader.0) }
        return request
    }
}

/// `XCTAssertThrowsError` does not accept an `await` in its autoclosure on this toolchain.
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (any Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
