import Foundation
import XCTest
import DailyPlannerDomain
@testable import DailyPlannerAPI

/// `GET /api/mail/body` and `POST /api/mail/summary`.
///
/// Reading a body is local; summarising one sends it. The test that matters most here is not
/// about either route: it is that wiring a body reader in changes NOTHING about what drafting
/// transmits. Being able to see more must not mean sending more.
final class MailBodyRouteTests: XCTestCase {
    private let token = "test-token-body"
    private let port: UInt16 = 51_236
    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    /// Text that exists ONLY in the body — never in the subject, sender or snippet — so its
    /// presence anywhere outbound proves the body leaked.
    private let bodyOnly = "BODY-ONLY-7f3a the room moved to AQ 3150"

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

    private final class FakeBodies: PlannerMailBodyReading, @unchecked Sendable {
        var bodies: [String: PlannerMailBody]
        var reads: [String] = []
        init(_ bodies: [String: PlannerMailBody]) { self.bodies = bodies }
        func body(for id: String) async throws -> PlannerMailBody {
            reads.append(id)
            guard let body = bodies[id] else { throw URLError(.fileDoesNotExist) }
            return body
        }
    }

    /// One object on both assistant ports, recording exactly what crossed each.
    private final class SpyAssistant: PlannerReplyDrafting, PlannerMailSummarizing, @unchecked Sendable {
        var drafted: [PlannerReplyRequest] = []
        var summarized: [PlannerSummaryRequest] = []
        var providerLabel: String { "Test assistant" }
        var contentLeavesMachine: Bool { true }
        func draft(_ request: PlannerReplyRequest) async throws -> PlannerProposedReply {
            drafted.append(request)
            return try PlannerProposedReply(body: "Sounds good.", provider: providerLabel)
        }
        func summarize(_ request: PlannerSummaryRequest) async throws -> PlannerMailSummary {
            summarized.append(request)
            return try PlannerMailSummary(text: "- Room change", provider: providerLabel)
        }
    }

    private func item(_ id: String) -> PlannerMailItem {
        PlannerMailItem(
            id: id, title: "ECONOMICS 250 room", summary: "Quick update about Thursday",
            sender: "prof@sfu.ca", receivedAt: referenceDate, category: .school,
            isPrivate: false, isUnread: true, threadID: "t-\(id)"
        )
    }

    private func body(_ id: String, text: String? = nil, isPrivate: Bool = false) -> PlannerMailBody {
        PlannerMailBody(
            id: id, subject: "ECONOMICS 250 room", sender: "prof@sfu.ca",
            text: text ?? bodyOnly, attachmentNames: ["slides.pdf"], isPrivate: isPrivate
        )
    }

    private func service(
        bodies: FakeBodies?,
        assistant: SpyAssistant? = nil,
        inbox: [PlannerMailItem] = []
    ) -> PlannerAPIService {
        PlannerAPIService(
            source: FakeSource(),
            settingsStore: FakeSettings(),
            clock: FixedTestClock(now: referenceDate),
            mailReader: FakeInbox(items: inbox),
            replyWriter: assistant,
            mailBodyReader: bodies,
            summarizer: assistant,
            capability: .readWrite
        )
    }

    private func router(_ service: PlannerAPIService) -> APIRouter {
        APIRouter(guardCheck: RequestGuard(token: token, port: port), service: service, assets: StaticWebAssets(root: nil))
    }

    private var headers: [String: String] {
        [
            "host": "127.0.0.1:\(port)",
            "origin": "http://127.0.0.1:\(port)",
            "content-type": "application/json",
            "authorization": "Bearer \(token)",
        ]
    }

    private func get(_ query: String?) -> HTTPRequest {
        HTTPRequest(method: "GET", path: "/api/mail/body", query: query, headers: headers)
    }

    private func post(_ path: String, _ json: String) -> HTTPRequest {
        HTTPRequest(method: "POST", path: path, query: nil, headers: headers, body: Data(json.utf8))
    }

    private func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func errorMessage(_ response: HTTPResponse) -> String? {
        (object(response.body)["error"] as? [String: Any])?["message"] as? String
    }

    // MARK: - THE privacy line

