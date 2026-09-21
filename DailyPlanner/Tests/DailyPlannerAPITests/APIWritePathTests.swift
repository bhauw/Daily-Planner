import Foundation
import XCTest
import DailyPlannerDomain
@testable import DailyPlannerAPI

/// The write path, from the gate down to what comes back.
///
/// The read-only engine could be wrong in ways that showed up as a blank screen. This one can be
/// wrong in ways that send someone's mail to the wrong place, or that send it twice, so the
/// tests here are about refusals as much as successes: who may POST, what happens when the grant
/// does not allow it, and what the user is told when Google says no.
final class APIWritePathTests: XCTestCase {
    private let token = "test-token-abc123"
    private let port: UInt16 = 51_234
    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Fakes

    private struct FakeSource: CalendarCatalogReading, PlanningCalendarReading, Sendable {
        func calendars() async throws -> [CalendarDescriptor] { [] }
        func planningEvents(calendarIDs: Set<CalendarID>, interval: DateInterval) async throws -> [PlannerEvent] { [] }
    }

    private struct FakeSettings: PrivateSettingsStore, Sendable {
        func load() throws -> PrivateSettings { .empty }
        func replace(_ settings: PrivateSettings) throws {}
    }

    private struct FixedTestClock: PlannerClock, Sendable {
        let now: Date
    }

    /// Records what it was asked to send so the test can assert the message actually crossed the
    /// boundary intact, and can be told to fail in a specific, finite way.
    private final class SpySender: PlannerMailSending, @unchecked Sendable {
        var sent: [PlannerOutgoingMail] = []
        var failure: (any Error)?

        func send(_ mail: PlannerOutgoingMail) async throws -> PlannerSentMail {
            if let failure { throw failure }
            sent.append(mail)
            return PlannerSentMail(id: "msg-1", threadID: "thread-1")
        }
    }

    private final class SpyScheduler: PlannerEventScheduling, @unchecked Sendable {
        var created: [PlannerEventDraft] = []
        var failure: (any Error)?

        func create(_ draft: PlannerEventDraft) async throws -> PlannerScheduledEvent {
            if let failure { throw failure }
            created.append(draft)
            return PlannerScheduledEvent(id: "evt-1", start: draft.start, end: draft.end, link: "https://example.test/e")
        }
    }

    private struct StubFailure: Error, PlannerWriteFailure {
        let writeOutcome: PlannerWriteOutcome
    }

    // MARK: - Helpers

    private func service(
        sender: (any PlannerMailSending)? = nil,
        scheduler: (any PlannerEventScheduling)? = nil,
        capability: GoogleGrantedCapability? = nil
    ) -> PlannerAPIService {
        PlannerAPIService(
            source: FakeSource(),
            settingsStore: FakeSettings(),
            clock: FixedTestClock(now: referenceDate),
            mailSender: sender,
            eventScheduler: scheduler,
            capability: capability
        )
    }

    private func router(_ service: PlannerAPIService) -> APIRouter {
        APIRouter(
            guardCheck: RequestGuard(token: token, port: port),
            service: service,
            assets: StaticWebAssets(root: nil)
        )
    }

    private func post(
        _ path: String,
        json: String,
        origin: String? = nil,
        contentType: String? = "application/json",
        withToken: Bool = true
    ) -> HTTPRequest {
        var headers = ["host": "127.0.0.1:\(port)"]
        headers["origin"] = origin ?? "http://127.0.0.1:\(port)"
        if let contentType { headers["content-type"] = contentType }
        if withToken { headers["authorization"] = "Bearer \(token)" }
        return HTTPRequest(
            method: "POST", path: path, query: nil, headers: headers, body: Data(json.utf8)
        )
    }

    private func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func errorCode(_ response: HTTPResponse) -> String? {
        ((object(response.body)["error"] as? [String: Any])?["code"]) as? String
    }

    private let validMail = #"{"to":["friend@example.com"],"subject":"Lunch","body":"Thursday?"}"#
    private let validEvent = """
    {"title":"Study block","start":"2026-09-16T09:00:00-07:00","end":"2026-09-16T10:30:00-07:00"}
    """

    // MARK: - The gate

