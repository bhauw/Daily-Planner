import Foundation
import XCTest
@testable import DailyPlannerDomain

/// A ranking you can edit.
///
/// The load-bearing test is the first one: the DEFAULT profile must rank an inbox exactly as the
/// compiled-in policy did, entry for entry — band, reason, the words on the row, and the order.
/// Shipping editable triage must not re-sort anyone's inbox on the way in. The golden order is
/// written out literally as well, so the equivalence cannot become a tautology once the old path
/// delegates to the new one.
final class TriageProfileTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func mail(
        _ id: String,
        title: String = "Subject",
        summary: String = "",
        sender: String = "someone@example.com",
        category: PlannerCategory = .other,
        minutesAgo: Int = 0,
        isPrivate: Bool = false,
        isUnread: Bool = true,
        isBulk: Bool = false
    ) -> PlannerMailItem {
        PlannerMailItem(
            id: id, title: title, summary: summary, sender: sender,
            receivedAt: base.addingTimeInterval(TimeInterval(-minutesAgo * 60)),
            category: category, isPrivate: isPrivate, isUnread: isUnread, isBulk: isBulk
        )
    }

    /// Every branch the old policy had: each category including the two it ranks after Other,
    /// each override in severity order, a private message whose snippet must not be scanned, a
    /// bulk one, read and unread, and ties broken by recency and then id.
    private var corpus: [PlannerMailItem] {
        [
            mail("other-new", category: .other, minutesAgo: 1),
            mail("commute", title: "Bus detour", category: .commute, minutesAgo: 2),
            mail("work", title: "Shift swap", category: .work, minutesAgo: 3),
            mail("school-old", title: "Reading list", category: .school, minutesAgo: 300),
            mail("school-new", title: "Lab moved", category: .school, minutesAgo: 30),
            mail("career", title: "Coffee chat", category: .career, minutesAgo: 40),
            mail("finance", title: "Statement ready", category: .finance, minutesAgo: 50),
            mail("personal", title: "Dinner Sunday", category: .personal, minutesAgo: 60),
            mail("security", title: "Security alert", category: .other, minutesAgo: 500),
            mail("interview", title: "Your interview is confirmed", summary: "payment due", category: .career, minutesAgo: 10),
            mail("deadline", title: "Form", summary: "Action required by Friday", category: .school, minutesAgo: 20),
            mail("obligation", title: "Tuition", category: .finance, minutesAgo: 5),
            mail("private", title: "Checkup", summary: "security alert", category: .personal, minutesAgo: 70, isPrivate: true),
            mail("bulk", title: "50% off", category: .other, isBulk: true),
            mail("read", title: "Old news", category: .school, minutesAgo: 90, isUnread: false),
            mail("tie-b", title: "Tie", category: .finance, minutesAgo: 55),
            mail("tie-a", title: "Tie", category: .finance, minutesAgo: 55),
        ]
    }

    private func summary(_ result: MailTriageResult) -> [String] {
        result.entries.map { "\($0.item.id)|\($0.band)|\($0.reason.rawValue)|\($0.why)" }
    }

    // MARK: - The default IS today's behaviour

    func testTheDefaultProfileRanksExactlyAsTheCompiledPolicyDid() {
        let expected = [
            // Urgent mail is ordered by CATEGORY, then recency — not by severity. That is what
            // the compiled policy did, and the default must not change it.
            "deadline|urgent|deadline|Has a deadline — \"action required\"",
            "interview|urgent|interview|Interview — \"interview\"",
            "obligation|urgent|obligation|Payment or enrolment — \"tuition\"",
            "security|urgent|security|Security warning — \"security alert\"",
            "school-new|ordinary|category|School",
            "read|ordinary|category|School",
            "school-old|ordinary|category|School",
            "career|ordinary|category|Recruiting",
            "finance|ordinary|category|Finance",
            "tie-a|ordinary|category|Finance",
            "tie-b|ordinary|category|Finance",
            "personal|ordinary|category|Personal",
            "private|ordinary|category|Personal",
            "other-new|ordinary|category|Other",
            "commute|ordinary|category|Commute",
            "work|ordinary|category|Work",
        ]
        let profiled = MailTriagePolicy.triage(corpus, profile: .default)
        XCTAssertEqual(summary(profiled), expected)
        XCTAssertEqual(profiled.hiddenCount, 1)
        XCTAssertEqual(summary(MailTriagePolicy.triage(corpus)), expected)
    }

    func testUnreadOnlyStillDropsReadMailUnderAProfile() {
        let ids = MailTriagePolicy.triage(corpus, profile: .default, unreadOnly: true).entries.map(\.item.id)
        XCTAssertFalse(ids.contains("read"))
    }

    // MARK: - Editing it changes the ranking

    func testMovingATopicUpMovesItsMailUp() {
        var profile = TriageProfile.default
        let finance = profile.topics.remove(at: 2)
        profile.topics.insert(finance, at: 0)
        let ordinary = MailTriagePolicy.triage(corpus, profile: profile).entries.filter { $0.band == .ordinary }
        XCTAssertEqual(ordinary.first?.item.id, "finance")
    }

    func testAUserTopicClaimsMailByHostAndSaysItsOwnName() {
        var profile = TriageProfile.default
        profile.topics.insert(
            TriageTopic(id: "example-corp", name: "Example Corp", color: "green", senderHosts: ["example.test"]),
            at: 0
        )
        let items = [
            mail("d", title: "Next steps", sender: "Alex <alex@example.test>", category: .career, minutesAgo: 100),
            mail("s", title: "Lab", category: .school),
            mail("lookalike", title: "Next steps", sender: "x@notexample.test", category: .other),
        ]
        let entries = MailTriagePolicy.triage(items, profile: profile).entries
        XCTAssertEqual(entries.first?.item.id, "d")
        XCTAssertEqual(entries.first?.why, "Example Corp")
        XCTAssertEqual(entries.last?.item.id, "lookalike", "a lookalike domain must not inherit the topic")
    }

    func testADisabledOverrideNoLongerLiftsAndACustomOneDoes() {
        var profile = TriageProfile.default
        profile.overrides[1].enabled = false // interview
        profile.overrides.append(TriageOverride(id: "custom-1", headline: "From my manager", phrases: ["quarterly review"]))
        let items = [
            mail("i", title: "Interview Thursday", category: .career),
            mail("q", title: "Quarterly review notes", category: .other),
        ]
        let byID = Dictionary(uniqueKeysWithValues: MailTriagePolicy.triage(items, profile: profile).entries.map { ($0.item.id, $0) })
        XCTAssertEqual(byID["i"]?.band, .ordinary)
        XCTAssertEqual(byID["q"]?.band, .urgent)
        XCTAssertEqual(byID["q"]?.reason, .custom)
        XCTAssertEqual(byID["q"]?.why, "From my manager — \"quarterly review\"")
    }

    func testAPrivateMessagesSnippetIsNotScannedForTopicsEither() {
        var profile = TriageProfile.default
        profile.topics.insert(TriageTopic(id: "t", name: "Health", color: "red", subjectPhrases: ["checkup"]), at: 0)
        let hidden = mail("p", title: "Hello", summary: "your checkup", category: .other, isPrivate: true)
        XCTAssertEqual(MailTriagePolicy.triage([hidden], profile: profile).entries.first?.why, "Other")
    }

    // MARK: - Round trip

    func testAProfileSurvivesEncoding() throws {
        var profile = TriageProfile.default
        profile.about = TriageAbout(roles: ["Accounting student at UBC"], notes: "Recruiting for Big Four co-ops")
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(TriageProfile.self, from: data), profile)
    }

    func testAboutIsTrimmedDeduplicatedAndBounded() {
        let about = TriageAbout(
            roles: ["  Student ", "student", "", String(repeating: "x", count: 300)] + (0..<20).map { "Role \($0)" },
            notes: String(repeating: "n", count: 3_000)
        ).normalized()
        XCTAssertEqual(about.roles.first, "Student")
        XCTAssertEqual(about.roles.count, TriageAbout.maxRoles)
        XCTAssertLessThanOrEqual(about.notes.utf8.count, TriageAbout.maxNotesBytes)
    }

    func testHostMatchingRespectsDomainBoundaries() {
        XCTAssertTrue(TriageProfileMatcher.matchesHost("a@mail.university.example", "university.example"))
        XCTAssertTrue(TriageProfileMatcher.matchesHost("Name <a@university.example>", "university.example"))
        XCTAssertFalse(TriageProfileMatcher.matchesHost("a@notuniversity.example", "university.example"))
        XCTAssertFalse(TriageProfileMatcher.matchesHost("a@university.example.evil.com", "university.example"))
    }
}
