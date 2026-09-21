import Foundation
import Testing
@testable import GoogleOAuthCore

@Suite("Gated live OAuth orchestration", .serialized)
struct GoogleOAuthLiveControllerTests {
    @Test("Controller passes an in-memory callback grant to the read-only runner")
    func passesAuthorizationGrantToRunner() async throws {
        let request = try makeRequest()
        let authorization = StubAuthorizationSession(
            result: .success(OAuthAuthorizationGrant(code: "callback-value", request: request))
        )
        let expected = GoogleReadOnlyProbeResult(
            scopes: ApprovedScopes.readOnly,
            refreshSucceeded: true,
            gmailProfileRead: true,
            calendarListRead: true,
            taskListsRead: true,
            cleanupSucceeded: true
        )
        let runner = StubReadOnlyRunner(result: .success(expected))
        let store = LiveRecordingTokenStore()
        let cache = LiveRecordingCacheCleaner()
        let controller = GoogleOAuthLiveController(
            authorizationSession: authorization,
            readOnlyRunner: runner,
            tokenStore: store,
            cacheCleaner: cache
        )

        let result = try await controller.run(clientID: "unit-test-client", callbackTimeout: 1)

        #expect(result == expected)
        #expect(await runner.runCount == 1)
        #expect(store.deleteCount == 0)
        #expect(cache.clearCount == 0)
    }

    @Test("Pre-grant failure reports exact-item deletion failure without secrets")
    func preGrantCleanupFailureIsSurfaced() async throws {
        let authorization = StubAuthorizationSession(result: .failure(.deniedConsent))
        let runner = StubReadOnlyRunner(
            result: .failure(
                GoogleReadOnlyRunFailure(
                    primary: .invalidResponse,
                    cleanup: GoogleOAuthCleanupStatus(
                        remoteRevocation: .notRequired,
                        keychainDeletion: .succeeded,
                        cacheCleared: true
                    )
                )
            )
        )
        let store = LiveRecordingTokenStore(deleteFails: true)
        let cache = LiveRecordingCacheCleaner()
        let controller = GoogleOAuthLiveController(
            authorizationSession: authorization,
            readOnlyRunner: runner,
            tokenStore: store,
            cacheCleaner: cache
        )

        let failure = try #require(await captureLiveFailure(controller))
        #expect(failure.primary == .deniedConsent)
        #expect(failure.cleanup.remoteRevocation == .notRequired)
        #expect(failure.cleanup.keychainDeletion == .failed)
        #expect(failure.cleanup.cacheCleared)
        #expect(await runner.runCount == 0)
    }

    @Test("Concrete loopback session cancels cleanly when the system-browser opener declines")
    func browserOpenFailureCancelsListener() async {
        let browser = DecliningBrowser()
        let session = LoopbackSystemBrowserAuthorizationSession(browser: browser)

        do {
            _ = try await session.authorize(clientID: "unit-test-client", timeout: 2)
            Issue.record("Expected browser cancellation")
        } catch let error as LoopbackCallbackError {
            #expect(error == .browserCancelled)
        } catch {
            Issue.record("Expected a sanitized loopback callback error")
        }
        #expect(await browser.openCount == 1)
    }

    private func captureLiveFailure(
        _ controller: GoogleOAuthLiveController
    ) async -> GoogleOAuthLiveControllerFailure? {
        do {
            _ = try await controller.run(clientID: "unit-test-client", callbackTimeout: 1)
            Issue.record("Expected a sanitized live-controller failure")
            return nil
        } catch let failure as GoogleOAuthLiveControllerFailure {
            return failure
        } catch {
            Issue.record("Expected GoogleOAuthLiveControllerFailure")
            return nil
        }
    }

    private func makeRequest() throws -> OAuthRequest {
        try OAuthRequest(
            clientID: "unit-test-client",
            redirectPort: 54_321,
            pkce: PKCEPair(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            state: "unit-test-state"
        )
    }
}

private actor StubAuthorizationSession: OAuthAuthorizationSession {
    let result: Result<OAuthAuthorizationGrant, LoopbackCallbackError>

    init(result: Result<OAuthAuthorizationGrant, LoopbackCallbackError>) {
        self.result = result
    }

    func authorize(clientID: String, timeout: TimeInterval) async throws -> OAuthAuthorizationGrant {
        try result.get()
    }

    func cancel() async {}
}

private actor StubReadOnlyRunner: GoogleReadOnlyRunning {
    let result: Result<GoogleReadOnlyProbeResult, GoogleReadOnlyRunFailure>
    private(set) var runCount = 0

    init(result: Result<GoogleReadOnlyProbeResult, GoogleReadOnlyRunFailure>) {
        self.result = result
    }

    func run(authorizationCode: String, request: OAuthRequest) async throws -> GoogleReadOnlyProbeResult {
        runCount += 1
        return try result.get()
    }
}

private final class LiveRecordingTokenStore: RefreshTokenStoring, @unchecked Sendable {
    private let deleteFails: Bool
    private(set) var deleteCount = 0

    init(deleteFails: Bool = false) {
        self.deleteFails = deleteFails
    }

    func store(_ token: String) throws {}
    func load() throws -> String { throw KeychainRefreshTokenError.notFound }

    func delete() throws {
        deleteCount += 1
        if deleteFails { throw KeychainRefreshTokenError.denied }
    }
}

private final class LiveRecordingCacheCleaner: URLCacheClearing, @unchecked Sendable {
    private(set) var clearCount = 0

    func clear() {
        clearCount += 1
    }
}

private actor DecliningBrowser: SystemBrowserOpening {
    private(set) var openCount = 0

    func open(_ url: URL) async -> Bool {
        openCount += 1
        return false
    }
}
