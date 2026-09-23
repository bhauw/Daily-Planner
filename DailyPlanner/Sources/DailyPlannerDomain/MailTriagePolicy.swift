import Foundation

/*
 * What to read first.
 *
 * Digest used to be a second copy of Focus: the same rows, the same stylesheet, ordered by the
 * clock. This is the rule that makes it a mail surface instead — an inbox ordered by what the
 * message is ABOUT, not when it arrived.
 *
 * The order is Braxton's, stated directly: school, then recruiting/career, then finance, then
 * personal, then everything else. `PlannerCategory`'s own raw values already run in exactly that
 * order, so the base rank is the category itself rather than a second table that could drift
 * out of step with it.
 *
 * Four kinds of message jump the queue regardless of category — a security or fraud warning, an
 * interview, a stated deadline, and a major obligation like tuition or rent. Promotions, social
 * noise and spam are hidden rather than ranked last, because a list you have to scroll past is
 * not a list that got triaged.
 *
 * Nothing here talks to a network, and nothing here reads a message body beyond the snippet the
 * mail source already chose to expose. Every decision carries the phrase that caused it, so a
 * row can say WHY it is where it is — a ranking you cannot interrogate is one you stop trusting
 * the first time it is wrong.
 */

/// Why a message is where it is. The urgent cases are the four that override category order.
public enum MailTriageReason: String, Codable, Hashable, Sendable, CaseIterable {
    /// A sign-in warning, a fraud alert, a password change. Read these first, always.
    case security
    /// An interview, a phone screen, a final round. Time-critical and easy to lose in a list.
    case interview
    /// The message states a date something is due, closes, or expires.
    case deadline
    /// Tuition, rent, an invoice, an enrolment — money or standing that lapses if ignored.
    case obligation
    /// A rule the user wrote in their triage profile.
    case custom
    /// No override applied; it sits in its category's place.
    case category
}

extension MailTriageReason {
    /// Whether this reason lifts a message above the category order.
    public var overridesCategory: Bool { self != .category }
}

/// The two bands a message can land in. Ordered, so a sort can use them directly.
public enum MailTriageBand: Int, Codable, Hashable, Sendable, Comparable {
    case urgent = 0
    case ordinary = 1

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One triaged message: where it landed, and the phrase that put it there.
public struct MailTriageEntry: Hashable, Sendable {
    public let item: PlannerMailItem
    public let band: MailTriageBand
    public let reason: MailTriageReason
    /// Shown to the user, in their words rather than a rule name. Never empty.
    public let why: String

    public init(item: PlannerMailItem, band: MailTriageBand, reason: MailTriageReason, why: String) {
        self.item = item
        self.band = band
        self.reason = reason
        self.why = why
    }
}

public struct MailTriageResult: Hashable, Sendable {
    /// Ranked, highest first.
    public let entries: [MailTriageEntry]
    /// How many messages were withheld as promotions, social noise or spam. Reported rather
    /// than silently dropped: "14 promotions hidden" is information; a shorter list is not.
    public let hiddenCount: Int

    public init(entries: [MailTriageEntry], hiddenCount: Int) {
        self.entries = entries
        self.hiddenCount = hiddenCount
    }
}

public enum MailTriagePolicy {
    /// Braxton's stated order. Asserted against `PlannerCategory`'s raw values in the tests, so
    /// reordering the enum without reordering this is caught rather than silently re-ranking
    /// someone's inbox.
    public static let categoryOrder: [PlannerCategory] = [.school, .career, .finance, .personal, .other]

    /// Ranks an inbox.
    ///
    /// - Parameter unreadOnly: when true, messages already read are dropped. They are not
    ///   ranked below — a triage list is about what still needs attention.
    public static func triage(_ items: [PlannerMailItem], unreadOnly: Bool = false) -> MailTriageResult {
        triage(items, profile: .default, unreadOnly: unreadOnly)
    }

