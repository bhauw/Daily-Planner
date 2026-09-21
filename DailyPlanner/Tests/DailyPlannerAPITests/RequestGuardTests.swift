import Foundation
import XCTest
@testable import DailyPlannerAPI

final class RequestGuardTests: XCTestCase {
    private let token = "test-token-abc123"
    private let port: UInt16 = 51_234

    private func guardCheck(extraOrigins: Set<String> = []) -> RequestGuard {
        RequestGuard(token: token, port: port, extraAllowedOrigins: extraOrigins)
    }

    private func request(
        method: String = "GET",
        path: String = "/api/preview",
        headers: [String: String]
    ) -> HTTPRequest {
        var lowered: [String: String] = [:]
        for (key, value) in headers { lowered[key.lowercased()] = value }
        return HTTPRequest(method: method, path: path, query: nil, headers: lowered)
    }

    private func loopbackHeaders(withToken: Bool = true) -> [String: String] {
        var headers = ["host": "127.0.0.1:\(port)"]
        if withToken { headers["authorization"] = "Bearer \(token)" }
        return headers
    }

    func testValidApiRequestIsAllowed() {
        let rejection = guardCheck().reject(request(headers: loopbackHeaders()))
        XCTAssertNil(rejection)
    }

    func testMissingTokenIsRejected() {
        let rejection = guardCheck().reject(request(headers: loopbackHeaders(withToken: false)))
        XCTAssertEqual(rejection?.status, 401)
    }

    func testWrongTokenIsRejected() {
        var headers = loopbackHeaders()
        headers["authorization"] = "Bearer not-the-real-token"
        let rejection = guardCheck().reject(request(headers: headers))
        XCTAssertEqual(rejection?.status, 401)
    }

    func testWrongTokenAndMissingTokenProduceIdenticalResponse() {
        // Behaviorally indistinguishable: same status and same finite body, so a caller cannot
        // tell "no token" from "wrong token". (The compare itself is constant-time by
        // construction — see HTTPSecurityTests.)
        var wrongHeaders = loopbackHeaders()
        wrongHeaders["authorization"] = "Bearer wrong"
        let wrong = guardCheck().reject(request(headers: wrongHeaders))
        let missing = guardCheck().reject(request(headers: loopbackHeaders(withToken: false)))
        XCTAssertEqual(wrong?.status, missing?.status)
        XCTAssertEqual(wrong?.body, missing?.body)
    }

    func testNonGetMethodIsRejected() {
        // The write verbs never reach a handler; they are refused at the gate as 405.
        for verb in ["POST", "PUT", "PATCH", "DELETE", "OPTIONS"] {
            let rejection = guardCheck().reject(request(method: verb, headers: loopbackHeaders()))
            XCTAssertEqual(rejection?.status, 405, "\(verb) should be rejected")
        }
    }

    func testHeadMethodIsAllowed() {
        let rejection = guardCheck().reject(request(method: "HEAD", headers: loopbackHeaders()))
        XCTAssertNil(rejection)
    }

    func testNonLoopbackHostIsRejected() {
        // App-layer defense against a request arriving with a non-loopback Host (e.g. via DNS
        // rebinding). Complements the transport-layer loopback-only bind.
        var headers = loopbackHeaders()
        headers["host"] = "192.168.1.50:\(port)"
        let rejection = guardCheck().reject(request(headers: headers))
        XCTAssertEqual(rejection?.status, 401)
    }

    func testMissingHostIsRejected() {
        var headers = loopbackHeaders()
        headers.removeValue(forKey: "host")
        let rejection = guardCheck().reject(request(headers: headers))
        XCTAssertEqual(rejection?.status, 401)
    }

    func testForeignOriginIsRejected() {
        var headers = loopbackHeaders()
        headers["origin"] = "https://evil.example.com"
        let rejection = guardCheck().reject(request(headers: headers))
        XCTAssertEqual(rejection?.status, 401)
    }

    func testLoopbackOriginIsAllowed() {
        var headers = loopbackHeaders()
        headers["origin"] = "http://127.0.0.1:\(port)"
        XCTAssertNil(guardCheck().reject(request(headers: headers)))
    }

    func testExtraDevOriginIsAllowedOnlyWhenConfigured() {
        var headers = loopbackHeaders()
        headers["origin"] = "http://localhost:5173"
        XCTAssertEqual(guardCheck().reject(request(headers: headers))?.status, 401)
        XCTAssertNil(guardCheck(extraOrigins: ["http://localhost:5173"]).reject(request(headers: headers)))
    }

    func testStaticPathDoesNotRequireToken() {
        let headers = ["host": "127.0.0.1:\(port)"]
        XCTAssertNil(guardCheck().reject(request(method: "GET", path: "/", headers: headers)))
        XCTAssertNil(guardCheck().reject(request(method: "GET", path: "/assets/app.js", headers: headers)))
    }
}
