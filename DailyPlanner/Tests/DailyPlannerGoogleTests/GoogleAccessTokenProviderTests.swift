import DailyPlannerDomain
import Foundation
import XCTest
@testable import DailyPlannerGoogle

final class GoogleAccessTokenProviderTests: XCTestCase {
    func testProviderLoadsStoredCredentialsAndPostsExactRefreshForm() async throws {
        // Break caught: the provider skips stored credentials or changes Google's refresh contract.
        let harness = TokenProviderHarness.success()

        let token = try await harness.provider.accessToken()

        XCTAssertEqual(harness.transport.requests.count, 1)
        XCTAssertEqual(
            harness.transport.requests[0].url?.absoluteString,
            "https://oauth2.googleapis.com/token"
        )
        XCTAssertEqual(harness.transport.requests[0].httpMethod, "POST")
        XCTAssertEqual(
            harness.transport.requests[0].value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded"
        )
        XCTAssertEqual(harness.transport.formFields, [
            "client_id": TokenProviderSynthetic.clientIdentifier,
            "client_secret": TokenProviderSynthetic.clientSecret,
            "refresh_token": TokenProviderSynthetic.refreshToken,
            "grant_type": "refresh_token",
        ])
        XCTAssertEqual(String(describing: token), "GoogleAccessToken(redacted)")
    }

    func testProviderAcceptsGoogleUserinfoEmailAliasAsCanonicalEmail() async throws {
        // Break caught: Google's documented userinfo-email alias is rejected as an extra scope.
        let alias = "https://www.googleapis.com/auth/userinfo.email"
        let scopes = ApprovedGoogleScopes.readOnly.map { $0 == "email" ? alias : $0 }
        let harness = TokenProviderHarness.success(scope: scopes.joined(separator: " "))

        let token = try await harness.provider.accessToken()

        XCTAssertEqual(String(describing: token), "GoogleAccessToken(redacted)")
    }

    func testProviderRejectsCanonicalDuplicateWhenEmailAndAliasAreBothGranted() async {
        // Break caught: raw uniqueness plus set equality accepts six scopes that collapse to five.
        let alias = "https://www.googleapis.com/auth/userinfo.email"
        let scopes = ApprovedGoogleScopes.readOnly + [alias]
        let harness = TokenProviderHarness.success(scope: scopes.joined(separator: " "))

        await assertProviderError(.scopeMismatch, harness: harness)
    }

    func testProviderReportsTheCapabilityGoogleActuallyGranted() async throws {
        // Break caught: the capability is only ever read from the settings blob, where it is
        // written once at connect time and can be missing or stale.
        //
        // This is not hypothetical. A connected account was found with gmail.send and
        // calendar.events in its refresh grant and NOTHING in the stored capability — so the app
        // reported "Connected, read-only", hid every in-app send, and offered a re-consent that
        // was not needed. Google states the scopes on every refresh; asking is what makes the
        // answer un-stale.
        let readOnly = TokenProviderHarness.success(
            scope: ApprovedGoogleScopes.readOnly.joined(separator: " ")
        )
        let capability = try await readOnly.provider.grantedCapability()
        XCTAssertEqual(capability, .readOnly)

        let readWrite = TokenProviderHarness.success(
            scope: ApprovedGoogleScopes.readWrite.joined(separator: " ")
        )
        let granted = try await readWrite.provider.grantedCapability()
        XCTAssertEqual(granted, .readWrite)
        XCTAssertTrue(granted.canSendMail)
        XCTAssertTrue(granted.canCreateEvents)
    }

    func testCapabilityAndTokenComeFromOneRefreshAndAgree() async throws {
        // Break caught: the two readings drift apart, so the app holds a token it believes can do
        // something different from what it can. They are one response; they stay one call.
        let harness = TokenProviderHarness.success(
            scope: ApprovedGoogleScopes.readWrite.joined(separator: " ")
        )
        let grant = try await GoogleOAuthTokenService(transport: harness.transport).refreshGrant(
            clientConfiguration: TokenProviderSynthetic.clientConfiguration,
            refreshToken: TokenProviderSynthetic.refreshToken
        )
        XCTAssertEqual(grant.capability, .readWrite)
        XCTAssertEqual(harness.transport.requests.count, 1)
    }