    /// Ranks an inbox by a profile — the one ranking path. The zero-argument form above is this
    /// with `TriageProfile.default`, which is today's compiled order written as data.
    public static func triage(
        _ items: [PlannerMailItem],
        profile: TriageProfile,
        unreadOnly: Bool = false
    ) -> MailTriageResult {
        var hidden = 0
        var ranked: [(entry: MailTriageEntry, rank: Int)] = []

        for item in items {
            if item.isBulk {
                hidden += 1
                continue
            }
            if unreadOnly, !item.isUnread { continue }
            let topic = TriageProfileMatcher.topic(for: item, profile: profile)
            ranked.append((entry(for: item, topic: topic, profile: profile), profile.rank(ofTopic: topic?.id)))
        }

        ranked.sort { lhs, rhs in
            precedes(lhs.entry, lhs.rank, rhs.entry, rhs.rank)
        }
        return MailTriageResult(entries: ranked.map(\.entry), hiddenCount: hidden)
    }

    /// The total order. Band, then category, then newest first.
    ///
    /// Recency is the LAST key, not the first. That is the whole point: a promotional blast
    /// from four minutes ago used to sit above a midterm notice from this morning.
    static func precedes(_ lhs: MailTriageEntry, _ left: Int, _ rhs: MailTriageEntry, _ right: Int) -> Bool {
        if lhs.band != rhs.band { return lhs.band < rhs.band }
        if left != right { return left < right }
        if lhs.item.receivedAt != rhs.item.receivedAt {
            return lhs.item.receivedAt > rhs.item.receivedAt
        }
        // A stable tiebreak so the list does not reshuffle between reads.
        return lhs.item.id < rhs.item.id
    }

    /// One message's entry under the default profile.
    static func entry(for item: PlannerMailItem) -> MailTriageEntry {
        entry(for: item, topic: TriageProfileMatcher.topic(for: item, profile: .default), profile: .default)
    }

    static func entry(for item: PlannerMailItem, topic: TriageTopic?, profile: TriageProfile) -> MailTriageEntry {
        // A message whose content is withheld cannot be scanned for phrases, and guessing from
        // a subject alone would be a worse answer presented with the same confidence. It takes
        // its topic's place and says so. (The matcher applies the same rule.)
        if let (rule, phrase) = TriageProfileMatcher.override(in: item, profile: profile) {
            let reason = MailTriageReason(rawValue: rule.id).flatMap { $0.overridesCategory ? $0 : nil } ?? .custom
            return MailTriageEntry(
                item: item,
                band: .urgent,
                reason: reason,
                why: "\(rule.headline) — \"\(phrase)\""
            )
        }
        return MailTriageEntry(
            item: item,
            band: .ordinary,
            reason: .category,
            // Unclaimed mail says what it is rather than a topic it does not belong to — the
            // same "Commute" / "Work" the compiled policy showed.
            why: topic?.name ?? item.category.triageLabel
        )
    }

    /// The first override whose phrase appears in `text`, in the profile's severity order.
    ///
    /// Severity order matters: "your interview is confirmed, payment due" is an interview that
    /// mentions money, and a security warning outranks everything because the cost of reading
    /// it late is the highest on the list.
    static func override(in text: String, profile: TriageProfile = .default) -> (MailTriageReason, String)? {
        let haystack = normalized(text)
        for rule in profile.overrides where rule.enabled {
            for phrase in rule.phrases where contains(haystack, phrase) {
                return (MailTriageReason(rawValue: rule.id).flatMap { $0.overridesCategory ? $0 : nil } ?? .custom, phrase)
            }
        }
        return nil
    }

    /// Lowercased, with runs of anything non-alphanumeric collapsed to a single space and the
    /// whole thing space-padded. That makes `contains` a whole-word match without a regex, so
    /// "due" cannot fire on "overdue" and "fraud" cannot fire on "fraudulently".
    public static func normalized(_ text: String) -> String {
        var out = " "
        var lastWasSeparator = true
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                out.append(" ")
                lastWasSeparator = true
            }
        }
        if !lastWasSeparator { out.append(" ") }
        return out.lowercased()
    }

    public static func contains(_ normalizedHaystack: String, _ phrase: String) -> Bool {
        normalizedHaystack.contains(" \(phrase) ")
    }
}

extension PlannerCategory {
    /// The category as a mail row names it. `career` is "Recruiting" here because that is what
    /// the mail in it actually is, even though the calendar calls the same category "Career".
    var triageLabel: String {
        switch self {
        case .school: return "School"
        case .career: return "Recruiting"
        case .finance: return "Finance"
        case .personal: return "Personal"
        case .other: return "Other"
        case .commute: return "Commute"
        case .work: return "Work"
        }
    }
}
