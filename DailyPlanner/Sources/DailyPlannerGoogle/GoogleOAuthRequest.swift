import DailyPlannerDomain
import Foundation

public struct GoogleOAuthRequest: Sendable {
    public let authorizationURL: URL
    public let redirectURL: URL
    public let scopes: [String]
    public let pkce: PKCEPair
    public let state: String

    public init(
        clientIdentifier: String,
        redirectPort: Int,
        pkce: PKCEPair,
        state: String,
        scopes: [String] = ApprovedGoogleScopes.readOnly
    ) throws {
        guard !clientIdentifier.isEmpty, !containsControlCharacter(clientIdentifier) else {
            throw GoogleOAuthRequestError.invalidClientIdentifier
        }
        guard (1...65_535).contains(redirectPort) else {
            throw GoogleOAuthRequestError.invalidRedirectPort
        }
        // Either approved set may be requested: read-only for a first connection that only
        // reads, read-write when the user has asked to send and schedule. Anything else is
        // refused, so a stray scope cannot be slipped into the consent screen.
        guard ApprovedGoogleScopes.approvedSets.contains(scopes) else {
            throw GoogleOAuthRequestError.unapprovedScopes
        }
        guard !pkce.verifier.isEmpty, !pkce.challenge.isEmpty, !state.isEmpty,
              !containsControlCharacter(pkce.verifier), !containsControlCharacter(pkce.challenge),
              !containsControlCharacter(state) else {
            throw GoogleOAuthRequestError.invalidOAuthValue
        }

        let redirectURL = try Self.redirectURL(port: redirectPort)
        var authorizationComponents = URLComponents()
        authorizationComponents.scheme = "https"
        authorizationComponents.host = "accounts.google.com"
        authorizationComponents.path = "/o/oauth2/v2/auth"
        authorizationComponents.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientIdentifier),
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "include_granted_scopes", value: "false"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authorizationURL = authorizationComponents.url else {
            throw GoogleOAuthRequestError.unconstructableURL
        }

        self.authorizationURL = authorizationURL
        self.redirectURL = redirectURL
        self.scopes = scopes
        self.pkce = pkce
        self.state = state
    }

    public init(clientIdentifier: String, redirectPort: Int, scopes: [String]) throws {
        try self.init(
            clientIdentifier: clientIdentifier,
            redirectPort: redirectPort,
            pkce: PKCEPair.generate(),
            state: OAuthState.generate(),
            scopes: scopes
        )
    }

    private static func redirectURL(port: Int) throws -> URL {
        guard let url = URL(string: "http://127.0.0.1:\(port)/oauth/callback") else {
            throw GoogleOAuthRequestError.unconstructableURL
        }
        return url
    }
}

public enum GoogleOAuthRequestError: Error, Equatable, Sendable {
    case invalidClientIdentifier
    case invalidRedirectPort
    case unapprovedScopes
    case invalidOAuthValue
    case unconstructableURL
}

private func containsControlCharacter(_ value: String) -> Bool {
    value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
}