    func testCapabilityProbeIsHeldToTheSameExactScopeCheckAsTheToken() async {
        // Break caught: the probe reads scopes loosely because it "only" reports a capability.
        // A grant carrying anything we did not ask for is refused, on both readings.
        let harness = TokenProviderHarness.success(
            scope: (ApprovedGoogleScopes.readWrite + ["https://www.googleapis.com/auth/drive"])
                .joined(separator: " ")
        )
        do {
            _ = try await harness.provider.grantedCapability()
            XCTFail("an unapproved scope set must not resolve to a capability")
        } catch {
            XCTAssertEqual(error as? GoogleAccessTokenProviderError, .scopeMismatch)
        }
    }

    func testProviderRefreshesOncePerCallWithoutRotatingOrDeletingStoredCredentials() async throws {
        // Break caught: ordinary reads cache access tokens or mutate long-lived credentials.
        let harness = TokenProviderHarness.success(includeRotatedRefreshToken: true)

        _ = try await harness.provider.accessToken()
        _ = try await harness.provider.accessToken()

        XCTAssertEqual(harness.transport.requests.count, 2)
        XCTAssertEqual(harness.credentials.clientLoadCount, 2)
        XCTAssertEqual(harness.credentials.refreshLoadCount, 2)
        XCTAssertEqual(harness.credentials.clientStoreCount, 0)
        XCTAssertEqual(harness.credentials.refreshStoreCount, 0)
        XCTAssertEqual(harness.credentials.deleteAllCount, 0)
    }

    func testProviderRejectsMissingCredentialsWithFiniteRedactedError() async {
        // Break caught: incomplete setup reaches the network or reveals which stored secret is absent.
        for presence in [GoogleCredentialPresence.none, .clientOnly, .inconsistent] {
            let harness = TokenProviderHarness.success(presence: presence)

            await assertProviderError(.notConfigured, harness: harness)
            XCTAssertTrue(harness.transport.requests.isEmpty)
        }
    }

    func testProviderMapsCredentialReadFailureToFiniteRedactedError() async {
        // Break caught: a credential-store implementation error escapes the provider boundary.
        let harness = TokenProviderHarness.success(credentialLoadError: .malformed)

        await assertProviderError(.credentialUnavailable, harness: harness)
    }

    func testProviderRejectsWrongScopeNonBearerAndMalformedToken() async {
        // Break caught: strict token and exact-scope validation is weakened during extraction.
        let cases: [(TokenProviderResponse, GoogleAccessTokenProviderError)] = [
            (.success(scope: ApprovedGoogleScopes.readOnly.dropLast().joined(separator: " ")),
             .scopeMismatch),
            (.success(tokenType: "bearer"), .malformedResponse),
            (.success(accessToken: "secret token with spaces"), .malformedResponse),
        ]

        for (response, expected) in cases {
            let harness = TokenProviderHarness.success(response: response)
            await assertProviderError(expected, harness: harness)
        }
    }

    func testProviderMapsHTTPAndRawTransportFailuresToFiniteRedactedErrors() async {
        // Break caught: status bodies, URLs, or arbitrary transport errors escape to callers.
        let cases: [(TokenProviderResponse, GoogleAccessTokenProviderError)] = [
            (.http(statusCode: 401, body: TokenProviderSynthetic.responseCanary), .rejected),
            (.http(statusCode: 200, body: "[]"), .malformedResponse),
            (.failure(GoogleHTTPTransportError.requestFailed), .offline),
            (.failure(TokenProviderRawError.secret(TokenProviderSynthetic.responseCanary)), .offline),
        ]

        for (response, expected) in cases {
            let harness = TokenProviderHarness.success(response: response)
            await assertProviderError(expected, harness: harness)
        }
    }

