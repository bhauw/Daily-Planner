import Foundation
import XCTest
@testable import DailyPlannerGoogle

final class GoogleHTTPTransportTests: XCTestCase {
    override func tearDown() {
        RedirectingURLProtocolSpy.reset()
        ScriptedURLProtocolSpy.reset()
        super.tearDown()
    }

    func testTransportValidatesBeforeRequestReachesURLSession() async {
        // Break caught: URLSession observes a rejected request before policy validation runs.
        let transport = URLSessionGoogleHTTPTransport(protocolClasses: [ScriptedURLProtocolSpy.self])

        do {
            _ = try await transport.send(request("POST", "https://gmail.googleapis.com/gmail/v1/users/me/messages/send"))
            XCTFail("Expected validation failure")
        } catch {
            XCTAssertEqual(ScriptedURLProtocolSpy.snapshot.requestCount, 0)
        }
    }

    func testTransportReturnsExactSyntheticHTTPStatusAndData() async throws {
        // Break caught: the transport rewrites a status or drops/corrupts the response body.
        ScriptedURLProtocolSpy.configure(.success(
            statusCode: 200,
            data: Data("synthetic-response".utf8),
            headers: [:]
        ))
        let transport = URLSessionGoogleHTTPTransport(protocolClasses: [ScriptedURLProtocolSpy.self])

        let response = try await transport.send(providerGET(
            "https://gmail.googleapis.com/gmail/v1/users/me/messages?q=after%3A1788112800&maxResults=100"
        ))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.data, Data("synthetic-response".utf8))
        XCTAssertEqual(ScriptedURLProtocolSpy.snapshot.requestCount, 1)
    }

    func testTransportRejectsRedirectWithoutSendingSecondRequest() async throws {
        // Break caught: URLSession follows a provider redirect outside the validated original request.
        let transport = URLSessionGoogleHTTPTransport(protocolClasses: [RedirectingURLProtocolSpy.self])

        let response = try await transport.send(providerGET(
            "https://gmail.googleapis.com/gmail/v1/users/me/messages?q=after%3A1788112800&maxResults=100"
        ))

        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(RedirectingURLProtocolSpy.requestCount, 1)
    }

    func testEphemeralSessionDoesNotStoreOrReplayResponseCookies() async throws {
        // Break caught: a Set-Cookie response creates ambient state on a later request.
        ScriptedURLProtocolSpy.configure(.success(
            statusCode: 200,
            data: Data(),
            headers: ["Set-Cookie": "SID=synthetic; Path=/; Secure"]
        ))
        let transport = URLSessionGoogleHTTPTransport(protocolClasses: [ScriptedURLProtocolSpy.self])
        let candidate = providerGET("https://gmail.googleapis.com/gmail/v1/users/me/profile")

        _ = try await transport.send(candidate)
        _ = try await transport.send(candidate)

        let snapshot = ScriptedURLProtocolSpy.snapshot
        XCTAssertEqual(snapshot.requestCount, 2)
        XCTAssertEqual(snapshot.cookieHeaders, [nil, nil])
    }

    func testEphemeralSessionDoesNotReuseCachedResponse() async throws {
        // Break caught: a cacheable first response bypasses URLProtocol on the second send.
        ScriptedURLProtocolSpy.configure(.incrementingCacheableSuccess)
        let transport = URLSessionGoogleHTTPTransport(protocolClasses: [ScriptedURLProtocolSpy.self])
        let candidate = providerGET("https://gmail.googleapis.com/gmail/v1/users/me/profile")

        let first = try await transport.send(candidate)
        let second = try await transport.send(candidate)

        XCTAssertEqual(first.data, Data("response-1".utf8))
        XCTAssertEqual(second.data, Data("response-2".utf8))
        XCTAssertEqual(ScriptedURLProtocolSpy.snapshot.requestCount, 2)
    }

    func testEphemeralSessionDoesNotUseSharedURLCredentials() async {
        // Break caught: URLSession consults ambient credential storage for an authentication challenge.
        let protectionSpace = syntheticProtectionSpace()
        let credential = URLCredential(user: "synthetic-user", password: "synthetic-password", persistence: .forSession)
        URLCredentialStorage.shared.setDefaultCredential(credential, for: protectionSpace)
        defer { URLCredentialStorage.shared.remove(credential, for: protectionSpace) }
        ScriptedURLProtocolSpy.configure(.authenticationChallenge)
        let transport = URLSessionGoogleHTTPTransport(protocolClasses: [ScriptedURLProtocolSpy.self])

        do {
            _ = try await transport.send(providerGET("https://gmail.googleapis.com/gmail/v1/users/me/profile"))
            XCTFail("Expected finite authentication failure")
        } catch {
            let snapshot = ScriptedURLProtocolSpy.snapshot
            XCTAssertEqual(snapshot.requestCount, 1)
            XCTAssertFalse(snapshot.usedCredential)
        }
    }

    func testTransportRejectsNonHTTPResponseWithFiniteSanitizedError() async {
        // Break caught: a non-HTTP URL response crashes, hangs, or leaks request details in its error.
        ScriptedURLProtocolSpy.configure(.nonHTTP)
        let transport = URLSessionGoogleHTTPTransport(protocolClasses: [ScriptedURLProtocolSpy.self])

        do {
            _ = try await transport.send(providerGET("https://gmail.googleapis.com/gmail/v1/users/me/profile"))
            XCTFail("Expected non-HTTP failure")
        } catch {
            let description = String(reflecting: error)
            XCTAssertFalse(description.contains("gmail.googleapis.com"))
            XCTAssertFalse(description.contains("profile"))
            XCTAssertEqual(ScriptedURLProtocolSpy.snapshot.requestCount, 1)
        }
    }

    func testTransportMapsInjectedFailuresToFiniteSanitizedPublicErrors() async {
        // Break caught: URLSession errors expose failing URLs or dynamic user-info to callers.
        let cases: [(ScriptedURLProtocolSpy.Failure, GoogleHTTPTransportError)] = [
            (.dynamic, .requestFailed),
            (.cancelled, .cancelled),
        ]

        for (failure, expectedError) in cases {
            ScriptedURLProtocolSpy.configure(.failure(failure))
            let transport = URLSessionGoogleHTTPTransport(protocolClasses: [ScriptedURLProtocolSpy.self])

            do {
                _ = try await transport.send(providerGET("https://gmail.googleapis.com/gmail/v1/users/me/profile"))
                XCTFail("Expected finite transport failure")
            } catch {
                XCTAssertEqual(error as? GoogleHTTPTransportError, expectedError)
                let description = String(reflecting: error)
                XCTAssertFalse(description.contains("secrets.example.test"))
                XCTAssertFalse(description.contains("dynamic-failure-detail"))
                XCTAssertFalse(description.contains("token="))
            }
        }
    }
}