    func testWriteRouteRequiresAnOriginEvenThoughAReadDoesNot() async {
        // Break caught: the "Origin when present" rule is left in place for POST. A page on
        // another origin can make a browser issue a cross-site POST; the browser always attaches
        // Origin to it, so REQUIRING the header is what makes a drive-by write fail. Accepting a
        // missing one leaves exactly the hole the token is there to close.
        let sender = SpySender()
        var headers = ["host": "127.0.0.1:\(port)", "content-type": "application/json", "authorization": "Bearer \(token)"]
        headers.removeValue(forKey: "origin")
        let response = await router(service(sender: sender, capability: .readWrite))
            .respond(to: HTTPRequest(method: "POST", path: "/api/mail/send", query: nil, headers: headers, body: Data(validMail.utf8)))

        XCTAssertEqual(response.status, 401)
        XCTAssertTrue(sender.sent.isEmpty, "nothing may be sent by a request the gate refused")
    }

    func testForeignOriginIsRefused() async {
        let sender = SpySender()
        let response = await router(service(sender: sender, capability: .readWrite))
            .respond(to: post("/api/mail/send", json: validMail, origin: "https://evil.example"))
        XCTAssertEqual(response.status, 401)
        XCTAssertTrue(sender.sent.isEmpty)
    }

    func testFormContentTypesAreRefused() async {
        // Break caught: a content type an HTML form can send is accepted. These three are the
        // only ones a cross-site form can produce without a CORS preflight, so refusing them
        // means a cross-site write cannot even be expressed.
        let sender = SpySender()
        for type in ["application/x-www-form-urlencoded", "multipart/form-data", "text/plain"] {
            let response = await router(service(sender: sender, capability: .readWrite))
                .respond(to: post("/api/mail/send", json: validMail, contentType: type))
            XCTAssertEqual(response.status, 415, "\(type) must not be accepted on a write")
        }
        XCTAssertTrue(sender.sent.isEmpty)
    }

    func testWriteRouteStillRequiresTheBearerToken() async {
        let sender = SpySender()
        let response = await router(service(sender: sender, capability: .readWrite))
            .respond(to: post("/api/mail/send", json: validMail, withToken: false))
        XCTAssertEqual(response.status, 401)
        XCTAssertTrue(sender.sent.isEmpty)
    }

    func testVerbAndPathMustAgree() async {
        // Break caught: a write route answers a GET, or a read route answers a POST.
        let service = service(sender: SpySender(), capability: .readWrite)
        let get = HTTPRequest(
            method: "GET", path: "/api/mail/send", query: nil,
            headers: ["host": "127.0.0.1:\(port)", "authorization": "Bearer \(token)"]
        )
        await XCTAssertEqualAsync(await router(service).respond(to: get).status, 405)
        await XCTAssertEqualAsync(await router(service).respond(to: post("/api/preview", json: "{}")).status, 405)
    }

    // MARK: - Capability

    func testReadOnlyGrantCannotSendOrSchedule() async {
        // Break caught: the write routes answer for an account connected before send/schedule
        // shipped. There is no sender at all for such a grant, so this cannot be flipped on by
        // a flag somewhere — and the message tells the user what to do about it.
        let router = router(service(capability: .readOnly))

        let send = await router.respond(to: post("/api/mail/send", json: validMail))
        XCTAssertEqual(send.status, 403)
        XCTAssertEqual(errorCode(send), "write_not_permitted")

        let schedule = await router.respond(to: post("/api/calendar/events", json: validEvent))
        XCTAssertEqual(schedule.status, 403)
        XCTAssertEqual(errorCode(schedule), "write_not_permitted")
    }

    func testSampleDataCannotWriteAnywhere() async {
        // Break caught: the synthetic service grows a write path. There is nothing to write to.
        let router = APIRouter(
            guardCheck: RequestGuard(token: token, port: port),
            service: PlannerAPIService(referenceDate: referenceDate),
            assets: StaticWebAssets(root: nil)
        )
        let response = await router.respond(to: post("/api/mail/send", json: validMail))
        XCTAssertEqual(response.status, 403)
    }

