import Foundation
import Testing
@testable import GoogleOAuthCore

@Suite("Read-only Google canary", .serialized)
struct GoogleReadOnlyClientTests {
    @Test("Success discards the first credential, refreshes, performs only three GETs, and cleans up")
    func refreshesBeforeOnlyApprovedReads() async throws {
        let transport = StubHTTPTransport(steps: [
            .response(200, tokenJSON(access: "first-credential", refresh: "temporary-credential", scopes: ApprovedScopes.readOnly)),
            .response(200, tokenJSON(access: "refreshed-credential")),
            .response(200, Data()),
            .response(200, Data()),
            .response(200, Data()),
            .response(200, Data()),
        ])
        let store = RecordingRefreshTokenStore()
        let cache = RecordingCacheCleaner()
        let client = GoogleReadOnlyClient(transport: transport, tokenStore: store, cacheCleaner: cache)
        let request = try makeRequest()

        let result = try await client.run(authorizationCode: "callback-value", request: request)
        let requests = await transport.recordedRequests()
        let apiRequests = requests.filter { request in
            ["gmail.googleapis.com", "www.googleapis.com", "tasks.googleapis.com"].contains(request.url?.host)
        }

        #expect(result == GoogleReadOnlyProbeResult(
            scopes: ApprovedScopes.readOnly,
            refreshSucceeded: true,
            gmailProfileRead: true,
            calendarListRead: true,
            taskListsRead: true,
            cleanupSucceeded: true
        ))
        #expect(apiRequests.map(\.httpMethod) == ["GET", "GET", "GET"])
        #expect(apiRequests.map { $0.url?.path } == [
            "/gmail/v1/users/me/profile",
            "/calendar/v3/users/me/calendarList",
            "/tasks/v1/users/@me/lists",
        ])
        #expect(apiRequests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-credential"
        })
        #expect(store.storedValues == ["temporary-credential"])
        #expect(store.loadCount == 1)
        #expect(store.deleteCount == 1)
        #expect(cache.clearCount == 1)
    }

    @Test("Token endpoint failure is typed and cleanup still runs")
    func tokenEndpointFailureCleansUp() async throws {
        let transport = StubHTTPTransport(steps: [.response(500, Data())])
        let store = RecordingRefreshTokenStore()
        let cache = RecordingCacheCleaner()
        let client = GoogleReadOnlyClient(transport: transport, tokenStore: store, cacheCleaner: cache)

        let failure = try #require(await captureFailure(client))
        #expect(failure.primary == .tokenExchangeFailed)
        #expect(failure.cleanup.remoteRevocation == .notRequired)
        #expect(failure.cleanup.keychainDeletion == .succeeded)
        #expect(store.deleteCount == 1)
        #expect(cache.clearCount == 1)
    }

    @Test("Refresh failure is typed and removes the temporary Keychain item")
    func refreshFailureCleansUp() async throws {
        let transport = StubHTTPTransport(steps: [
            .response(200, tokenJSON(access: "first-credential", refresh: "temporary-credential", scopes: ApprovedScopes.readOnly)),
            .response(503, Data()),
            .response(200, Data()),
        ])
        let store = RecordingRefreshTokenStore()
        let cache = RecordingCacheCleaner()
        let client = GoogleReadOnlyClient(transport: transport, tokenStore: store, cacheCleaner: cache)

        let failure = try #require(await captureFailure(client))
        #expect(failure.primary == .refreshFailed)
        #expect(failure.cleanup.remoteRevocation == .succeeded)
        #expect(failure.cleanup.keychainDeletion == .succeeded)
        #expect(store.deleteCount == 1)
        #expect(cache.clearCount == 1)
    }

    @Test("A grant missing one approved scope is rejected")
    func missingScopeIsRejected() async throws {
        let transport = StubHTTPTransport(steps: [
            .response(
                200,
                tokenJSON(
                    access: "first-credential",
                    refresh: "temporary-credential",
                    scopes: Array(ApprovedScopes.readOnly.dropLast())
                )
            ),
            .response(200, Data()),
        ])
        let store = RecordingRefreshTokenStore()
        let cache = RecordingCacheCleaner()
        let client = GoogleReadOnlyClient(transport: transport, tokenStore: store, cacheCleaner: cache)

        let failure = try #require(await captureFailure(client))
        #expect(failure.primary == .scopeMismatch)
        #expect(failure.cleanup.remoteRevocation == .succeeded)
        #expect(store.storedValues.isEmpty)
        #expect(store.deleteCount == 1)
        #expect(cache.clearCount == 1)
    }

    @Test("Cancellation during a read is sanitized and cleans up")
    func interruptionCleansUp() async throws {
        let transport = StubHTTPTransport(steps: [
            .response(200, tokenJSON(access: "first-credential", refresh: "temporary-credential", scopes: ApprovedScopes.readOnly)),
            .response(200, tokenJSON(access: "refreshed-credential")),
            .cancel,
            .response(200, Data()),
        ])
        let store = RecordingRefreshTokenStore()
        let cache = RecordingCacheCleaner()
        let client = GoogleReadOnlyClient(transport: transport, tokenStore: store, cacheCleaner: cache)

        let failure = try #require(await captureFailure(client))
        #expect(failure.primary == .interrupted)
        #expect(failure.cleanup.remoteRevocation == .succeeded)
        #expect(store.deleteCount == 1)
        #expect(cache.clearCount == 1)
    }

    @Test("Missing refresh credential revokes with the first access credential")
    func missingRefreshCredentialRevokesGrant() async throws {
        let transport = StubHTTPTransport(steps: [
            .response(200, tokenJSON(access: "first-credential", scopes: ApprovedScopes.readOnly)),
            .response(200, Data()),
        ])
        let client = GoogleReadOnlyClient(
            transport: transport,
            tokenStore: RecordingRefreshTokenStore(),
            cacheCleaner: RecordingCacheCleaner()
        )

        let failure = try #require(await captureFailure(client))
        #expect(failure.primary == .tokenExchangeFailed)
        #expect(failure.cleanup.remoteRevocation == .succeeded)
    }

    @Test("Empty refresh credential falls back to the first access credential for revocation")
    func emptyRefreshCredentialUsesAccessCredentialForRevocation() async throws {
        let transport = StubHTTPTransport(steps: [
            .response(200, tokenJSON(access: "first-credential", refresh: "", scopes: ApprovedScopes.readOnly)),
            .response(200, Data()),
        ])
        let client = GoogleReadOnlyClient(
            transport: transport,
            tokenStore: RecordingRefreshTokenStore(),
            cacheCleaner: RecordingCacheCleaner()
        )

        let failure = try #require(await captureFailure(client))
        let revokeRequest = try #require(await transport.recordedRequests().last)
        let revokeBody = try #require(revokeRequest.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(failure.primary == .tokenExchangeFailed)
        #expect(revokeBody == "token=first-credential")
    }

    @Test("Keychain store and load failures both revoke the remote grant", arguments: [
        StoreFailurePoint.store,
        StoreFailurePoint.load,
    ])
    func keychainFailuresRevokeGrant(point: StoreFailurePoint) async throws {
        let transport = StubHTTPTransport(steps: [
            .response(200, tokenJSON(access: "first-credential", refresh: "temporary-credential", scopes: ApprovedScopes.readOnly)),
            .response(200, Data()),
        ])
        let store = RecordingRefreshTokenStore()
        store.failurePoint = point
        let client = GoogleReadOnlyClient(
            transport: transport,
            tokenStore: store,
            cacheCleaner: RecordingCacheCleaner()
        )

        let failure = try #require(await captureFailure(client))
        #expect(failure.primary == .keychainFailure)
        #expect(failure.cleanup.remoteRevocation == .succeeded)
        #expect(failure.cleanup.keychainDeletion == .succeeded)
    }

    @Test("Each API failure revokes the remote grant", arguments: [
        APIFailurePoint.gmail,
        APIFailurePoint.calendar,
        APIFailurePoint.tasks,
    ])
    func apiFailuresRevokeGrant(point: APIFailurePoint) async throws {
        var steps: [StubStep] = [
            .response(200, tokenJSON(access: "first-credential", refresh: "temporary-credential", scopes: ApprovedScopes.readOnly)),
            .response(200, tokenJSON(access: "refreshed-credential")),
        ]
        let successfulReadsBeforeFailure: Int
        let expectedPrimary: GoogleReadOnlyClientError
        switch point {
        case .gmail:
            successfulReadsBeforeFailure = 0
            expectedPrimary = .gmailReadFailed
        case .calendar:
            successfulReadsBeforeFailure = 1
            expectedPrimary = .calendarReadFailed
        case .tasks:
            successfulReadsBeforeFailure = 2
            expectedPrimary = .tasksReadFailed
        }
        steps += Array(repeating: .response(200, Data()), count: successfulReadsBeforeFailure)
        steps += [.response(500, Data()), .response(200, Data())]
        let transport = StubHTTPTransport(steps: steps)
        let client = GoogleReadOnlyClient(
            transport: transport,
            tokenStore: RecordingRefreshTokenStore(),
            cacheCleaner: RecordingCacheCleaner()
        )

        let failure = try #require(await captureFailure(client))
        #expect(failure.primary == expectedPrimary)
        #expect(failure.cleanup.remoteRevocation == .succeeded)
    }

    @Test("Revocation failure is reported without replacing the primary failure")
    func revocationFailurePreservesPrimaryFailure() async throws {
        let transport = StubHTTPTransport(steps: [
            .response(200, tokenJSON(access: "first-credential", refresh: "temporary-credential", scopes: ApprovedScopes.readOnly)),
            .response(503, Data()),
            .response(500, Data()),
        ])
        let client = GoogleReadOnlyClient(
            transport: transport,
            tokenStore: RecordingRefreshTokenStore(),
            cacheCleaner: RecordingCacheCleaner()
        )

        let failure = try #require(await captureFailure(client))
        #expect(failure.primary == .refreshFailed)
        #expect(failure.cleanup.remoteRevocation == .failed)
    }

    @Test("Keychain deletion failure is surfaced on throwing paths")
    func deleteFailureIsSurfacedWithoutReplacingPrimary() async throws {
        let transport = StubHTTPTransport(steps: [
            .response(200, tokenJSON(access: "first-credential", refresh: "temporary-credential", scopes: ApprovedScopes.readOnly)),
            .response(503, Data()),
            .response(200, Data()),
        ])
        let store = RecordingRefreshTokenStore()
        store.failurePoint = .delete
        let client = GoogleReadOnlyClient(
            transport: transport,
            tokenStore: store,
            cacheCleaner: RecordingCacheCleaner()
        )

        let failure = try #require(await captureFailure(client))
        #expect(failure.primary == .refreshFailed)
        #expect(failure.cleanup.remoteRevocation == .succeeded)
        #expect(failure.cleanup.keychainDeletion == .failed)
        #expect(!failure.cleanup.succeeded)
    }

    @Test("Keychain deletion failure prevents a success cleanup claim")
    func deleteFailureMarksSuccessResultUnclean() async throws {
        let transport = StubHTTPTransport(steps: [
            .response(200, tokenJSON(access: "first-credential", refresh: "temporary-credential", scopes: ApprovedScopes.readOnly)),
            .response(200, tokenJSON(access: "refreshed-credential")),
            .response(200, Data()),
            .response(200, Data()),
            .response(200, Data()),
            .response(200, Data()),
        ])
        let store = RecordingRefreshTokenStore()
        store.failurePoint = .delete
        let client = GoogleReadOnlyClient(
            transport: transport,
            tokenStore: store,
            cacheCleaner: RecordingCacheCleaner()
        )

        let result = try await client.run(authorizationCode: "callback-value", request: makeRequest())
        #expect(!result.cleanupSucceeded)
    }

    private func captureFailure(_ client: GoogleReadOnlyClient) async -> GoogleReadOnlyRunFailure? {
        do {
            _ = try await client.run(authorizationCode: "callback-value", request: makeRequest())
            Issue.record("Expected a sanitized run failure")
            return nil
        } catch let failure as GoogleReadOnlyRunFailure {
            return failure
        } catch {
            Issue.record("Expected GoogleReadOnlyRunFailure, got another error type")
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

enum StoreFailurePoint: Equatable, Sendable {
    case store
    case load
    case delete
}

enum APIFailurePoint: Sendable {
    case gmail
    case calendar
    case tasks
}

private enum StubStep: Sendable {
    case response(Int, Data)
    case cancel
}

private actor StubHTTPTransport: OAuthHTTPTransport {
    private var steps: [StubStep]
    private var requests: [URLRequest] = []

    init(steps: [StubStep]) {
        self.steps = steps
    }

    func send(_ request: URLRequest) async throws -> OAuthHTTPResponse {
        requests.append(request)
        guard !steps.isEmpty else { throw StubTransportError.noResponse }
        switch steps.removeFirst() {
        case let .response(status, data):
            return OAuthHTTPResponse(statusCode: status, data: data)
        case .cancel:
            throw CancellationError()
        }
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private enum StubTransportError: Error {
    case noResponse
}

private final class RecordingRefreshTokenStore: RefreshTokenStoring, @unchecked Sendable {
    private(set) var storedValues: [String] = []
    private(set) var loadCount = 0
    private(set) var deleteCount = 0
    var failurePoint: StoreFailurePoint?

    func store(_ token: String) throws {
        if failurePoint == .store { throw KeychainRefreshTokenError.denied }
        storedValues.append(token)
    }

    func load() throws -> String {
        loadCount += 1
        if failurePoint == .load { throw KeychainRefreshTokenError.denied }
        guard let value = storedValues.last else { throw KeychainRefreshTokenError.notFound }
        return value
    }

    func delete() throws {
        deleteCount += 1
        if failurePoint == .delete { throw KeychainRefreshTokenError.denied }
    }
}

private final class RecordingCacheCleaner: URLCacheClearing, @unchecked Sendable {
    private(set) var clearCount = 0

    func clear() {
        clearCount += 1
    }
}

private func tokenJSON(access: String, refresh: String? = nil, scopes: [String]? = nil) -> Data {
    var object: [String: Any] = ["access_token": access, "token_type": "Bearer"]
    if let refresh { object["refresh_token"] = refresh }
    if let scopes { object["scope"] = scopes.joined(separator: " ") }
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
