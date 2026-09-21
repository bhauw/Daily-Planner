import Foundation

public struct OAuthHTTPResponse: Sendable {
    public let statusCode: Int
    public let data: Data

    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

public protocol OAuthHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> OAuthHTTPResponse
}

public final class URLSessionOAuthHTTPTransport: OAuthHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> OAuthHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw GoogleReadOnlyClientError.invalidResponse
        }
        return OAuthHTTPResponse(statusCode: response.statusCode, data: data)
    }
}

public protocol RefreshTokenStoring: Sendable {
    func store(_ token: String) throws
    func load() throws -> String
    func delete() throws
}

extension KeychainRefreshToken: RefreshTokenStoring {}

public protocol URLCacheClearing: Sendable {
    func clear()
}

public struct SharedURLCacheCleaner: URLCacheClearing {
    public init() {}

    public func clear() {
        URLCache.shared.removeAllCachedResponses()
    }
}

public struct GoogleReadOnlyProbeResult: Codable, Equatable, Sendable {
    public let scopes: [String]
    public let refreshSucceeded: Bool
    public let gmailProfileRead: Bool
    public let calendarListRead: Bool
    public let taskListsRead: Bool
    public let cleanupSucceeded: Bool

    public init(
        scopes: [String],
        refreshSucceeded: Bool,
        gmailProfileRead: Bool,
        calendarListRead: Bool,
        taskListsRead: Bool,
        cleanupSucceeded: Bool
    ) {
        self.scopes = scopes
        self.refreshSucceeded = refreshSucceeded
        self.gmailProfileRead = gmailProfileRead
        self.calendarListRead = calendarListRead
        self.taskListsRead = taskListsRead
        self.cleanupSucceeded = cleanupSucceeded
    }
}

public enum GoogleOAuthDryRunReport {
    public static func render() -> String {
        let scopeLines = ApprovedScopes.readOnly.map { "scope: \($0)" }
        return ([
            "google-oauth-readonly dry-run",
        ] + scopeLines + [
            "loopback: 127.0.0.1 ephemeral-port",
            "pkce: S256",
            "state: 256-bit",
            "incremental-authorization: disabled",
            "live-readonly: BLOCKED_BY_USER_AUTH",
        ]).joined(separator: "\n")
    }
}

public enum SensitiveValueRedactor {
    public static func redact(_ value: String, knownSecrets: [String] = []) -> String {
        var output = value
        let patterns = [
            #"https?://[^\s\"]+"#,
            #"(?i)Bearer\s+[^\s\"]+"#,
            #"(?i)\"(?:access_token|refresh_token|id_token|code|client_id)\"\s*:\s*\"[^\"]*\""#,
            #"(?i)(?:client_id|code|access_token|refresh_token|id_token)=[^&\s\"]+"#,
        ]
        for pattern in patterns {
            output = output.replacingOccurrences(
                of: pattern,
                with: "[REDACTED]",
                options: .regularExpression
            )
        }
        for secret in knownSecrets where !secret.isEmpty {
            output = output.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        return output
    }
}

public enum GoogleReadOnlyClientError: String, Codable, Error, Equatable, Sendable {
    case tokenExchangeFailed
    case refreshFailed
    case scopeMismatch
    case keychainFailure
    case gmailReadFailed
    case calendarReadFailed
    case tasksReadFailed
    case invalidResponse
    case interrupted
}

public enum GoogleCleanupDisposition: String, Codable, Equatable, Sendable {
    case notRequired
    case succeeded
    case failed
}

public struct GoogleOAuthCleanupStatus: Codable, Equatable, Sendable {
    public let remoteRevocation: GoogleCleanupDisposition
    public let keychainDeletion: GoogleCleanupDisposition
    public let cacheCleared: Bool

    public var succeeded: Bool {
        remoteRevocation != .failed && keychainDeletion == .succeeded && cacheCleared
    }

