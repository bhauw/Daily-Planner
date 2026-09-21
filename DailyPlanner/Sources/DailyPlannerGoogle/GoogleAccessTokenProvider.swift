import DailyPlannerDomain
import Foundation

public enum GoogleAccessTokenProviderError: Error, Equatable, CaseIterable, Sendable {
    case notConfigured, credentialUnavailable, cancelled, offline, rejected, scopeMismatch
    case malformedResponse
}

/// A refreshed access token together with what it is actually permitted to do.
public struct GoogleRefreshedGrant: Sendable {
    public let accessToken: GoogleAccessToken
    public let capability: GoogleGrantedCapability

    public init(accessToken: GoogleAccessToken, capability: GoogleGrantedCapability) {
        self.accessToken = accessToken
        self.capability = capability
    }
}

public struct GoogleOAuthTokenService: Sendable {
    struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int
        let refreshToken: String?
        let scope: String
        let tokenType: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case scope
            case tokenType = "token_type"
        }
    }

    private let transport: any GoogleHTTPTransport

    public init(transport: any GoogleHTTPTransport) {
        self.transport = transport
    }

    public func refresh(
        clientConfiguration: GoogleOAuthClientConfiguration,
        refreshToken: String
    ) async throws -> GoogleAccessToken {
        try await refreshGrant(
            clientConfiguration: clientConfiguration, refreshToken: refreshToken
        ).accessToken
    }

    /// The same refresh, returning the capability alongside the token.
    ///
    /// Google states the granted scopes on every refresh, so what the credentials can actually
    /// do is knowable at any moment — it does not have to be remembered from the day the account
    /// was connected. That distinction matters: the capability was recorded once, at connect,
    /// and a settings blob written before that field existed (or a `replace` that did not land)
    /// left the app permanently telling the user "read-only" while holding a token that could
    /// send. This is the reading that cannot go stale.
    public func refreshGrant(
        clientConfiguration: GoogleOAuthClientConfiguration,
        refreshToken: String
    ) async throws -> GoogleRefreshedGrant {
        let request = Self.refreshRequest(
            clientConfiguration: clientConfiguration,
            refreshToken: refreshToken
        )
        let response: GoogleHTTPResponse
        do {
            response = try await transport.send(request)
        } catch is CancellationError {
            throw GoogleAccessTokenProviderError.cancelled
        } catch let error as GoogleHTTPTransportError where error == .cancelled {
            throw GoogleAccessTokenProviderError.cancelled
        } catch {
            throw GoogleAccessTokenProviderError.offline
        }
        guard response.statusCode == 200 else {
            throw GoogleAccessTokenProviderError.rejected
        }
        let decoded = try Self.decodeTokenResponse(response.data)
        return GoogleRefreshedGrant(
            accessToken: try Self.validatedAccessToken(from: decoded),
            // Exact-match against the approved sets, same as the token validation above: a grant
            // carrying anything we did not ask for is refused rather than read loosely.
            capability: try Self.validateApprovedScopes(decoded.scope)
        )
    }

    static func decodeTokenResponse(_ data: Data) throws -> TokenResponse {
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw GoogleAccessTokenProviderError.malformedResponse
        }
    }

    static func validatedAccessToken(from response: TokenResponse) throws -> GoogleAccessToken {
        try validateApprovedScopes(response.scope)
        guard response.tokenType == "Bearer", response.expiresIn > 0 else {
            throw GoogleAccessTokenProviderError.malformedResponse
        }
        do {
            return try GoogleAccessToken(validating: response.accessToken)
        } catch {
            throw GoogleAccessTokenProviderError.malformedResponse
        }
    }

    @discardableResult
    static func validateApprovedScopes(_ scope: String) throws -> GoogleGrantedCapability {
        let granted = scope.split(separator: " ").map(String.init)
        let canonicalGranted = granted.map {
            $0 == emailScopeAlias ? "email" : $0
        }
        // Duplicates are still a mismatch: a grant we cannot read exactly is one we do not trust.
        guard Set(canonicalGranted).count == canonicalGranted.count,
              let capability = GoogleGrantedCapability.matching(canonicalGranted) else {
            throw GoogleAccessTokenProviderError.scopeMismatch
        }
        return capability
    }

    private static func refreshRequest(
        clientConfiguration: GoogleOAuthClientConfiguration,
        refreshToken: String
    ) -> URLRequest {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientConfiguration.clientIdentifier),
            URLQueryItem(name: "client_secret", value: clientConfiguration.clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        return request
    }

    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let emailScopeAlias = "https://www.googleapis.com/auth/userinfo.email"
}

public struct StoredGoogleAccessTokenProvider: GoogleAccessTokenProviding, Sendable {
    private let credentials: any GoogleOAuthCredentialStoring
    private let tokenService: GoogleOAuthTokenService

    public init(
        credentials: any GoogleOAuthCredentialStoring,
        tokenService: GoogleOAuthTokenService
    ) {
        self.credentials = credentials
        self.tokenService = tokenService
    }

    public func accessToken() async throws -> GoogleAccessToken {
        try await refreshedGrant().accessToken
    }

    /// What the stored credentials actually permit, asked of Google rather than remembered.
    ///
    /// One network round trip. Worth it: the alternative is a local record that can disagree
    /// with the token — and when it does, the app either offers to send with a grant that
    /// cannot, or refuses to with one that can. The second is what shipped.
    public func grantedCapability() async throws -> GoogleGrantedCapability {
        try await refreshedGrant().capability
    }

    private func refreshedGrant() async throws -> GoogleRefreshedGrant {
        let configuration: GoogleOAuthClientConfiguration?
        let refreshToken: String?
        do {
            configuration = try credentials.loadClientConfiguration()
            refreshToken = try credentials.loadRefreshToken()
        } catch {
            throw GoogleAccessTokenProviderError.credentialUnavailable
        }
        guard let configuration, let refreshToken else {
            throw GoogleAccessTokenProviderError.notConfigured
        }
        return try await tokenService.refreshGrant(
            clientConfiguration: configuration,
            refreshToken: refreshToken
        )
    }
}

extension GoogleAccessTokenProviderError: PlannerWriteFailure {
    /// A write that cannot get a token has not happened. `rejected` and `scopeMismatch` are the
    /// two the user can act on — the grant is gone or is not the grant we asked for — and they
    /// are the ones reported as a refusal so the app can say "reconnect" rather than "try later".
    public var writeOutcome: PlannerWriteOutcome {
        switch self {
        case .cancelled: return .cancelled
        case .rejected, .scopeMismatch, .notConfigured, .credentialUnavailable: return .refused
        case .offline, .malformedResponse: return .unavailable
        }
    }
}
