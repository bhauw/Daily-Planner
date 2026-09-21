import Foundation

public enum GoogleIdentityBindingError: Equatable, Error, Sendable {
    case invalidEmail
}

public struct GoogleIdentityBinding: Codable, Equatable, Sendable {
    public let normalizedEmail: String

    public init(normalizing value: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pieces = normalized.split(separator: "@", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              !pieces[0].isEmpty,
              pieces[1].contains("."),
              !normalized.contains(where: { $0.isWhitespace }),
              !normalized.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw GoogleIdentityBindingError.invalidEmail
        }
        normalizedEmail = normalized
    }
}

public struct GooglePendingIdentity: Equatable, Sendable {
    public let displayEmail: String
    public let binding: GoogleIdentityBinding

    public init(displayEmail: String, binding: GoogleIdentityBinding) {
        self.displayEmail = displayEmail
        self.binding = binding
    }
}

public struct GoogleConnectionReceipt: Equatable, Sendable {
    public let scopes: [String]
    public let refreshSucceeded: Bool
    public let gmailProfileRead: Bool
    public let calendarListRead: Bool
    public let taskListsRead: Bool
    public let binding: GoogleIdentityBinding

    public init(
        scopes: [String],
        refreshSucceeded: Bool,
        gmailProfileRead: Bool,
        calendarListRead: Bool,
        taskListsRead: Bool,
        binding: GoogleIdentityBinding
    ) {
        self.scopes = scopes
        self.refreshSucceeded = refreshSucceeded
        self.gmailProfileRead = gmailProfileRead
        self.calendarListRead = calendarListRead
        self.taskListsRead = taskListsRead
        self.binding = binding
    }
}

public enum GoogleCredentialPresence: Equatable, Sendable {
    case none, clientOnly, complete, inconsistent
}

public enum GoogleConnectionProgress: Equatable, Sendable {
    case connecting, awaitingConsent
}

public enum GoogleOAuthCredentialStoreError: Equatable, Error, Sendable {
    case invalidValue, unavailable, malformed
}

public struct GoogleOAuthClientConfiguration: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let clientIdentifier: String
    public let clientSecret: String

    public init(clientIdentifier: String, clientSecret: String) throws {
        guard Self.isValid(clientIdentifier), Self.isValid(clientSecret) else {
            throw GoogleOAuthCredentialStoreError.invalidValue
        }
        self.clientIdentifier = clientIdentifier
        self.clientSecret = clientSecret
    }

    public var description: String { "GoogleOAuthClientConfiguration(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection()) }

    private static func isValid(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 4_096
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

public enum GoogleConnectionControllerError: Equatable, Error, Sendable {
    case notConfigured, invalidConfiguration, cancelled, offline, scopeMismatch
    case identityMismatch, credentialUnavailable, providerUnavailable, cleanupRequired

    /// A literal name for the log. `StaticString` so a case name is all that can ever be
    /// written — the same rule the calendar decoder's rejection reasons follow.
    public var diagnosticName: StaticString {
        switch self {
        case .notConfigured: return "notConfigured"
        case .invalidConfiguration: return "invalidConfiguration"
        case .cancelled: return "cancelled"
        case .offline: return "offline"
        case .scopeMismatch: return "scopeMismatch"
        case .identityMismatch: return "identityMismatch"
        case .credentialUnavailable: return "credentialUnavailable"
        case .providerUnavailable: return "providerUnavailable"
        case .cleanupRequired: return "cleanupRequired"
        }
    }
}

public protocol GoogleOAuthCredentialStoring: Sendable {
    func storeClientConfiguration(_ value: GoogleOAuthClientConfiguration) throws
    func loadClientConfiguration() throws -> GoogleOAuthClientConfiguration?
    func storeRefreshToken(_ value: String) throws
    func loadRefreshToken() throws -> String?
    func deleteAll() throws
    /// Clears the grant — the refresh token — and nothing else.
    ///
    /// The client configuration is not part of the grant: the user typed it in from the Google
    /// Cloud console, and no failed, cancelled or timed-out connection attempt has any business
    /// destroying it. Cleanup paths use this; only an explicit user disconnect uses `deleteAll()`.
    func deleteGrant() throws
    func presence() throws -> GoogleCredentialPresence
}

public protocol GoogleConnectionControlling: Sendable {
    func saveClientConfiguration(_ value: GoogleOAuthClientConfiguration) throws
    func credentialPresence() throws -> GoogleCredentialPresence
    func begin(
        capability: GoogleGrantedCapability,
        progress: @escaping @Sendable (GoogleConnectionProgress) async -> Void
    ) async throws -> GooglePendingIdentity
    func confirmPendingIdentity() async throws -> GoogleConnectionReceipt
    func cancelPendingConnection() async
    func disconnect() async throws
    /// Clears the current grant while keeping the OAuth client configuration, so the user can
    /// consent again without re-entering their client id and secret.
    ///
    /// Needed because Google cannot widen an existing grant — enabling sending means consenting
    /// from scratch — but `deleteAll()` removes the client configuration too, which would leave
    /// the user disconnected with no way back.
    func disconnectForReconsent() async throws
}

extension GoogleConnectionControlling {
    /// Read-only stays the default, so a caller that has not opted into write access cannot
    /// request it by omission.
    public func begin(
        progress: @escaping @Sendable (GoogleConnectionProgress) async -> Void
    ) async throws -> GooglePendingIdentity {
        try await begin(capability: .readOnly, progress: progress)
    }
}

public protocol SystemBrowserOpening: Sendable {
    func open(_ url: URL) async -> Bool
}