private final class RedirectingURLProtocolSpy: URLProtocol, @unchecked Sendable {
    private static let state = ProtocolSpyState()

    static var requestCount: Int { state.snapshot.requestCount }

    static func reset() {
        state.reset()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.state.record(request: request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": request.url!.absoluteString]
        )!
        client?.urlProtocol(self, wasRedirectedTo: request, redirectResponse: response)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ScriptedURLProtocolSpy: URLProtocol, @unchecked Sendable {
    enum Failure: Sendable {
        case dynamic
        case cancelled
    }

    enum Scenario: Sendable {
        case success(statusCode: Int, data: Data, headers: [String: String])
        case incrementingCacheableSuccess
        case authenticationChallenge
        case nonHTTP
        case failure(Failure)
    }

    private static let state = ProtocolSpyState()
    private var challengeSender: SyntheticChallengeSender?

    static var snapshot: ProtocolSpySnapshot { state.snapshot }

    static func configure(_ scenario: Scenario) {
        state.configure(scenario)
    }

    static func reset() {
        state.reset()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (scenario, count) = Self.state.record(request: request)
        switch scenario {
        case .success(let statusCode, let data, let headers):
            sendHTTP(statusCode: statusCode, data: data, headers: headers)
        case .incrementingCacheableSuccess:
            sendHTTP(
                statusCode: 200,
                data: Data("response-\(count)".utf8),
                headers: ["Cache-Control": "public, max-age=3600"]
            )
        case .authenticationChallenge:
            let sender = SyntheticChallengeSender(owner: self)
            challengeSender = sender
            let challenge = URLAuthenticationChallenge(
                protectionSpace: syntheticProtectionSpace(),
                proposedCredential: nil,
                previousFailureCount: 0,
                failureResponse: nil,
                error: nil,
                sender: sender
            )
            client?.urlProtocol(self, didReceive: challenge)
        case .nonHTTP:
            let response = URLResponse(
                url: request.url!,
                mimeType: "application/octet-stream",
                expectedContentLength: 0,
                textEncodingName: nil
            )
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(.dynamic):
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: "DynamicTransportError.example.test",
                code: 41,
                userInfo: [
                    NSURLErrorKey: URL(string: "https://secrets.example.test/private?token=dynamic-value")!,
                    NSLocalizedDescriptionKey: "dynamic-failure-detail",
                ]
            ))
        case .failure(.cancelled):
            client?.urlProtocol(self, didFailWithError: URLError(
                .cancelled,
                userInfo: [NSLocalizedDescriptionKey: "dynamic-failure-detail"]
            ))
        }
    }

