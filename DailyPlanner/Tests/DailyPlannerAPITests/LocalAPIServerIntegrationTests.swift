import Foundation
import XCTest
@testable import DailyPlannerAPI

/// End-to-end tests over a real loopback socket. Each starts the server, reads the ephemeral
/// port, and drives it with URLSession — the same surface the WKWebView uses.
final class LocalAPIServerIntegrationTests: XCTestCase {
    private var server: LocalAPIServer!
    private var port: UInt16!
    private var base: URL!

    override func setUp() async throws {
        try await super.setUp()
        server = LocalAPIServer(referenceDate: Date(timeIntervalSince1970: 1_800_000_000))
        port = try await server.start()
        base = URL(string: "http://127.0.0.1:\(port!)")!
    }

    override func tearDown() async throws {
        server.stop()
        server = nil
        try await super.tearDown()
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }

    private func statusAndBody(
        _ path: String,
        method: String = "GET",
        token: String? = nil,
        origin: String? = nil
    ) async throws -> (Int, Data) {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        let (data, response) = try await session().data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }

    func testBoundOnLoopbackPort() {
        XCTAssertGreaterThan(port, 1024)
        XCTAssertEqual(server.port, port)
    }

    func testPreviewWithoutTokenIs401() async throws {
        let (status, _) = try await statusAndBody("/api/preview")
        XCTAssertEqual(status, 401)
    }

    func testPreviewWithWrongTokenIs401() async throws {
        let (status, _) = try await statusAndBody("/api/preview", token: "wrong-token")
        XCTAssertEqual(status, 401)
    }

    func testPreviewWithValidTokenReturnsContractJSON() async throws {
        let (status, data) = try await statusAndBody("/api/preview", token: server.token)
        XCTAssertEqual(status, 200)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        XCTAssertNotNil(json?["day"] as? String)
        XCTAssertEqual((json?["queue"] as? [[String: Any]])?.count, 2)
    }

    func testHealthWithValidTokenReturnsReadOnly() async throws {
        let (status, data) = try await statusAndBody("/api/health", token: server.token)
        XCTAssertEqual(status, 200)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        XCTAssertEqual(json?["mode"] as? String, "read-only")
    }

    func testStaticRootServesWithoutToken() async throws {
        let (status, data) = try await statusAndBody("/")
        XCTAssertEqual(status, 200)
        let html = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(html.contains("Read-only · no external writes"))
    }

    func testForeignOriginIs401() async throws {
        let (status, _) = try await statusAndBody(
            "/api/preview", token: server.token, origin: "https://evil.example.com"
        )
        XCTAssertEqual(status, 401)
    }

    func testWriteVerbsNeverSucceed() async throws {
        // No route responds to a write verb. Each is refused (405) — there is no mutation path.
        for verb in ["POST", "PUT", "PATCH", "DELETE"] {
            let (status, _) = try await statusAndBody("/api/preview", method: verb, token: server.token)
            XCTAssertNotEqual(status, 200, "\(verb) must not succeed")
            XCTAssertEqual(status, 405, "\(verb) must be rejected as method-not-allowed")
        }
    }

    func testSpoofedNonLoopbackHostIs401() async throws {
        // The transport binds loopback-only; this asserts the app-layer Host check as well.
        var request = URLRequest(url: base.appendingPathComponent("/api/preview"))
        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        request.setValue("192.168.1.50:\(port!)", forHTTPHeaderField: "Host")
        let (_, response) = try await session().data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
    }
}
