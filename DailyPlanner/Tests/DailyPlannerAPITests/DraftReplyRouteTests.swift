import Foundation
import XCTest
import DailyPlannerDomain
@testable import DailyPlannerAPI

/// `/api/mail/draft`.
///
/// The route sends the user's own content off the machine, which nothing else in this engine
/// does. What is pinned here is mostly what it REFUSES, and in particular that the private-mail
/// rule is enforced against the engine's own copy of the message rather than against anything
/// the client said about it.
final class DraftReplyRouteTests: XCTestCase {
    private let token = "test-token-abc123"
    private let port: UInt16 = 51_235
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
        func mailItems(limit: Int) async throws -> [PlannerMailItem] { items }
    }

    /// Records what it was asked to draft, so the test can assert what actually crossed the
    /// boundary — which is the only thing that matters on this route.
    private final class SpyWriter: PlannerReplyDrafting, @unchecked Sendable {
        var seen: [PlannerReplyRequest] = []
        var failure: (any Error)?
        var providerLabel: String { "Test assistant" }
        var contentLeavesMachine: Bool { true }

        func draft(_ request: PlannerReplyRequest) async throws -> PlannerProposedReply {
            if let failure { throw failure }
            seen.append(request)
            return try PlannerProposedReply(body: "Thanks, that works.", provider: providerLabel)
        }
    }

    private struct LocalWriter: PlannerReplyDrafting, Sendable {
        var providerLabel: String { "Local model" }
        var contentLeavesMachine: Bool { false }
        func draft(_ request: PlannerReplyRequest) async throws -> PlannerProposedReply {
            try PlannerProposedReply(body: "ok", provider: providerLabel)
        }
    }

    private func mail(_ id: String, isPrivate: Bool = false) -> PlannerMailItem {
        PlannerMailItem(
            id: id,
            title: "Interview Thursday",
            summary: isPrivate ? "Hidden — this message is marked private." : "Can you do 14:30?",
            sender: "recruiter@example.com",
            receivedAt: referenceDate,
            category: .career,
            isPrivate: isPrivate,
            isUnread: true,
            threadID: "t-\(id)"
        )
    }

    private func service(
        inbox: [PlannerMailItem] = [],
        writer: (any PlannerReplyDrafting)? = nil
    ) -> PlannerAPIService {
        PlannerAPIService(
            source: FakeSource(),
            settingsStore: FakeSettings(),
            clock: FixedTestClock(now: referenceDate),
            mailReader: FakeInbox(items: inbox),
            replyWriter: writer,
            capability: .readWrite
        )
    }

    private func router(_ service: PlannerAPIService) -> APIRouter {
        APIRouter(
            guardCheck: RequestGuard(token: token, port: port),
            service: service,
            assets: StaticWebAssets(root: nil)
        )
    }

    private func post(_ json: String) -> HTTPRequest {
        HTTPRequest(
            method: "POST",
            path: "/api/mail/draft",
            query: nil,
            headers: [
                "host": "127.0.0.1:\(port)",
                "origin": "http://127.0.0.1:\(port)",
                "content-type": "application/json",
                "authorization": "Bearer \(token)",
            ],
            body: Data(json.utf8)
        )
    }

    private func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func errorCode(_ response: HTTPResponse) -> String? {
        (object(response.body)["error"] as? [String: Any])?["code"] as? String
    }

    // MARK: - The refusals

    func testAPrivateMessageIsNeverSentToTheAssistant() async {
        // THE test on this route. The message's content is withheld from the screen; sending it
        // to a model would be the stricter promise broken more quietly. Note the client asks
        // for it perfectly normally — the refusal comes from the engine's own copy.
        let writer = SpyWriter()
        let response = await router(service(inbox: [mail("m1", isPrivate: true)], writer: writer))
            .respond(to: post(#"{"messageId":"m1","intent":"accept"}"#))

        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(writer.seen.isEmpty, "nothing may reach the assistant")
        let message = (object(response.body)["error"] as? [String: Any])?["message"] as? String
        XCTAssertEqual(
            message,
            "That message is marked private, so its content is never sent to an assistant."
        )
    }

    func testTheClientCannotSupplyContentAtAll() async {
        // The request has no field for message text: extra keys are ignored, and the prompt is
        // built from the inbox. So a client cannot smuggle anything to a model even on purpose.
        let writer = SpyWriter()
        _ = await router(service(inbox: [mail("m1")], writer: writer)).respond(
            to: post(#"""
            {"messageId":"m1","intent":"accept",
             "subject":"INJECTED","snippet":"INJECTED","body":"INJECTED"}
            """#)
        )
        let seen = writer.seen.first
        XCTAssertEqual(seen?.subject, "Interview Thursday")
        XCTAssertEqual(seen?.snippet, "Can you do 14:30?")
    }

    func testAnUnknownIntentIsRefused() async {
        let writer = SpyWriter()
        let response = await router(service(inbox: [mail("m1")], writer: writer))
            .respond(to: post(#"{"messageId":"m1","intent":"exfiltrate"}"#))
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(writer.seen.isEmpty)
    }

    func testAMessageNotInTheListIsOneFiniteRefusal() async {
        // Deliberately the same answer whether the id is unknown or the inbox failed. This
        // route does not answer probes about which message ids exist.
        let response = await router(service(inbox: [mail("m1")], writer: SpyWriter()))
            .respond(to: post(#"{"messageId":"other","intent":"accept"}"#))
        XCTAssertEqual(response.status, 400)
        let message = (object(response.body)["error"] as? [String: Any])?["message"] as? String
        XCTAssertEqual(message, "That message is no longer in the list.")
    }

    func testNoAssistantMeansTheRouteIsNotPermitted() async {
        // Structural: there is no writer to call, so this cannot be turned on with a flag.
        let response = await router(service(inbox: [mail("m1")], writer: nil))
            .respond(to: post(#"{"messageId":"m1","intent":"accept"}"#))
        XCTAssertEqual(response.status, 403)
        XCTAssertEqual(errorCode(response), "write_not_permitted")
    }

    // MARK: - The happy path, and what it reports

    func testAProposalComesBackAndNothingIsSent() async {
        let writer = SpyWriter()
        let response = await router(service(inbox: [mail("m1")], writer: writer))
            .respond(to: post(#"{"messageId":"m1","intent":"reschedule"}"#))

        XCTAssertEqual(response.status, 200)
        let payload = object(response.body)
        XCTAssertEqual(payload["body"] as? String, "Thanks, that works.")
        XCTAssertEqual(payload["provider"] as? String, "Test assistant")
        XCTAssertEqual(writer.seen.first?.intent, .reschedule)
    }

    func testAnAssistantFailureIsReportedWithoutLosingTheComposer() async {
        let writer = SpyWriter()
        writer.failure = PlannerDraftingError.unavailable
        let response = await router(service(inbox: [mail("m1")], writer: writer))
            .respond(to: post(#"{"messageId":"m1","intent":"accept"}"#))
        // Not a 500: the user can still write the reply themselves.
        XCTAssertEqual(response.status, 503)
        XCTAssertEqual(errorCode(response), "unavailable")
    }

    // MARK: - What the rail is told

    func testSettingsReportsTheProviderAndWhetherContentLeaves() {
        // Break caught: the rail says content stays local while it is being shipped to a
        // subscription, or says nothing at all. Read off the provider, never assumed.
        let remote = object(service(writer: SpyWriter()).settingsPayload())
        let assist = remote["assist"] as? [String: Any]
        XCTAssertEqual(assist?["enabled"] as? Bool, true)
        XCTAssertEqual(assist?["provider"] as? String, "Test assistant")
        XCTAssertEqual(assist?["contentLeavesMachine"] as? Bool, true)
        XCTAssertTrue((assist?["label"] as? String ?? "").contains("leaves this Mac"))
        XCTAssertEqual((remote["capability"] as? [String: Any])?["canDraft"] as? Bool, true)

        // A local model answers false, and the label changes on its own.
        let local = object(service(writer: LocalWriter()).settingsPayload())
        let localAssist = local["assist"] as? [String: Any]
        XCTAssertEqual(localAssist?["contentLeavesMachine"] as? Bool, false)
        XCTAssertTrue((localAssist?["label"] as? String ?? "").contains("stays on this Mac"))

        // None wired: off, and the UI shows no offer.
        let none = object(service().settingsPayload())
        XCTAssertEqual((none["assist"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertEqual((none["capability"] as? [String: Any])?["canDraft"] as? Bool, false)
    }

    func testDraftingIsGatedLikeAWriteEvenThoughItWritesNothing() async {
        // It changes nothing in the account, but it transmits the user's content, so it goes
        // through the same guard: no token, no draft.
        var request = post(#"{"messageId":"m1","intent":"accept"}"#)
        request = HTTPRequest(
            method: request.method, path: request.path, query: nil,
            headers: request.headers.filter { $0.key != "authorization" },
            body: request.body
        )
        let response = await router(service(inbox: [mail("m1")], writer: SpyWriter()))
            .respond(to: request)
        XCTAssertEqual(response.status, 401)
    }
}
