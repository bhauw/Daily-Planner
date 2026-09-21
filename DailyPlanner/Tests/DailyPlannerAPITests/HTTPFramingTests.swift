import Foundation
import XCTest
@testable import DailyPlannerAPI

/// Framing is where a server decides how much of the byte stream is "this request". The read-only
/// engine never had to: it stopped at the header terminator and handed the buffer on. The moment
/// a route takes a body, that shortcut becomes a bug — a body arriving in a second TCP segment
/// would be dispatched as an empty one — and every rule below is a way of getting it wrong.
final class HTTPFramingTests: XCTestCase {
    private func raw(
        _ method: String = "POST",
        path: String = "/api/mail/send",
        headers: [String] = [],
        body: String = ""
    ) -> Data {
        var text = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:1234\r\n"
        for header in headers { text += header + "\r\n" }
        text += "\r\n"
        return Data(text.utf8) + Data(body.utf8)
    }

    private func complete(_ framing: HTTPFraming) -> HTTPRequest? {
        if case .complete(let request) = framing { return request }
        return nil
    }

    private func refusalStatus(_ framing: HTTPFraming) -> Int? {
        if case .refused(let response) = framing { return response.status }
        return nil
    }

    private func isIncomplete(_ framing: HTTPFraming) -> Bool {
        if case .incomplete = framing { return true }
        return false
    }

    func testBodyIsFramedByContentLength() throws {
        // Break caught: the body is not attached, or is attached with the wrong length.
        let body = #"{"subject":"hi"}"#
        let framing = HTTPFraming.frame(
            raw(headers: ["Content-Length: \(body.utf8.count)"], body: body)
        )
        let request = try XCTUnwrap(complete(framing))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(String(data: request.body, encoding: .utf8), body)
    }

    func testBodyArrivingInASecondSegmentIsWaitedFor() throws {
        // Break caught: the server dispatches as soon as it sees the header terminator, so a
        // body split across TCP segments is read as empty. This is the whole reason framing
        // moved out of the receive loop.
        let body = #"{"subject":"hi"}"#
        let head = raw(headers: ["Content-Length: \(body.utf8.count)"], body: "")
        XCTAssertTrue(isIncomplete(HTTPFraming.frame(head)), "a missing body must not dispatch")

        let firstHalf = String(body.prefix(6))
        XCTAssertTrue(
            isIncomplete(HTTPFraming.frame(head + Data(firstHalf.utf8))),
            "a partial body must not dispatch"
        )

        let whole = try XCTUnwrap(complete(HTTPFraming.frame(head + Data(body.utf8))))
        XCTAssertEqual(String(data: whole.body, encoding: .utf8), body)
    }

    func testTrailingBytesBeyondContentLengthAreNotPartOfTheBody() throws {
        // Break caught: a pipelined second request bleeds into the first one's body.
        let body = #"{"a":1}"#
        let framing = HTTPFraming.frame(
            raw(headers: ["Content-Length: \(body.utf8.count)"], body: body + "GET /api/preview HTTP/1.1\r\n")
        )
        let request = try XCTUnwrap(complete(framing))
        XCTAssertEqual(String(data: request.body, encoding: .utf8), body)
    }

    func testOversizeAndMalformedContentLengthsAreRefused() {
        // Break caught: an unbounded or lenient length is accepted. A body budget the server
        // does not enforce is a body budget it does not have.
        XCTAssertEqual(
            refusalStatus(HTTPFraming.frame(raw(headers: ["Content-Length: \(HTTPLimits.maxBodyBytes + 1)"]))),
            413
        )
        for bad in ["abc", "-1", "+5", "0x10", "5 5", "1_000", "", "1e3"] {
            XCTAssertEqual(
                refusalStatus(HTTPFraming.frame(raw(headers: ["Content-Length: \(bad)"]))),
                400,
                "Content-Length '\(bad)' must be refused, not guessed at"
            )
        }
    }

    func testSurroundingWhitespaceOnAHeaderValueIsStandardAndTolerated() throws {
        // Not a loophole: HTTP defines optional whitespace around a field value, so trimming it
        // and then requiring digits is the correct rule — and it is the trimmed value that has
        // to be all digits, which is what the case above pins down.
        let body = "12345"
        let request = try XCTUnwrap(
            complete(HTTPFraming.frame(raw(headers: ["Content-Length:   5  "], body: body)))
        )
        XCTAssertEqual(String(data: request.body, encoding: .utf8), body)
    }

    func testDuplicateFramingHeadersAreRefused() {
        // Break caught: two Content-Length headers collapse to last-one-wins. That is a
        // disagreement about where the request ends — the shape request smuggling is built on.
        XCTAssertEqual(
            refusalStatus(HTTPFraming.frame(raw(headers: ["Content-Length: 2", "Content-Length: 9"], body: "{}"))),
            400
        )
        XCTAssertEqual(
            refusalStatus(HTTPFraming.frame(raw(headers: ["Host: evil.example", "Content-Length: 2"], body: "{}"))),
            400
        )
    }

    func testTransferEncodingIsRefusedRatherThanIgnored() {
        // Break caught: a chunked request is accepted and its framing header quietly ignored.
        XCTAssertEqual(
            refusalStatus(HTTPFraming.frame(raw(headers: ["Transfer-Encoding: chunked"], body: "0\r\n\r\n"))),
            400
        )
    }

    func testReadVerbsMayNotCarryABody() {
        // Break caught: a GET body is silently dropped. A body the server discards is a body the
        // client believed it sent.
        XCTAssertEqual(
            refusalStatus(HTTPFraming.frame(raw("GET", path: "/api/preview", headers: ["Content-Length: 2"], body: "{}"))),
            400
        )
    }

    func testHeaderFloodIsRefusedBeforeATerminatorArrives() {
        // Break caught: a client that never sends the blank line can grow the buffer forever.
        let flood = Data(String(repeating: "x", count: HTTPLimits.maxHeaderBytes + 1).utf8)
        XCTAssertEqual(refusalStatus(HTTPFraming.frame(flood)), 431)
    }

    func testRequestWithoutABodyStillFrames() throws {
        // Break caught: the read path regresses. Every GET on this server has no Content-Length.
        let request = try XCTUnwrap(complete(HTTPFraming.frame(raw("GET", path: "/api/preview"))))
        XCTAssertTrue(request.body.isEmpty)
        XCTAssertEqual(request.path, "/api/preview")
    }
}
