import XCTest
import DailyPlannerDomain
@testable import DailyPlannerGoogle

/// Drives the real URL builders through the real `GoogleNetworkPolicy`.
///
/// This is another untested seam of exactly the shape the calendar bug had. Every existing test
/// transport answers whatever request it is handed, but the shipped app talks through
/// `URLSessionGoogleHTTPTransport`, which calls `GoogleNetworkPolicy.validate` first. So a URL
/// the client builds but the policy refuses passes the entire suite and fails only against a
/// real account — and `mapCalendarError` turns the refusal into `.malformedResponse`, which
/// reads like a bad payload from Google rather than a request we declined to send ourselves.
final class GoogleCalendarPolicySeamTests: XCTestCase {
    /// Runs the real policy over every request, exactly as the live transport does, then answers
    /// with a caller-supplied body.
    private final class PolicyEnforcingTransport: GoogleHTTPTransport, @unchecked Sendable {
        private var responses: [Data]
        private(set) var sent: [URLRequest] = []
        init(_ responses: [Data]) { self.responses = responses }

        func send(_ request: URLRequest) async throws -> GoogleHTTPResponse {
            sent.append(request)
            try GoogleNetworkPolicy.validate(request)
            return GoogleHTTPResponse(statusCode: 200, data: responses.removeFirst())
        }
    }

    private struct FakeTokens: GoogleAccessTokenProviding {
        func accessToken() async throws -> GoogleAccessToken {
            try GoogleAccessToken(validating: "test-token")
        }
    }

    private var day: DateInterval {
        let start = ISO8601DateFormatter().date(from: "2026-09-16T07:00:00Z")!
        return DateInterval(start: start, duration: 24 * 60 * 60)
    }

    private func emptyPage() -> Data {
        try! JSONSerialization.data(withJSONObject: ["items": []])
    }

    /// The planning calendar on a personal account is the Gmail address itself.
    func testEventsRequestForAGmailCalendarIDSurvivesTheNetworkPolicy() async throws {
        let transport = PolicyEnforcingTransport([emptyPage()])
        let client = GoogleCalendarReadClient(transport: transport)

        _ = try await client.events(
            calendarID: CalendarID(rawValue: "calendar@example.test"),
            interval: day,
            syncToken: nil,
            pageToken: nil,
            accessToken: try FakeTokens().accessToken()
        )
    }

    /// Group and holiday calendars carry ids the personal address does not exercise.
    func testEventsRequestForGroupStyleCalendarIDsSurviveTheNetworkPolicy() async throws {
        let ids = [
            "abc123def456@group.calendar.google.com",
            "en.canadian#holiday@group.v.calendar.google.com",
        ]
        for id in ids {
            let transport = PolicyEnforcingTransport([emptyPage()])
            let client = GoogleCalendarReadClient(transport: transport)
            do {
                _ = try await client.events(
                    calendarID: CalendarID(rawValue: id),
                    interval: day,
                    syncToken: nil,
                    pageToken: nil,
                    accessToken: try FakeTokens().accessToken()
                )
            } catch {
                XCTFail("policy refused the request we build for calendar id shape \(id): \(error)")
            }
        }
    }

    /// The round trip that was broken: a padded sync token must survive being decoded from
    /// Google's response AND being sent back through the policy on the next request. Fixing only
    /// the decoder would move the failure one request later instead of removing it.
    func testAPaddedSyncTokenSurvivesBeingSentBackThroughThePolicy() async throws {
        let transport = PolicyEnforcingTransport([emptyPage()])
        let client = GoogleCalendarReadClient(transport: transport)
        let token = try CalendarSyncToken(validating: "CPjJi8yF2fMCEPjJi8yF2fMCGAUgtc_QoQI=")

        _ = try await client.events(
            calendarID: CalendarID(rawValue: "calendar@example.test"),
            interval: day,
            syncToken: token,
            pageToken: nil,
            accessToken: try FakeTokens().accessToken()
        )

        let sent = try XCTUnwrap(transport.sent.first?.url?.absoluteString)
        XCTAssertTrue(sent.contains("syncToken="), "the token must actually be on the request")
    }

    /// The calendar list request is the one that already works in the shipped app, so it acts as
    /// the control: if this also failed, the fault would be in the harness, not the seam.
    func testCalendarListRequestSurvivesTheNetworkPolicy() async throws {
        let body = try! JSONSerialization.data(withJSONObject: ["items": []])
        let transport = PolicyEnforcingTransport([body])
        let client = GoogleCalendarReadClient(transport: transport)
        _ = try await client.calendars(accessToken: try FakeTokens().accessToken())
    }
}
