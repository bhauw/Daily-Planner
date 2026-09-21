import Foundation

public enum OAuthRequestError: Error, Equatable, Sendable {
    case invalidClientID
    case invalidRedirectPort
    case invalidAuthorizationURL
    case unapprovedScopes
}

public enum ApprovedScopes {
    public static let readOnly = [
        "openid",
        "email",
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/tasks.readonly",
    ]

    public static func validate(_ scopes: [String]) throws {
        guard scopes == readOnly else {
            throw OAuthRequestError.unapprovedScopes
        }
    }
}

public struct OAuthRequest: Sendable {
    let clientID: String
    public let scopes: [String]
    public let redirectURL: URL
    public let authorizationURL: URL
    public let pkce: PKCEPair
    public let state: String

    public init(
        clientID: String,
        redirectPort: UInt16,
        pkce: PKCEPair? = nil,
        state: String? = nil,
        scopes: [String] = ApprovedScopes.readOnly
    ) throws {
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OAuthRequestError.invalidClientID
        }
        guard redirectPort > 0 else {
            throw OAuthRequestError.invalidRedirectPort
        }
        try ApprovedScopes.validate(scopes)

        let resolvedPKCE = try pkce ?? PKCEPair.generate()
        let resolvedState = try state ?? OAuthState.generate()
        guard !resolvedState.isEmpty else {
            throw OAuthRequestError.invalidAuthorizationURL
        }

        var redirect = URLComponents()
        redirect.scheme = "http"
        redirect.host = "127.0.0.1"
        redirect.port = Int(redirectPort)
        redirect.path = "/oauth/callback"
        guard let redirectURL = redirect.url else {
            throw OAuthRequestError.invalidAuthorizationURL
        }

        var authorization = URLComponents()
        authorization.scheme = "https"
        authorization.host = "accounts.google.com"
        authorization.path = "/o/oauth2/v2/auth"
        authorization.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: resolvedPKCE.challenge),
            URLQueryItem(name: "code_challenge_method", value: resolvedPKCE.method),
            URLQueryItem(name: "state", value: resolvedState),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "include_granted_scopes", value: "false"),
        ]
        guard let authorizationURL = authorization.url else {
            throw OAuthRequestError.invalidAuthorizationURL
        }

        self.clientID = clientID
        self.scopes = scopes
        self.redirectURL = redirectURL
        self.authorizationURL = authorizationURL
        self.pkce = resolvedPKCE
        self.state = resolvedState
    }
}
