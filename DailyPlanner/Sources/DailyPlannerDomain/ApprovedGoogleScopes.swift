/// The exact scope sets this app will ever request or accept.
///
/// Two sets, not one. `readOnly` is what every account connected so far was granted, and it
/// keeps working untouched — swapping the approved set outright would fail the exact-match check
/// on existing credentials, drop the app back to synthetic fixtures and blank the calendar until
/// the user happened to reconnect. `readWrite` adds exactly two capabilities on top, and is only
/// granted after the user reconnects and consents again: a refresh token cannot gain scopes.
///
/// Both sets stay exact-match. The point of the check is that a token carrying anything we did
/// not ask for is refused, so "a bit more than expected" is still a mismatch.
public enum ApprovedGoogleScopes {
    public static let readOnly = [
        "openid",
        "email",
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/tasks.readonly",
    ]

    /// `gmail.send` can only send; it grants no ability to read, modify or delete mail beyond
    /// what `gmail.readonly` already allows. `calendar.events` is needed to create events —
    /// Google has no narrower "insert only" calendar scope.
    public static let readWrite =
        readOnly + [
            "https://www.googleapis.com/auth/gmail.send",
            "https://www.googleapis.com/auth/calendar.events",
        ]

    /// Every set the token validator will accept.
    public static let approvedSets = [readOnly, readWrite]
}

/// What the credentials currently held actually permit.
///
/// Derived from the scopes Google granted, never from a local preference — the UI must not offer
/// a Send button that the token cannot honour, and must not hide one that it can.
public enum GoogleGrantedCapability: String, Codable, Sendable, Equatable, CaseIterable {
    case readOnly
    case readWrite

    public var canSendMail: Bool { self == .readWrite }
    public var canCreateEvents: Bool { self == .readWrite }

    public var scopes: [String] {
        switch self {
        case .readOnly: return ApprovedGoogleScopes.readOnly
        case .readWrite: return ApprovedGoogleScopes.readWrite
        }
    }

    /// The capability matching an exact granted set, or nil if the grant is not one we approve.
    public static func matching(_ grantedScopes: [String]) -> GoogleGrantedCapability? {
        allCases.first { Set($0.scopes) == Set(grantedScopes) && $0.scopes.count == grantedScopes.count }
    }
}