    public init(
        remoteRevocation: GoogleCleanupDisposition,
        keychainDeletion: GoogleCleanupDisposition,
        cacheCleared: Bool
    ) {
        self.remoteRevocation = remoteRevocation
        self.keychainDeletion = keychainDeletion
        self.cacheCleared = cacheCleared
    }
}

public struct GoogleReadOnlyRunFailure: Codable, Error, Equatable, Sendable {
    public let primary: GoogleReadOnlyClientError
    public let cleanup: GoogleOAuthCleanupStatus

    public init(primary: GoogleReadOnlyClientError, cleanup: GoogleOAuthCleanupStatus) {
        self.primary = primary
        self.cleanup = cleanup
    }
}

public struct GoogleReadOnlyClient: Sendable {
    private let transport: any OAuthHTTPTransport
    private let tokenStore: any RefreshTokenStoring
    private let cacheCleaner: any URLCacheClearing

    public init(
        transport: any OAuthHTTPTransport = URLSessionOAuthHTTPTransport(),
        tokenStore: any RefreshTokenStoring = KeychainRefreshToken(),
        cacheCleaner: any URLCacheClearing = SharedURLCacheCleaner()
    ) {
        self.transport = transport
        self.tokenStore = tokenStore
        self.cacheCleaner = cacheCleaner
    }

    public func run(
        authorizationCode: String,
        request: OAuthRequest
    ) async throws -> GoogleReadOnlyProbeResult {
        var revocationCredential: String?
        do {
            let exchange = try await exchangeAuthorizationCode(
                authorizationCode,
                request: request
            )
            revocationCredential = exchange.revocationCredential
            guard Self.matchesApprovedScopes(exchange.grantedScope) else {
                throw GoogleReadOnlyClientError.scopeMismatch
            }
            guard let temporaryRefreshCredential = exchange.refreshCredential,
                  !temporaryRefreshCredential.isEmpty else {
                throw GoogleReadOnlyClientError.tokenExchangeFailed
            }

            do {
                try tokenStore.store(temporaryRefreshCredential)
            } catch {
                throw GoogleReadOnlyClientError.keychainFailure
            }

            let persistedRefreshCredential: String
            do {
                persistedRefreshCredential = try tokenStore.load()
            } catch {
                throw GoogleReadOnlyClientError.keychainFailure
            }
            let refreshed = try await refreshAccess(
                refreshCredential: persistedRefreshCredential,
                clientID: request.clientID
            )

            let gmailRead = try await read(
                url: Self.gmailProfileURL,
                accessCredential: refreshed.accessToken,
                failure: .gmailReadFailed
            )
            let calendarRead = try await read(
                url: Self.calendarListURL,
                accessCredential: refreshed.accessToken,
                failure: .calendarReadFailed
            )
            let tasksRead = try await read(
                url: Self.tasksListsURL,
                accessCredential: refreshed.accessToken,
                failure: .tasksReadFailed
            )

            let cleanup = await cleanup(revocationCredential: revocationCredential)
            revocationCredential = nil
            return GoogleReadOnlyProbeResult(
                scopes: ApprovedScopes.readOnly,
                refreshSucceeded: true,
                gmailProfileRead: gmailRead,
                calendarListRead: calendarRead,
                taskListsRead: tasksRead,
                cleanupSucceeded: cleanup.succeeded
            )
        } catch {
            let primary: GoogleReadOnlyClientError
            if error is CancellationError {
                primary = .interrupted
            } else if let typed = error as? GoogleReadOnlyClientError {
                primary = typed
            } else {
                primary = .invalidResponse
            }
            let cleanup = await cleanup(revocationCredential: revocationCredential)
            revocationCredential = nil
            throw GoogleReadOnlyRunFailure(primary: primary, cleanup: cleanup)
        }
    }