    func testSettingsReportsTheCapabilityAndTheSafetyModeTogether() {
        // Break caught: the safety rail keeps promising "no external writes" on a connection that
        // can send. That label is the line the user relies on to know what this app can do with
        // their account; it has to follow the grant, in both directions.
        let writable = object(service(sender: SpySender(), scheduler: SpyScheduler(), capability: .readWrite).settingsPayload())
        XCTAssertEqual((writable["safety"] as? [String: Any])?["mode"] as? String, "send-and-schedule")
        XCTAssertEqual((writable["safety"] as? [String: Any])?["externalWrites"] as? Bool, true)
        XCTAssertEqual((writable["capability"] as? [String: Any])?["canSend"] as? Bool, true)
        XCTAssertEqual((writable["capability"] as? [String: Any])?["canSchedule"] as? Bool, true)

        let readOnly = object(service(capability: .readOnly).settingsPayload())
        XCTAssertEqual((readOnly["safety"] as? [String: Any])?["mode"] as? String, "read-only")
        XCTAssertEqual((readOnly["safety"] as? [String: Any])?["externalWrites"] as? Bool, false)
        XCTAssertEqual((readOnly["capability"] as? [String: Any])?["canSend"] as? Bool, false)

        let sample = object(PlannerAPIService(referenceDate: referenceDate).settingsPayload())
        XCTAssertEqual((sample["safety"] as? [String: Any])?["mode"] as? String, "read-only")
    }

    func testCapabilityFollowsWhatWasBuiltNotWhatWasStored() {
        // Break caught: the UI is told it can send because the stored grant says so, while no
        // sender was actually constructed. The button must follow the thing that does the work.
        let payload = object(service(sender: nil, scheduler: SpyScheduler(), capability: .readWrite).settingsPayload())
        XCTAssertEqual((payload["capability"] as? [String: Any])?["canSend"] as? Bool, false)
        XCTAssertEqual((payload["capability"] as? [String: Any])?["canSchedule"] as? Bool, true)
    }

    // MARK: - Sending