    override func stopLoading() {}

    fileprivate func completeChallenge(usedCredential: Bool) {
        Self.state.recordCredentialUse(usedCredential)
        client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
    }

    private func sendHTTP(statusCode: Int, data: Data, headers: [String: String]) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private struct ProtocolSpySnapshot: Sendable {
    var requestCount = 0
    var cookieHeaders: [String?] = []
    var usedCredential = false
}

private final class ProtocolSpyState: @unchecked Sendable {
    private let lock = NSLock()
    private var scenario: ScriptedURLProtocolSpy.Scenario = .success(statusCode: 200, data: Data(), headers: [:])
    private var value = ProtocolSpySnapshot()

    var snapshot: ProtocolSpySnapshot {
        lock.withLock { value }
    }

    func configure(_ scenario: ScriptedURLProtocolSpy.Scenario) {
        lock.withLock {
            self.scenario = scenario
            value = ProtocolSpySnapshot()
        }
    }

    func reset() {
        configure(.success(statusCode: 200, data: Data(), headers: [:]))
    }

    @discardableResult
    func record(request: URLRequest) -> (ScriptedURLProtocolSpy.Scenario, Int) {
        lock.withLock {
            value.requestCount += 1
            value.cookieHeaders.append(request.value(forHTTPHeaderField: "Cookie"))
            return (scenario, value.requestCount)
        }
    }

    func recordCredentialUse(_ usedCredential: Bool) {
        lock.withLock {
            value.usedCredential = value.usedCredential || usedCredential
        }
    }
}

private final class SyntheticChallengeSender: NSObject, URLAuthenticationChallengeSender, @unchecked Sendable {
    private weak var owner: ScriptedURLProtocolSpy?

    init(owner: ScriptedURLProtocolSpy) {
        self.owner = owner
    }

    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {
        owner?.completeChallenge(usedCredential: true)
    }

    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {
        owner?.completeChallenge(usedCredential: false)
    }

    func cancel(_ challenge: URLAuthenticationChallenge) {
        owner?.completeChallenge(usedCredential: false)
    }

    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {
        owner?.completeChallenge(usedCredential: false)
    }

    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {
        owner?.completeChallenge(usedCredential: false)
    }
}

private func syntheticProtectionSpace() -> URLProtectionSpace {
    URLProtectionSpace(
        host: "credentials.example.test",
        port: 443,
        protocol: "https",
        realm: "Synthetic",
        authenticationMethod: NSURLAuthenticationMethodHTTPBasic
    )
}