    func testDraftingSendsTheSnippetAndNeverTheBodyEvenWithABodyReaderWired() async {
        let bodies = FakeBodies(["m1": body("m1")])
        let assistant = SpyAssistant()
        let r = router(service(bodies: bodies, assistant: assistant, inbox: [item("m1")]))

        // He opens the message first, so the body is right there on screen…
        let read = await r.respond(to: get("id=m1"))
        XCTAssertEqual(read.status, 200)
        bodies.reads.removeAll()

        // …then drafts a reply.
        let drafted = await r.respond(to: post("/api/mail/draft", #"{"messageId":"m1","intent":"accept"}"#))
        XCTAssertEqual(drafted.status, 200)

        XCTAssertTrue(bodies.reads.isEmpty, "drafting must not even read the body")
        let sent = assistant.drafted.map(PlannerReplyPrompt.text(for:)).joined()
        XCTAssertTrue(sent.contains("Quick update about Thursday"), "the snippet is what drafting sends")
        XCTAssertFalse(sent.contains("BODY-ONLY-7f3a"), "the body must never reach a draft prompt")
        XCTAssertTrue(assistant.summarized.isEmpty, "drafting is not a summary")
    }

    func testReadingABodySendsNothingToTheAssistant() async {
        let assistant = SpyAssistant()
        _ = await router(service(bodies: FakeBodies(["m1": body("m1")]), assistant: assistant))
            .respond(to: get("id=m1"))
        XCTAssertTrue(assistant.drafted.isEmpty)
        XCTAssertTrue(assistant.summarized.isEmpty)
    }

    // MARK: - Reading

    func testTheBodyIsReturnedForDisplay() async {
        let response = await router(service(bodies: FakeBodies(["m 1": body("m 1")])))
            .respond(to: get("id=m%201"))
        XCTAssertEqual(response.status, 200)
        let json = object(response.body)
        XCTAssertEqual(json["text"] as? String, bodyOnly)
        XCTAssertEqual(json["attachments"] as? [String], ["slides.pdf"])
        XCTAssertEqual(json["truncated"] as? Bool, false)
        XCTAssertTrue(json["unreadable"] is NSNull || json["unreadable"] == nil)
    }

    func testAWithheldBodySaysWhyInsteadOfShowingNothing() async {
        let response = await router(service(bodies: FakeBodies(["m1": body("m1", isPrivate: true)])))
            .respond(to: get("id=m1"))
        let json = object(response.body)
        XCTAssertTrue(json["text"] is NSNull || json["text"] == nil)
        XCTAssertEqual(json["unreadable"] as? String, "This message could not be read safely, so its body is not shown.")
    }

    func testAMissingIdIsABadRequestAndNoReaderIsNotFound() async {
        let missing = await router(service(bodies: FakeBodies([:]))).respond(to: get(nil))
        XCTAssertEqual(missing.status, 400)
        let none = await router(service(bodies: nil)).respond(to: get("id=m1"))
        XCTAssertEqual(none.status, 404)
    }

    func testAFailedReadIsAFiniteUnavailableThatNamesNothing() async {
        let response = await router(service(bodies: FakeBodies([:]))).respond(to: get("id=nope"))
        XCTAssertEqual(response.status, 503)
        XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("nope"))
    }

    func testReadingNeedsTheToken() async {
        let request = HTTPRequest(
            method: "GET", path: "/api/mail/body", query: "id=m1",
            headers: headers.filter { $0.key != "authorization" }
        )
        let response = await router(service(bodies: FakeBodies(["m1": body("m1")]))).respond(to: request)
        XCTAssertEqual(response.status, 401)
    }

    // MARK: - Summarising

    func testSummarySendsTheEnginesOwnCopyOfTheBody() async {
        let assistant = SpyAssistant()
        let response = await router(service(bodies: FakeBodies(["m1": body("m1")]), assistant: assistant))
            .respond(to: post("/api/mail/summary", #"{"messageId":"m1","body":"INJECTED"}"#))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(object(response.body)["summary"] as? String, "- Room change")
        XCTAssertEqual(assistant.summarized.map(\.body), [bodyOnly])
        XCTAssertFalse(assistant.summarized.map(PlannerSummaryPrompt.text(for:)).joined().contains("INJECTED"))
    }

    func testSummaryRefusesAPrivateBody() async {
        let assistant = SpyAssistant()
        let response = await router(service(bodies: FakeBodies(["m1": body("m1", isPrivate: true)]), assistant: assistant))
            .respond(to: post("/api/mail/summary", #"{"messageId":"m1"}"#))
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(assistant.summarized.isEmpty)
    }

    func testSummaryRefusesABodyThatLooksLikeItHoldsACredential() async {
        let assistant = SpyAssistant()
        let secret = body("m1", text: "Your verification code is 482913. Do not share your password.")
        let response = await router(service(bodies: FakeBodies(["m1": secret]), assistant: assistant))
            .respond(to: post("/api/mail/summary", #"{"messageId":"m1"}"#))
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(assistant.summarized.isEmpty, "a code must not be sent to a model")
        XCTAssertEqual(
            errorMessage(response),
            "That message looks like it holds a code, a password or an account detail, so it is not sent to an assistant."
        )
    }

    func testSummaryIsGatedLikeAWriteAndAbsentWithoutAnAssistant() async {
        let noAssistant = await router(service(bodies: FakeBodies(["m1": body("m1")])))
            .respond(to: post("/api/mail/summary", #"{"messageId":"m1"}"#))
        XCTAssertEqual(noAssistant.status, 403)

        let getOnWriteRoute = await router(service(bodies: FakeBodies(["m1": body("m1")]), assistant: SpyAssistant()))
            .respond(to: HTTPRequest(method: "GET", path: "/api/mail/summary", query: nil, headers: headers))
        XCTAssertEqual(getOnWriteRoute.status, 405)
    }

    func testCapabilityReportsReadingAndSummarisingFromWhatWasBuilt() {
        let both = object(service(bodies: FakeBodies([:]), assistant: SpyAssistant()).settingsPayload())
        let capability = both["capability"] as? [String: Any]
        XCTAssertEqual(capability?["canReadBody"] as? Bool, true)
        XCTAssertEqual(capability?["canSummarize"] as? Bool, true)

        let readOnly = object(service(bodies: FakeBodies([:])).settingsPayload())["capability"] as? [String: Any]
        XCTAssertEqual(readOnly?["canReadBody"] as? Bool, true)
        XCTAssertEqual(readOnly?["canSummarize"] as? Bool, false)
    }
}