    func testProviderPreservesTaskAndTransportCancellationAsFiniteCancelledError() async {
        // Break caught: cancellation is collapsed into offline at the reusable provider boundary.
        for failure in [CancellationError(), GoogleHTTPTransportError.cancelled] as [any Error] {
            let harness = TokenProviderHarness.success(response: .failure(failure))

            await assertProviderError(.cancelled, harness: harness)
        }
    }

    private func assertProviderError(
        _ expected: GoogleAccessTokenProviderError,
        harness: TokenProviderHarness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await harness.provider.accessToken()
            XCTFail("Invalid token response was accepted", file: file, line: line)
        } catch let error as GoogleAccessTokenProviderError {
            XCTAssertEqual(error, expected, file: file, line: line)
            XCTAssertTrue(GoogleAccessTokenProviderError.allCases.contains(error), file: file, line: line)
            let diagnostic = String(reflecting: error)
            XCTAssertFalse(diagnostic.contains(TokenProviderSynthetic.clientSecret), file: file, line: line)
            XCTAssertFalse(diagnostic.contains(TokenProviderSynthetic.refreshToken), file: file, line: line)
            XCTAssertFalse(diagnostic.contains(TokenProviderSynthetic.accessToken), file: file, line: line)
            XCTAssertFalse(diagnostic.contains(TokenProviderSynthetic.responseCanary), file: file, line: line)
        } catch {
            XCTFail("Raw error escaped the token provider: \(type(of: error))", file: file, line: line)
        }
    }
}

private enum TokenProviderSynthetic {
    static let clientIdentifier = "provider-client.apps.example.test"
    static let clientSecret = "provider-client-secret-canary"
    static let refreshToken = "provider-refresh-token-canary"
    static let rotatedRefreshToken = "rotated-refresh-token-canary"
    static let accessToken = "provider-access-token-canary=="
    static let responseCanary = "provider-response-secret-canary"
    static let clientConfiguration = try! GoogleOAuthClientConfiguration(
        clientIdentifier: clientIdentifier,
        clientSecret: clientSecret
    )
}

private enum TokenProviderRawError: Error {
    case secret(String)
}

private enum TokenProviderResponse {
    case http(statusCode: Int, body: String)
    case failure(any Error)

    static func success(
        accessToken: String = TokenProviderSynthetic.accessToken,
        scope: String = ApprovedGoogleScopes.readOnly.joined(separator: " "),
        tokenType: String = "Bearer",
        includeRotatedRefreshToken: Bool = false
    ) -> TokenProviderResponse {
        var object: [String: Any] = [
            "access_token": accessToken,
            "expires_in": 3_600,
            "scope": scope,
            "token_type": tokenType,
        ]
        if includeRotatedRefreshToken {
            object["refresh_token"] = TokenProviderSynthetic.rotatedRefreshToken
        }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return .http(statusCode: 200, body: String(decoding: data, as: UTF8.self))
    }
}

private final class TokenProviderHarness: @unchecked Sendable {
    let credentials: TokenProviderCredentialStore
    let transport: TokenProviderTransport
    let provider: StoredGoogleAccessTokenProvider

    static func success(
        presence: GoogleCredentialPresence = .complete,
        scope: String = ApprovedGoogleScopes.readOnly.joined(separator: " "),
        includeRotatedRefreshToken: Bool = false,
        credentialLoadError: GoogleOAuthCredentialStoreError? = nil,
        response: TokenProviderResponse? = nil
    ) -> TokenProviderHarness {
        TokenProviderHarness(
            credentials: TokenProviderCredentialStore(
                presence: presence,
                loadError: credentialLoadError
            ),
            transport: TokenProviderTransport(response: response ?? .success(
                scope: scope,
                includeRotatedRefreshToken: includeRotatedRefreshToken
            ))
        )
    }

