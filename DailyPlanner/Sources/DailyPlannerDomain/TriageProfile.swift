import Foundation

/*
 * Who you are, and what that means for what you read first.
 *
 * `MailTriagePolicy` ranks an inbox by five fixed categories in one fixed order — school, then
 * recruiting, then finance, then personal, then other — with four hardcoded sets of urgent
 * phrases. Every one of those was a guess made on someone's behalf, and the order only makes
 * sense for one kind of life. Move the same person from term time to a full-time job and the
 * order is wrong; give them an inbox with no course mail in it and the top category is empty.
 *
 * A profile replaces the guess with a statement. It holds:
 *
 *   - `topics`, IN PRIORITY ORDER. The order of the array *is* the ranking, so there is no
 *     second table of weights that can drift out of step with the list a person edits.
 *   - `about`, a short description of the person, which is what an assistant is given when it
 *     proposes topics. "Third-year accounting student recruiting for Big Four co-ops" produces
 *     a different set of topics from "portfolio manager", and neither is guessable from mail
 *     alone.
 *   - `overrides`, the urgent phrase lists, which used to be compiled into an enum. A phrase
 *     list that cannot be corrected without a rebuild is a phrase list that stays wrong.
 *
 * THE DEFAULT PROFILE REPRODUCES TODAY'S BEHAVIOUR EXACTLY. That is deliberate and it is
 * tested: it means there is one ranking path rather than an old one and a new one, and that
 * nobody's inbox re-sorts itself the moment this type exists. A topic may bind to the existing
 * `PlannerCategory` values, which is how the default expresses "this topic IS school" without
 * restating the categoriser's work.
 *
 * Nothing here touches a network, reads a body, or stores provider content. A profile is rules
 * about mail, never mail.
 */

// MARK: - Topic

/// Where a topic came from. Shown in Settings so a proposal is never mistaken for a decision
/// the user made themselves.
public enum TriageTopicOrigin: String, Codable, Hashable, Sendable, CaseIterable {
    /// Shipped in the default profile.
    case builtIn
    /// Suggested by an assistant from the user's own mail, and not yet edited.
    case proposed
    /// Created or edited by the user. Never overwritten by a re-proposal.
    case user
}

/// One thing the user cares about, and how a message is recognised as being about it.
///
/// The three rule kinds are OR'd: any one match is a match. They are deliberately coarse —
/// a sender domain, a whole word in the subject, a Gmail label — because a rule someone has to
/// debug is a rule they will stop trusting. Anything subtler belongs in a proposal the user
/// can read, not in a matcher they cannot see into.
public struct TriageTopic: Codable, Hashable, Sendable, Identifiable {
    /// Stable across renames: the colour and any stored preference are keyed to it.
    public let id: String
    public var name: String
    /// A name from the topic palette, e.g. "blue". Not a hex — the app owns the actual value.
    public var color: String
    /// Matched against the sender as a DOMAIN SUFFIX, so "university.example" matches "mail.university.example" but
    /// "notuniversity.example" does not. Stored lowercased.
    public var senderHosts: [String]
    /// Whole-word matched against subject (and snippet, when the message is not private).
    public var subjectPhrases: [String]
    /// A Gmail user label, matched case-insensitively. An explicit label always outranks a guess.
    public var labels: [String]
    /// Existing categories this topic absorbs. How the default profile says "this is school"
    /// without duplicating the categoriser.
    public var categories: [PlannerCategory]
    public var origin: TriageTopicOrigin

    public init(
        id: String,
        name: String,
        color: String,
        senderHosts: [String] = [],
        subjectPhrases: [String] = [],
        labels: [String] = [],
        categories: [PlannerCategory] = [],
        origin: TriageTopicOrigin = .user
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.senderHosts = senderHosts.map { $0.lowercased() }
        self.subjectPhrases = subjectPhrases.map { $0.lowercased() }
        self.labels = labels
        self.categories = categories
        self.origin = origin
    }

    /// Whether this topic can match anything at all. A topic with no rules and no category
    /// silently never matches, which looks like a bug in the ranking rather than an empty rule
    /// set — so Settings can warn instead of leaving someone puzzled.
    public var hasRules: Bool {
        !senderHosts.isEmpty || !subjectPhrases.isEmpty || !labels.isEmpty || !categories.isEmpty
    }
}

// MARK: - Urgent overrides

