import Foundation
import XCTest
@testable import DailyPlannerDomain

/// The rule that decides what Braxton reads first.
///
/// Getting this wrong is not a cosmetic failure: it buries the thing that mattered under the
/// thing that did not, and the user has no way to tell it happened. So the order is asserted
/// whole, the overrides are asserted individually, and the phrase matcher is asserted against
/// the near-misses that would make it fire on ordinary mail.
final class MailTriagePolicyTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func mail(
        _ id: String,
        title: String = "Subject",
        summary: String = "",
        category: PlannerCategory = .other,
        minutesAgo: Int = 0,
        isPrivate: Bool = false,
        isUnread: Bool = true,
        isBulk: Bool = false
    ) -> PlannerMailItem {
        PlannerMailItem(
            id: id,
            title: title,
            summary: summary,
            sender: "someone@example.com",
            receivedAt: base.addingTimeInterval(TimeInterval(-minutesAgo * 60)),
            category: category,
            isPrivate: isPrivate,
            isUnread: isUnread,
            isBulk: isBulk
        )
    }

    // MARK: - The order

    func testCategoryOrderIsTheOneBraxtonStated() {
        // Break caught: the order drifts from what he asked for. School, recruiting, finance,
        // personal, other — stated directly, and the whole surface depends on it.
        XCTAssertEqual(MailTriagePolicy.categoryOrder, [.school, .career, .finance, .personal, .other])
    }

    func testTheEnumsOwnOrderBacksTheStatedOne() {
        // Break caught: `PlannerCategory`'s raw values are reordered for some unrelated reason
        // and quietly re-rank someone's inbox. The policy leans on this agreement, so it is
        // asserted rather than assumed.
        let byRawValue = MailTriagePolicy.categoryOrder.sorted { $0.rawValue < $1.rawValue }
        XCTAssertEqual(byRawValue, MailTriagePolicy.categoryOrder)
    }

    func testMailIsOrderedByCategoryNotByArrivalTime() {
        // Break caught: Digest goes back to being a clock-ordered list. The newest message here
        // is `other` and the oldest is `school`; school must still come first.
        let items = [
            mail("d", category: .other, minutesAgo: 1),
            mail("c", category: .personal, minutesAgo: 10),
            mail("b", category: .finance, minutesAgo: 100),
            mail("a", category: .career, minutesAgo: 500),
            mail("z", category: .school, minutesAgo: 5_000),
        ]
        let ranked = MailTriagePolicy.triage(items).entries.map(\.item.id)
        XCTAssertEqual(ranked, ["z", "a", "b", "c", "d"])
    }

    func testRecencyOnlyBreaksTiesWithinACategory() {
        let items = [
            mail("old", category: .school, minutesAgo: 600),
            mail("new", category: .school, minutesAgo: 5),
            mail("middle", category: .school, minutesAgo: 60),
        ]
        XCTAssertEqual(
            MailTriagePolicy.triage(items).entries.map(\.item.id),
            ["new", "middle", "old"]
        )
    }

    func testAnUnrankedCategorySortsAfterOtherRatherThanIntoIt() {
        // `commute` and `work` are not in the stated order. They go last, visibly, instead of
        // being folded onto `other` where it would be invisible that they were never ranked.
        let items = [mail("w", category: .work), mail("o", category: .other)]
        XCTAssertEqual(MailTriagePolicy.triage(items).entries.map(\.item.id), ["o", "w"])
    }

    // MARK: - The overrides

    func testTheFourOverridesLiftAMessageAboveEveryCategory() {
        // Break caught: an override stops overriding. Each of these is `other` — the lowest
        // ranked category — and each must still beat an ordinary school message.
        let cases: [(String, String, MailTriageReason)] = [
            ("security", "Security alert on your account", .security),
            ("interview", "Your interview is confirmed", .interview),
            ("obligation", "Tuition statement available", .obligation),
            ("deadline", "Action required before Friday", .deadline),
        ]
        for (id, subject, reason) in cases {
            let items = [mail("school", category: .school), mail(id, title: subject, category: .other)]
            let entries = MailTriagePolicy.triage(items).entries
            XCTAssertEqual(entries.first?.item.id, id, "\(reason) must outrank a school message")
            XCTAssertEqual(entries.first?.band, .urgent)
            XCTAssertEqual(entries.first?.reason, reason)
        }
    }

    func testSecurityOutranksTheOtherOverrides() {
        // A message that is both is read as the more costly one to miss.
        let both = mail("x", title: "Security alert", summary: "Your interview is confirmed, payment due")
        XCTAssertEqual(MailTriagePolicy.entry(for: both).reason, .security)
    }

    func testEveryEntryCarriesThePhraseThatRankedIt() {
        // Break caught: the row cannot say why it is where it is. A ranking you cannot
        // interrogate is one the user stops trusting the first time it is wrong.
        let urgent = MailTriagePolicy.entry(for: mail("u", title: "Final notice"))
        XCTAssertTrue(urgent.why.contains("final notice"), urgent.why)
        XCTAssertFalse(urgent.why.isEmpty)

        let ordinary = MailTriagePolicy.entry(for: mail("o", category: .career))
        XCTAssertEqual(ordinary.why, "Recruiting")
    }

    func testPhrasesMatchWholeWordsOnly() {
        // Break caught: the matcher becomes a substring search. Every subject here contains an
        // override phrase as a FRAGMENT and none of them is urgent.
        let nearMisses = [
            "Your subscription is overdue for renewal review", // "due" inside "overdue"
            "Fraudulently obtained — a documentary",           // "fraud" inside "fraudulently"
            "Interviewing techniques workshop",                // "interview" inside "interviewing"
            "Compromised? A book review",                      // whole word, but see below
        ]
        XCTAssertNil(MailTriagePolicy.override(in: nearMisses[0]))
        XCTAssertNil(MailTriagePolicy.override(in: nearMisses[1]))
        XCTAssertNil(MailTriagePolicy.override(in: nearMisses[2]))
        // The last one genuinely contains the whole word, so it DOES fire. Recorded here rather
        // than hidden: this is the kind of false positive the list is expected to be corrected
        // for against a real inbox, and it should be visible when it changes.
        XCTAssertEqual(MailTriagePolicy.override(in: nearMisses[3])?.0, .security)
    }

    func testPunctuationAndCaseDoNotHideAPhrase() {
        XCTAssertEqual(MailTriagePolicy.override(in: "ACTION REQUIRED: read this")?.0, .deadline)
        XCTAssertEqual(MailTriagePolicy.override(in: "Re: [Deadline] reminder")?.0, .deadline)
        XCTAssertEqual(MailTriagePolicy.override(in: "suspicious sign-in detected")?.0, .security)
    }

    // MARK: - What is hidden, and what is not

    func testPromotionsAndSpamAreHiddenAndCounted() {
        // Break caught: bulk mail is ranked last instead of hidden, so the list is still
        // something you have to scroll past. Or it is dropped silently, which is worse — the
        // count is what makes the hiding honest.
        let items = [
            mail("keep", category: .school),
            mail("promo", isBulk: true),
            mail("spam", isBulk: true),
        ]
        let result = MailTriagePolicy.triage(items)
        XCTAssertEqual(result.entries.map(\.item.id), ["keep"])
        XCTAssertEqual(result.hiddenCount, 2)
    }

    func testAnUrgentPromotionIsStillHidden() {
        // "ACTION REQUIRED" in a marketing blast is how marketing blasts are written. Gmail
        // already classified it; the override must not pull it back into view.
        let items = [mail("promo", title: "ACTION REQUIRED: 50% off", isBulk: true)]
        let result = MailTriagePolicy.triage(items)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.hiddenCount, 1)
    }

    func testUnreadOnlyDropsReadMailRatherThanDemotingIt() {
        let items = [mail("read", category: .school, isUnread: false), mail("unread", category: .other)]
        XCTAssertEqual(
            MailTriagePolicy.triage(items, unreadOnly: true).entries.map(\.item.id),
            ["unread"]
        )
        XCTAssertEqual(MailTriagePolicy.triage(items).entries.count, 2)
    }

    func testAPrivateMessageIsRankedOnItsSubjectAndNeverOnWithheldContent() {
        // The snippet of a private message is withheld from the UI. Scanning it here would read
        // content the user was told is not shown — so only the subject is considered.
        let hidden = mail(
            "p",
            title: "Weekly note",
            summary: "Security alert: unusual activity",
            isPrivate: true
        )
        XCTAssertEqual(MailTriagePolicy.entry(for: hidden).band, .ordinary)

        let visible = mail("v", title: "Weekly note", summary: "Security alert: unusual activity")
        XCTAssertEqual(MailTriagePolicy.entry(for: visible).band, .urgent)
    }

    func testOrderIsStableAcrossReads() {
        // Break caught: two messages with the same band, category and timestamp reshuffle
        // between reads, so the list moves under the cursor.
        let items = (1...5).map { mail("id-\($0)", category: .school) }
        let first = MailTriagePolicy.triage(items).entries.map(\.item.id)
        let second = MailTriagePolicy.triage(items.reversed()).entries.map(\.item.id)
        XCTAssertEqual(first, second)
    }
}