    init(credentials: TokenProviderCredentialStore, transport: TokenProviderTransport) {
        self.credentials = credentials
        self.transport = transport
        provider = StoredGoogleAccessTokenProvider(
            credentials: credentials,
            tokenService: GoogleOAuthTokenService(transport: transport)
        )
    }
}

private final class TokenProviderCredentialStore: GoogleOAuthCredentialStoring, @unchecked Sendable {
    private struct State {
        var configuration: GoogleOAuthClientConfiguration?
        var refreshToken: String?
        var loadError: GoogleOAuthCredentialStoreError?
        var clientLoadCount = 0
        var refreshLoadCount = 0
        var clientStoreCount = 0
        var refreshStoreCount = 0
        var deleteAllCount = 0
        var deleteGrantCount = 0
    }

    private let lock = NSLock()
    private var state: State

    init(presence: GoogleCredentialPresence, loadError: GoogleOAuthCredentialStoreError?) {
        state = switch presence {
        case .none:
            State(loadError: loadError)
        case .clientOnly:
            State(configuration: TokenProviderSynthetic.clientConfiguration, loadError: loadError)
        case .complete:
            State(
                configuration: TokenProviderSynthetic.clientConfiguration,
                refreshToken: TokenProviderSynthetic.refreshToken,
                loadError: loadError
            )
        case .inconsistent:
            State(refreshToken: TokenProviderSynthetic.refreshToken, loadError: loadError)
        }
    }

    var clientLoadCount: Int { locked { $0.clientLoadCount } }
    var refreshLoadCount: Int { locked { $0.refreshLoadCount } }
    var clientStoreCount: Int { locked { $0.clientStoreCount } }
    var refreshStoreCount: Int { locked { $0.refreshStoreCount } }
    var deleteAllCount: Int { locked { $0.deleteAllCount } }

    func storeClientConfiguration(_ value: GoogleOAuthClientConfiguration) throws {
        locked {
            $0.clientStoreCount += 1
            $0.configuration = value
        }
    }

    func loadClientConfiguration() throws -> GoogleOAuthClientConfiguration? {
        try locked {
            $0.clientLoadCount += 1
            if let error = $0.loadError { throw error }
            return $0.configuration
        }
    }

    func storeRefreshToken(_ value: String) throws {
        locked {
            $0.refreshStoreCount += 1
            $0.refreshToken = value
        }
    }

    func loadRefreshToken() throws -> String? {
        try locked {
            $0.refreshLoadCount += 1
            if let error = $0.loadError { throw error }
            return $0.refreshToken
        }
    }

    func deleteAll() throws {
        locked {
            $0.deleteAllCount += 1
            $0.configuration = nil
            $0.refreshToken = nil
        }
    }

    func deleteGrant() throws {
        locked {
            $0.deleteGrantCount += 1
            $0.refreshToken = nil
        }
    }

    func presence() throws -> GoogleCredentialPresence {
        locked {
            switch ($0.configuration != nil, $0.refreshToken != nil) {
            case (false, false): .none
            case (true, false): .clientOnly
            case (true, true): .complete
            case (false, true): .inconsistent
            }
        }
    }

    @discardableResult
    private func locked<T>(_ body: (inout State) throws -> T) rethrows -> T {
        try lock.withLock { try body(&state) }
    }
}

private final class TokenProviderTransport: GoogleHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [URLRequest] = []
    private let response: TokenProviderResponse

    init(response: TokenProviderResponse) {
        self.response = response
    }

    var requests: [URLRequest] { lock.withLock { recordedRequests } }

    var formFields: [String: String] {
        guard let body = requests.last?.httpBody,
              let text = String(data: body, encoding: .utf8) else { return [:] }
        var components = URLComponents()
        components.percentEncodedQuery = text
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
    }

    func send(_ request: URLRequest) async throws -> GoogleHTTPResponse {
        lock.withLock { recordedRequests.append(request) }
        switch response {
        case .http(let statusCode, let body):
            return GoogleHTTPResponse(statusCode: statusCode, data: Data(body.utf8))
        case .failure(let error):
            throw error
        }
    }
}
