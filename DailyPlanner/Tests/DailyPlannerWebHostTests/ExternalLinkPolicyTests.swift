import Foundation
import XCTest
@testable import DailyPlannerWebHost

/// Which links leave the app.
///
/// These exist because the opposite failure shipped: with no `WKUIDelegate` at all, WKWebView
/// discarded every `window.open` silently, so every external action in the UI — "Open in
/// Calendar", "Find in Gmail", "Open in Tasks", the post-schedule "Open in Google Calendar", and
/// the Gmail fallbacks meant for grants that cannot write — did nothing in the signed app while
/// working correctly in a browser. No error, no log line; the buttons were simply dead.
final class ExternalLinkPolicyTests: XCTestCase {
    private let appOrigin = URL(string: "http://127.0.0.1:54075/")!

    private func decide(_ raw: String) -> ExternalLinkDecision {
        ExternalLinkPolicy.decide(url: URL(string: raw), appOrigin: appOrigin)
    }

    func testGoogleDestinationsOpenInTheSystemBrowser() {
        XCTAssertEqual(decide("https://calendar.google.com/calendar/r/day/2026/9/21"), .openInSystemBrowser)
        XCTAssertEqual(decide("https://mail.google.com/mail/u/0/#search/midterm"), .openInSystemBrowser)
        XCTAssertEqual(decide("https://tasks.google.com/"), .openInSystemBrowser)
    }

    func testTheAppsOwnRoutesStayInTheWebView() {
        // Opened in Safari these would render a dead shell: the bearer token is injected into
        // this web view only, so the page would load and then fail every request.
        XCTAssertEqual(decide("http://127.0.0.1:54075/focus"), .keepInWebView)
        XCTAssertEqual(decide("http://127.0.0.1:54075/"), .keepInWebView)
    }

    func testSchemesThatAreNotWebAreRefusedRatherThanOpened() {
        XCTAssertEqual(decide("file:///Users/synthetic/.ssh/id_ed25519"), .refuse)
        XCTAssertEqual(decide("javascript:alert(1)"), .refuse)
        XCTAssertEqual(decide("data:text/html,<script>alert(1)</script>"), .refuse)
        XCTAssertEqual(decide("ftp://example.test/x"), .refuse)
        XCTAssertEqual(decide("mailto:someone@example.test"), .refuse)
        // A scheme nobody has considered yet is refused too — that is the point of an allowlist.
        XCTAssertEqual(decide("dailyplanner-internal://wipe"), .refuse)
    }

    func testAMissingOrUnparseableURLIsRefused() {
        XCTAssertEqual(ExternalLinkPolicy.decide(url: nil, appOrigin: appOrigin), .refuse)
    }

    /// The origin check compares scheme, host and port in full. A suffix test would let
    /// `evil-127.0.0.1` and `127.0.0.1.attacker.test` pass as the app's own origin.
    func testLookAlikeOriginsAreNotTreatedAsTheApp() {
        XCTAssertEqual(decide("http://evil-127.0.0.1:54075/focus"), .openInSystemBrowser)
        XCTAssertEqual(decide("http://127.0.0.1.attacker.test:54075/focus"), .openInSystemBrowser)
        // Right host, wrong port: a different server entirely.
        XCTAssertEqual(decide("http://127.0.0.1:9999/focus"), .openInSystemBrowser)
        // Right host and port, wrong scheme.
        XCTAssertEqual(decide("https://127.0.0.1:54075/focus"), .openInSystemBrowser)
    }

    func testDefaultPortsCompareEqualToTheirImplicitForm() {
        let httpsOrigin = URL(string: "https://app.example.test/")!
        XCTAssertEqual(
            ExternalLinkPolicy.decide(url: URL(string: "https://app.example.test:443/x"), appOrigin: httpsOrigin),
            .keepInWebView
        )
        let httpOrigin = URL(string: "http://app.example.test:80/")!
        XCTAssertEqual(
            ExternalLinkPolicy.decide(url: URL(string: "http://app.example.test/x"), appOrigin: httpOrigin),
            .keepInWebView
        )
    }

    func testHostComparisonIgnoresCase() {
        XCTAssertEqual(
            ExternalLinkPolicy.decide(
                url: URL(string: "HTTP://127.0.0.1:54075/focus"),
                appOrigin: appOrigin
            ),
            .keepInWebView
        )
    }
}
