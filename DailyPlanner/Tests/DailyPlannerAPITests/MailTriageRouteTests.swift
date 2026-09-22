import Foundation
import XCTest
import DailyPlannerDomain
@testable import DailyPlannerAPI

/// `/api/drafts` against a real inbox.
///
/// This route had no test on the live path at all — the only coverage was the synthetic
/// fallback — and it is the one Digest reads to decide what Braxton sees first. What is pinned
/// here is that the RANKING happens in the engine: two surfaces consume this list, and a rank
/// each of them re-derives is one that will eventually disagree with itself.
final class MailTriageRouteTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    private struct FakeSource: CalendarCatalogReading, PlanningCalendarReading, Sendable {
        func calendars() async throws -> [CalendarDescriptor] { [] }
        func planningEvents(calendarIDs: Set<CalendarID>, interval: DateInterval) async throws -> [PlannerEvent] { [] }
    }

    private struct FakeSettings: PrivateSettingsStore, Sendable {
        func load() throws -> PrivateSettings { .empty }
        func replace(_ settings: PrivateSettings) throws {}
    }

    private struct FixedTestClock: PlannerClock, Sendable { let now: Date }

    private struct FakeInbox: PlannerMailReading, Sendable {
        let items: [PlannerMailItem]
        func mailItems(limit: Int) async throws -> [PlannerMailItem] { Array(items.prefix(limit)) }
    }

    /// An inbox that cannot be read at all. The surface must still answer.
    private struct BrokenInbox: PlannerMailReading, Sendable {
        struct Failure: Error {}
        func mailItems(limit: Int) async throws -> [PlannerMailItem] { throw Failure() }
    }

    private func mail(
        _ id: String,
        title: String = "Subject",
        category: PlannerCategory = .other,
        minutesAgo: Int = 0,
        isUnread: Bool = true,
        isBulk: Bool = false
    ) -> PlannerMailItem {
        PlannerMailItem(
            id: id,
            title: title,
            summary: "snippet",
            sender: "someone@example.com",
            receivedAt: referenceDate.addingTimeInterval(TimeInterval(-minutesAgo * 60)),
            category: category,
            isPrivate: false,
            isUnread: isUnread,
            isBulk: isBulk,
            threadID: "t-\(id)"
        )
    }

    private func service(inbox: any PlannerMailReading) -> PlannerAPIService {
        PlannerAPIService(
            source: FakeSource(),
            settingsStore: FakeSettings(),
            clock: FixedTestClock(now: referenceDate),
            mailReader: inbox
        )
    }

    private func payload(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func testTheListArrivesAlreadyRanked() async {
        // Break caught: the engine hands over arrival order and leaves ranking to whichever
        // surface happens to do it. The newest message here is `other`; school must lead.
        let inbox = FakeInbox(items: [
            mail("promo-noise", minutesAgo: 1, isBulk: true),
            mail("personal", category: .personal, minutesAgo: 2),
            mail("school", category: .school, minutesAgo: 900),
            mail("urgent", title: "Security alert", category: .other, minutesAgo: 4_000),
            mail("career", category: .career, minutesAgo: 30),
        ])
        let body = payload(await service(inbox: inbox).drafts())
        let drafts = body["drafts"] as? [[String: Any]] ?? []

        XCTAssertEqual(
            drafts.map { $0["id"] as? String },
            ["urgent", "school", "career", "personal"]
        )
        // The promotion is not last — it is not there, and the count says so.
        XCTAssertEqual(body["hiddenCount"] as? Int, 1)
    }

    func testEveryRowCanSayWhyItIsWhereItIs() async {
        let inbox = FakeInbox(items: [
            mail("a", title: "Action required now", category: .other),
            mail("b", category: .school),
        ])
        let drafts = payload(await service(inbox: inbox).drafts())["drafts"] as? [[String: Any]] ?? []

        XCTAssertEqual(drafts[0]["band"] as? String, "urgent")
        XCTAssertEqual(drafts[0]["reason"] as? String, "deadline")
        XCTAssertTrue((drafts[0]["why"] as? String ?? "").contains("action required"))

        XCTAssertEqual(drafts[1]["band"] as? String, "ordinary")
        XCTAssertEqual(drafts[1]["reason"] as? String, "category")
        XCTAssertEqual(drafts[1]["why"] as? String, "School")
        XCTAssertEqual(drafts[1]["unread"] as? Bool, true)
    }

    func testTheThreadStillSurvivesTheRanking() async {
        // Break caught: reordering drops the thread id, so a reply composed from a triaged row
        // starts a new conversation beside the one it answers. That bug has shipped here once.
        let inbox = FakeInbox(items: [mail("a", category: .school)])
        let drafts = payload(await service(inbox: inbox).drafts())["drafts"] as? [[String: Any]] ?? []
        XCTAssertEqual(drafts.first?["threadId"] as? String, "t-a")
    }

    func testAnUnreadableInboxFallsBackRatherThanEmptyingTheSurface() async {
        // The day stays usable when only mail is unavailable.
        let body = payload(await service(inbox: BrokenInbox()).drafts())
        XCTAssertFalse((body["drafts"] as? [[String: Any]] ?? []).isEmpty)
        XCTAssertEqual(body["hiddenCount"] as? Int, 0)
    }
}