    func testSendReachesTheSenderIntactAndReportsTheProviderIdentity() async throws {
        let sender = SpySender()
        let response = await router(service(sender: sender, capability: .readWrite))
            .respond(to: post("/api/mail/send", json: #"""
            {"to":["friend@example.com"],"cc":["cc@example.com"],"subject":"Lunch","body":"Thursday?","threadId":"t-9"}
            """#))

        XCTAssertEqual(response.status, 200)
        let mail = try XCTUnwrap(sender.sent.first)
        XCTAssertEqual(mail.to.map(\.value), ["friend@example.com"])
        XCTAssertEqual(mail.cc.map(\.value), ["cc@example.com"])
        XCTAssertEqual(mail.subject, "Lunch")
        XCTAssertEqual(mail.body, "Thursday?")
        XCTAssertEqual(mail.threadID, "t-9")

        let payload = object(response.body)
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["id"] as? String, "msg-1")
        XCTAssertEqual(payload["threadId"] as? String, "thread-1")
    }

    func testInvalidMessagesAreRefusedBeforeAnythingIsSent() async {
        // Break caught: validation is skipped, or its message quotes back what the user typed.
        // Each case here is one the composer can actually produce.
        let cases: [(String, String)] = [
            (#"{"to":[],"subject":"Hi","body":"x"}"#, "no recipient"),
            (#"{"to":["not-an-address"],"subject":"Hi","body":"x"}"#, "malformed recipient"),
            (#"{"to":["a@b.com"],"subject":"  ","body":"x"}"#, "empty subject"),
            (#"{"to":["a@b.com"],"subject":"Hi","body":"   "}"#, "empty body"),
            (#"{"subject":"Hi","body":"x"}"#, "no `to` key at all"),
        ]
        for (json, why) in cases {
            let sender = SpySender()
            let response = await router(service(sender: sender, capability: .readWrite))
                .respond(to: post("/api/mail/send", json: json))
            XCTAssertEqual(response.status, 400, "\(why) must be refused")
            XCTAssertEqual(errorCode(response), "invalid_request", "\(why)")
            XCTAssertTrue(sender.sent.isEmpty, "\(why) must not reach the sender")
        }
    }

    func testHeaderInjectionIsRefusedAtTheRoute() async {
        // Break caught: a newline in an address or subject reaches the message builder, where it
        // would end one header and begin another the user never wrote.
        for json in [
            #"{"to":["a@b.com\r\nBcc: everyone@example.com"],"subject":"Hi","body":"x"}"#,
            #"{"to":["a@b.com"],"subject":"Hi\r\nBcc: everyone@example.com","body":"x"}"#,
        ] {
            let sender = SpySender()
            let response = await router(service(sender: sender, capability: .readWrite))
                .respond(to: post("/api/mail/send", json: json))
            XCTAssertEqual(response.status, 400)
            XCTAssertTrue(sender.sent.isEmpty)
        }
    }

    func testProviderRefusalAndOutageAreReportedDifferently() async {
        // Break caught: "Google said no, fix it" and "we could not reach Google, try later" are
        // collapsed into one message. They call for opposite actions from the user.
        let refusing = SpySender()
        refusing.failure = StubFailure(writeOutcome: .refused)
        let refused = await router(service(sender: refusing, capability: .readWrite))
            .respond(to: post("/api/mail/send", json: validMail))
        XCTAssertEqual(refused.status, 502)
        XCTAssertEqual(errorCode(refused), "provider_refused")

        let offline = SpySender()
        offline.failure = StubFailure(writeOutcome: .unavailable)
        let unavailable = await router(service(sender: offline, capability: .readWrite))
            .respond(to: post("/api/mail/send", json: validMail))
        XCTAssertEqual(unavailable.status, 503)
        XCTAssertEqual(errorCode(unavailable), "unavailable")
    }

    // MARK: - Scheduling

    func testEventReachesTheSchedulerAndEchoesTheStoredTimes() async throws {
        let scheduler = SpyScheduler()
        let response = await router(service(scheduler: scheduler, capability: .readWrite))
            .respond(to: post("/api/calendar/events", json: """
            {"title":"Study block","start":"2026-09-16T09:00:00-07:00","end":"2026-09-16T10:30:00-07:00","location":"Library"}
            """))

        XCTAssertEqual(response.status, 200)
        let draft = try XCTUnwrap(scheduler.created.first)
        XCTAssertEqual(draft.title, "Study block")
        XCTAssertEqual(draft.location, "Library")
        XCTAssertEqual(draft.end.timeIntervalSince(draft.start), 90 * 60)

        let payload = object(response.body)
        XCTAssertEqual(payload["id"] as? String, "evt-1")
        XCTAssertEqual(payload["start"] as? String, "2026-09-16T09:00:00-07:00")
        XCTAssertEqual(payload["htmlLink"] as? String, "https://example.test/e")
    }

    func testEventsWithImpossibleIntervalsAreRefused() async {
        // Break caught: an end before its start, or a mistyped year, is written to a real
        // calendar. The second is the one that matters — "2062" is one keystroke from "2026".
        let cases = [
            #"{"title":"x","start":"2026-09-16T10:00:00-07:00","end":"2026-09-16T09:00:00-07:00"}"#,
            #"{"title":"x","start":"2026-09-16T10:00:00-07:00","end":"2026-09-16T10:00:00-07:00"}"#,
            #"{"title":"x","start":"2026-09-16T10:00:00-07:00","end":"2062-09-16T10:00:00-07:00"}"#,
            #"{"title":"  ","start":"2026-09-16T09:00:00-07:00","end":"2026-09-16T10:00:00-07:00"}"#,
            #"{"title":"x","start":"not-a-date","end":"2026-09-16T10:00:00-07:00"}"#,
        ]
        for json in cases {
            let scheduler = SpyScheduler()
            let response = await router(service(scheduler: scheduler, capability: .readWrite))
                .respond(to: post("/api/calendar/events", json: json))
            XCTAssertEqual(response.status, 400, "must refuse: \(json)")
            XCTAssertTrue(scheduler.created.isEmpty)
        }
    }

    func testUndecodableBodyIsOneFiniteRefusal() async {
        // Break caught: a decoding error's description reaches the client. `DecodingError` quotes
        // the offending value back, and here that value is someone's mail.
        let sender = SpySender()
        let response = await router(service(sender: sender, capability: .readWrite))
            .respond(to: post("/api/mail/send", json: "{not json"))
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(errorCode(response), "invalid_request")
        let message = (object(response.body)["error"] as? [String: Any])?["message"] as? String
        XCTAssertEqual(message, "That message could not be read.")
    }
}

/// `XCTAssertEqual` does not accept an `await` in its autoclosure on this toolchain.
private func XCTAssertEqualAsync<T: Equatable>(
    _ expression1: @autoclosure () async throws -> T,
    _ expression2: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async rethrows {
    let lhs = try await expression1()
    let rhs = try await expression2()
    XCTAssertEqual(lhs, rhs, file: file, line: line)
}
