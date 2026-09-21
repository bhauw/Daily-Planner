import Foundation

public enum CalendarRoleChangeActor: String, Codable, Hashable, Sendable {
    case localUser
}

public struct CalendarRoleAuditEntry: Codable, Equatable, Sendable {
    public let calendarID: CalendarID
    public let oldRole: CalendarRole
    public let newRole: CalendarRole
    public let actor: CalendarRoleChangeActor
    public let changedAt: Date

    public init(
        calendarID: CalendarID,
        oldRole: CalendarRole,
        newRole: CalendarRole,
        actor: CalendarRoleChangeActor,
        changedAt: Date
    ) {
        self.calendarID = calendarID
        self.oldRole = oldRole
        self.newRole = newRole
        self.actor = actor
        self.changedAt = changedAt
    }
}

public struct PrivateSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public var schemaVersion = currentSchemaVersion
    public var vaultBookmark: Data?
    public var googleAccountBinding: GoogleIdentityBinding?
    /// What the stored grant actually permits.
    ///
    /// Derived from the scopes Google returned, never from what was requested. Absent on grants
    /// made before write access existed, which is why readers treat nil as `.readOnly`: a grant
    /// we cannot describe must not be assumed to allow more than reading.
    public var googleGrantedCapability: GoogleGrantedCapability?
    public var calendarRoles: [CalendarID: CalendarRole]
    public var calendarRoleAudit: [CalendarRoleAuditEntry]
    /// User-editable map of Google `colorId` → planner category. Ships empty; Settings
    /// populates it from the colours actually in use in the connected account.
    public var colorCategoryMapping: [String: PlannerCategory]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        vaultBookmark: Data?,
        googleAccountBinding: GoogleIdentityBinding? = nil,
        googleGrantedCapability: GoogleGrantedCapability? = nil,
        calendarRoles: [CalendarID: CalendarRole],
        calendarRoleAudit: [CalendarRoleAuditEntry],
        colorCategoryMapping: [String: PlannerCategory] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.vaultBookmark = vaultBookmark
        self.googleAccountBinding = googleAccountBinding
        self.googleGrantedCapability = googleGrantedCapability
        self.calendarRoles = calendarRoles
        self.calendarRoleAudit = calendarRoleAudit
        self.colorCategoryMapping = colorCategoryMapping
    }

    public static let empty = PrivateSettings(
        vaultBookmark: nil,
        googleAccountBinding: nil,
        calendarRoles: [:],
        calendarRoleAudit: [],
        colorCategoryMapping: [:]
    )

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, vaultBookmark, googleAccountBinding, googleGrantedCapability
        case calendarRoles, calendarRoleAudit, colorCategoryMapping
    }

    // Tolerant decode: `colorCategoryMapping` was added within schema v2, so blobs
    // written before it must still load (missing key → empty). The other fields keep
    // the synthesized behaviour (optionals absent when nil).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        vaultBookmark = try container.decodeIfPresent(Data.self, forKey: .vaultBookmark)
        googleAccountBinding = try container.decodeIfPresent(
            GoogleIdentityBinding.self, forKey: .googleAccountBinding
        )
        // Absent on every grant made before write access existed; nil reads as read-only.
        googleGrantedCapability = try container.decodeIfPresent(
            GoogleGrantedCapability.self, forKey: .googleGrantedCapability
        )
        calendarRoles = try container.decode([CalendarID: CalendarRole].self, forKey: .calendarRoles)
        calendarRoleAudit = try container.decode(
            [CalendarRoleAuditEntry].self, forKey: .calendarRoleAudit
        )
        colorCategoryMapping = try container.decodeIfPresent(
            [String: PlannerCategory].self, forKey: .colorCategoryMapping
        ) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(vaultBookmark, forKey: .vaultBookmark)
        try container.encodeIfPresent(googleAccountBinding, forKey: .googleAccountBinding)
        // Omitted here once, which made the field impossible to persist: `init(from:)` read it
        // and `CodingKeys` declared it, so every write silently dropped it and every read got
        // nil back. That is what left the app telling the user "read-only" while holding a
        // token that could send — and what made `AppComposition.resolveCapability`'s correction
        // a no-op, because the value it wrote could never survive the encode.
        try container.encodeIfPresent(googleGrantedCapability, forKey: .googleGrantedCapability)
        try container.encode(calendarRoles, forKey: .calendarRoles)
        try container.encode(calendarRoleAudit, forKey: .calendarRoleAudit)
        try container.encode(colorCategoryMapping, forKey: .colorCategoryMapping)
    }
}
