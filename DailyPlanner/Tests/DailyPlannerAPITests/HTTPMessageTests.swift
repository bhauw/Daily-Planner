import Foundation
import XCTest
@testable import DailyPlannerAPI

final class HTTPMessageTests: XCTestCase {
    func testParsesRequestLineAndHeaders() {
        // Written as an explicit byte sequence so the header block ends with a full CRLFCRLF
        // terminator — the exact framing a real client sends and the parser requires.
        let raw = Data("GET /api/preview?dev=1 HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nAuthorization: Bearer secret\r\n\r\n".utf8)
        let request = HTTPRequest.parse(raw)
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.path, "/api/preview")
        XCTAssertEqual(request?.query, "dev=1")
        XCTAssertEqual(request?.header("host"), "127.0.0.1:8080")
        // Header lookup is case-insensitive.
        XCTAssertEqual(request?.header("AUTHORIZATION"), "Bearer secret")
    }

    func testReturnsNilWhenHeaderBlockIncomplete() {
        let raw = Data("GET / HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n".utf8)
        XCTAssertNil(HTTPRequest.parse(raw))
    }

    func testResponseSerializationIncludesLengthAndClose() {
        let response = HTTPResponse.json(200, "OK", Data("{\"ok\":true}".utf8))
        let text = String(data: response.serialize(includeBody: true), encoding: .utf8) ?? ""
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 11\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.contains("X-Content-Type-Options: nosniff\r\n"))
        XCTAssertTrue(text.hasSuffix("{\"ok\":true}"))
    }

    func testHeadResponseOmitsBodyButKeepsLength() {
        let response = HTTPResponse.json(200, "OK", Data("{\"ok\":true}".utf8))
        let text = String(data: response.serialize(includeBody: false), encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("Content-Length: 11\r\n"))
        XCTAssertFalse(text.contains("{\"ok\":true}"))
    }

    func testErrorBodyIsFiniteShape() {
        let response = HTTPResponse.error(401, "Unauthorized", .unauthorized, "Authentication required.")
        let body = String(data: response.body, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"code\":\"unauthorized\""))
        XCTAssertTrue(body.contains("\"error\""))
    }
}