/// A kind of message that jumps the queue whatever topic it belongs to.
///
/// Was an enum with compiled-in phrase lists. It is data now for one reason: these lists are
/// wrong until they have met a real inbox, and the person who finds out is the one who cannot
/// rebuild the app.
public struct TriageOverride: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    /// What the row says, in the user's words. "Security warning", not "rule 3".
    public var headline: String
    /// Whole-word matched. Short and specific beats long and eager: a list that catches more is
    /// wrong more often, and being wrong here buries something that mattered.
    public var phrases: [String]
    public var enabled: Bool

    public init(id: String, headline: String, phrases: [String], enabled: Bool = true) {
        self.id = id
        self.headline = headline
        self.phrases = phrases.map { $0.lowercased() }
        self.enabled = enabled
    }
}

// MARK: - Who you are

/// The short self-description an assistant is given when proposing topics.
///
/// Free text, and bounded — it becomes part of a prompt, and a prompt built from an unbounded
/// field is a prompt whose size is somebody else's problem.
public struct TriageAbout: Codable, Hashable, Sendable {
    /// e.g. ["Third-year accounting student at UBC", "Recruiting for Big Four co-ops"].
    public var roles: [String]
    /// Anything that does not fit a role line.
    public var notes: String

    public static let maxRoles = 12
    public static let maxRoleBytes = 200
    public static let maxNotesBytes = 2_000

    public init(roles: [String] = [], notes: String = "") {
        self.roles = roles
        self.notes = notes
    }

    public var isEmpty: Bool {
        roles.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Trimmed, de-duplicated and clipped to the limits. Applied on the way IN, so nothing
    /// downstream has to wonder whether it is looking at a validated value.
    public func normalized() -> TriageAbout {
        var seen = Set<String>()
        var out: [String] = []
        for role in roles {
            let trimmed = role.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= Self.maxRoleBytes else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            out.append(trimmed)
            if out.count == Self.maxRoles { break }
        }
        var notes = self.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.utf8.count > Self.maxNotesBytes {
            notes = String(notes.prefix(Self.maxNotesBytes))
        }
        return TriageAbout(roles: out, notes: notes)
    }
}

// MARK: - Profile

public struct TriageProfile: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var about: TriageAbout
    /// IN PRIORITY ORDER. Index 0 is read first. The array order is the ranking.
    public var topics: [TriageTopic]
    /// In severity order, highest first.
    public var overrides: [TriageOverride]

    public init(
        schemaVersion: Int = TriageProfile.currentSchemaVersion,
        about: TriageAbout = TriageAbout(),
        topics: [TriageTopic],
        overrides: [TriageOverride]
    ) {
        self.schemaVersion = schemaVersion
        self.about = about
        self.topics = topics
        self.overrides = overrides
    }

    /// Where a topic sits. An unmatched message sorts AFTER every topic rather than being
    /// folded into the last one, so "nothing claimed this" stays visible instead of quietly
    /// becoming whatever happens to be bottom of the list.
    public func rank(ofTopic id: String?) -> Int {
        guard let id, let index = topics.firstIndex(where: { $0.id == id }) else {
            return topics.count
        }
        return index
    }

    public func topic(id: String) -> TriageTopic? {
        topics.first { $0.id == id }
    }

    // MARK: The default