    private func exchangeAuthorizationCode(
        _ authorizationCode: String,
        request: OAuthRequest
    ) async throws -> AuthorizationExchange {
        let tokenRequest = try Self.formRequest(
            url: Self.tokenURL,
            items: [
                URLQueryItem(name: "grant_type", value: "authorization_code"),
                URLQueryItem(name: "client_id", value: request.clientID),
                URLQueryItem(name: "code", value: authorizationCode),
                URLQueryItem(name: "code_verifier", value: request.pkce.verifier),
                URLQueryItem(name: "redirect_uri", value: request.redirectURL.absoluteString),
            ]
        )
        let response: OAuthHTTPResponse
        do {
            response = try await transport.send(tokenRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GoogleReadOnlyClientError.tokenExchangeFailed
        }
        guard (200..<300).contains(response.statusCode),
              let payload = try? JSONDecoder().decode(TokenResponse.self, from: response.data),
              !payload.accessToken.isEmpty else {
            throw GoogleReadOnlyClientError.tokenExchangeFailed
        }
        let refreshCredential = payload.refreshToken.flatMap { $0.isEmpty ? nil : $0 }
        return AuthorizationExchange(
            refreshCredential: refreshCredential,
            revocationCredential: refreshCredential ?? payload.accessToken,
            grantedScope: payload.scope ?? ""
        )
    }

    private func refreshAccess(
        refreshCredential: String,
        clientID: String
    ) async throws -> TokenResponse {
        let refreshRequest = try Self.formRequest(
            url: Self.tokenURL,
            items: [
                URLQueryItem(name: "grant_type", value: "refresh_token"),
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "refresh_token", value: refreshCredential),
            ]
        )
        let response: OAuthHTTPResponse
        do {
            response = try await transport.send(refreshRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GoogleReadOnlyClientError.refreshFailed
        }
        guard (200..<300).contains(response.statusCode),
              let payload = try? JSONDecoder().decode(TokenResponse.self, from: response.data),
              !payload.accessToken.isEmpty else {
            throw GoogleReadOnlyClientError.refreshFailed
        }
        return payload
    }

    private func read(
        url: URL,
        accessCredential: String,
        failure: GoogleReadOnlyClientError
    ) async throws -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(accessCredential)", forHTTPHeaderField: "Authorization")
        let response: OAuthHTTPResponse
        do {
            response = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw failure
        }
        guard (200..<300).contains(response.statusCode) else {
            throw failure
        }
        return true
    }

    private func cleanup(revocationCredential: String?) async -> GoogleOAuthCleanupStatus {
        let remoteRevocation: GoogleCleanupDisposition
        if let revocationCredential {
            let transport = transport
            let revoked = await Task.detached {
                await Self.revoke(revocationCredential, using: transport)
            }.value
            remoteRevocation = revoked ? .succeeded : .failed
        } else {
            remoteRevocation = .notRequired
        }

        let keychainDeletion: GoogleCleanupDisposition
        do {
            try tokenStore.delete()
            keychainDeletion = .succeeded
        } catch {
            keychainDeletion = .failed
        }
        cacheCleaner.clear()
        return GoogleOAuthCleanupStatus(
            remoteRevocation: remoteRevocation,
            keychainDeletion: keychainDeletion,
            cacheCleared: true
        )
    }

    private static func revoke(
        _ credential: String,
        using transport: any OAuthHTTPTransport
    ) async -> Bool {
        guard let request = try? formRequest(
            url: revokeURL,
            items: [URLQueryItem(name: "token", value: credential)]
        ), let response = try? await transport.send(request) else {
            return false
        }
        return (200..<300).contains(response.statusCode)
    }

    private static func matchesApprovedScopes(_ value: String) -> Bool {
        let granted = value.split(whereSeparator: \Character.isWhitespace).map(String.init)
        return granted.count == ApprovedScopes.readOnly.count
            && Set(granted) == Set(ApprovedScopes.readOnly)
    }

    private static func formRequest(url: URL, items: [URLQueryItem]) throws -> URLRequest {
        var components = URLComponents()
        components.queryItems = items
        guard let encoded = components.percentEncodedQuery?.data(using: .utf8) else {
            throw GoogleReadOnlyClientError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = encoded
        return request
    }

    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let revokeURL = URL(string: "https://oauth2.googleapis.com/revoke")!
    private static let gmailProfileURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!
    private static let calendarListURL = URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList?maxResults=1")!
    private static let tasksListsURL = URL(string: "https://tasks.googleapis.com/tasks/v1/users/@me/lists?maxResults=1")!

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case scope
        }
    }

    private struct AuthorizationExchange: Sendable {
        let refreshCredential: String?
        let revocationCredential: String
        let grantedScope: String
    }
}