    /*
     * Today's behaviour, written as data.
     *
     * The order, the category bindings and the four phrase lists are exactly what
     * MailTriagePolicy compiled in before this type existed, and a test asserts that ranking
     * through this profile gives the same answer as the old path did. That equivalence is the
     * point: shipping a profile system must not re-sort anyone's inbox on the way in.
     *
     * Colours come from the topic palette rather than the category palette, because these are
     * topics now and a user who renames "School" to "UBC" should not lose its colour.
     */
    public static let `default` = TriageProfile(
        about: TriageAbout(),
        topics: [
            TriageTopic(
                id: "school", name: "School", color: "blue",
                categories: [.school], origin: .builtIn
            ),
            TriageTopic(
                id: "recruiting", name: "Recruiting", color: "violet",
                categories: [.career], origin: .builtIn
            ),
            TriageTopic(
                id: "finance", name: "Finance", color: "teal",
                categories: [.finance], origin: .builtIn
            ),
            TriageTopic(
                id: "personal", name: "Personal", color: "magenta",
                categories: [.personal], origin: .builtIn
            ),
            TriageTopic(
                id: "other", name: "Other", color: "slate",
                categories: [.other, .commute, .work], origin: .builtIn
            ),
        ],
        overrides: [
            TriageOverride(
                id: "security", headline: "Security warning",
                phrases: [
                    "security alert", "suspicious sign in", "unusual sign in", "new sign in",
                    "unusual activity", "suspicious activity", "verify your identity",
                    "password was changed", "password was reset", "fraud alert",
                    "unauthorized transaction", "compromised",
                ]
            ),
            TriageOverride(
                id: "interview", headline: "Interview",
                phrases: [
                    "interview", "phone screen", "final round", "assessment centre",
                    "assessment center", "superday", "hiring manager",
                ]
            ),
            TriageOverride(
                id: "obligation", headline: "Payment or enrolment",
                phrases: [
                    "tuition", "rent is due", "invoice", "payment due", "amount due",
                    "past due", "enrolment deadline", "enrollment deadline", "registration closes",
                ]
            ),
            TriageOverride(
                id: "deadline", headline: "Has a deadline",
                phrases: [
                    "due today", "due tomorrow", "deadline", "final notice", "action required",
                    "expires today", "expires tomorrow", "last day", "closes today",
                    "response required", "rsvp by",
                ]
            ),
        ]
    )
}

// MARK: - Matching

public enum TriageProfileMatcher {
    /// The topic a message belongs to, or nil when nothing claims it.
    ///
    /// Rules are checked in the user's own priority order, so the first — highest-priority —
    /// topic that matches wins. That is the behaviour someone editing a ranked list expects:
    /// move a topic up and it starts claiming the messages the one below it used to.
    ///
    /// A LABEL BEATS EVERYTHING. An explicit label is a decision the user already made about
    /// that message, so it is checked across all topics before any sender or subject guess is
    /// considered — otherwise a high-priority topic's keyword would quietly override a label
    /// the user applied by hand.
    public static func topic(
        for item: PlannerMailItem,
        labels: [String] = [],
        profile: TriageProfile
    ) -> TriageTopic? {
        if !labels.isEmpty {
            let applied = Set(labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            for topic in profile.topics
            where topic.labels.contains(where: { applied.contains($0.lowercased()) }) {
                return topic
            }
        }

        // A private message's content is withheld from the screen, so it is not scanned here
        // either — guessing from a subject alone and presenting it with the same confidence
        // would be a worse answer, not a cheaper one.
        let haystack = MailTriagePolicy.normalized(
            item.isPrivate ? item.title : "\(item.title)\n\(item.summary)"
        )
        let sender = item.sender.lowercased()

        for topic in profile.topics {
            if topic.categories.contains(item.category) { return topic }
            if topic.senderHosts.contains(where: { matchesHost(sender, $0) }) { return topic }
            if topic.subjectPhrases.contains(where: { MailTriagePolicy.contains(haystack, $0) }) {
                return topic
            }
        }
        return nil
    }

    /// Whether a sender belongs to a host, matched on domain boundaries.
    ///
    /// "university.example" matches "student@mail.university.example" and "@university.example" but NOT "@notuniversity.example" — a plain
    /// `contains` would match the last one, and a rule that silently claims a lookalike domain
    /// is how a phishing sender inherits a trusted topic.
    public static func matchesHost(_ sender: String, _ host: String) -> Bool {
        let needle = host.lowercased()
        guard !needle.isEmpty else { return false }
        guard let range = sender.lowercased().range(of: needle) else { return false }
        // Must be preceded by @ or . (or be the whole remainder) and end at a boundary.
        let before = range.lowerBound == sender.startIndex
            ? nil
            : sender[sender.index(before: range.lowerBound)]
        let leadingOK = before == nil || before == "@" || before == "."
        let after = range.upperBound == sender.endIndex ? nil : sender[range.upperBound]
        let trailingOK = after == nil || after == ">" || after == " "
        return leadingOK && trailingOK
    }

    /// The first override whose phrase appears, in the profile's own severity order.
    public static func override(
        in item: PlannerMailItem,
        profile: TriageProfile
    ) -> (TriageOverride, String)? {
        let haystack = MailTriagePolicy.normalized(
            item.isPrivate ? item.title : "\(item.title)\n\(item.summary)"
        )
        for rule in profile.overrides where rule.enabled {
            for phrase in rule.phrases where MailTriagePolicy.contains(haystack, phrase) {
                return (rule, phrase)
            }
        }
        return nil
    }
}
