import Foundation
import XCTest
@testable import DailyPlannerGoogle

final class GoogleOAuthCallbackTests: XCTestCase {
    func testCallbackAcceptsOnlyExactPathSingleCodeAndMatchingState() throws {
        // Break caught: the exact callback is rejected or its opaque code is changed.
        let result = try GoogleOAuthCallback.parse(
            target: "/oauth/callback?code=synthetic-code&state=expected-state",
            expectedState: "expected-state"
        )

        XCTAssertEqual(result.authorizationCode, "synthetic-code")
    }

    func testCallbackAcceptsAValidPercentEncodedCodeWithoutFormDecoding() throws {
        // Break caught: valid provider percent encoding is rejected or '+' is treated as a space.
        let result = try GoogleOAuthCallback.parse(
            target: "/oauth/callback?code=synthetic%2Fcode&state=expected-state",
            expectedState: "expected-state"
        )

        XCTAssertEqual(result.authorizationCode, "synthetic/code")
        XCTAssertThrowsError(try GoogleOAuthCallback.parse(
            target: "/oauth/callback?code=synthetic+code&state=expected-state",
            expectedState: "expected-state"
        ))
    }

    func testCallbackAcceptsKnownGoogleSuccessMetadataWithoutTrustingIt() throws {
        // Break caught: Google's real loopback callback is rejected for including standard success metadata.
        let result = try GoogleOAuthCallback.parse(
            target: "/oauth/callback?state=expected-state&iss=https://accounts.google.com&code=synthetic-code&scope=email%20openid%20https://www.googleapis.com/auth/calendar.readonly&authuser=0&prompt=consent",
            expectedState: "expected-state"
        )

        XCTAssertEqual(result.authorizationCode, "synthetic-code")
    }

    func testCallbackRejectsWrongMissingOrAmbiguousRouteAndQueryShapes() {
        // Break caught: alternate origins, paths, fragments, or extra query shapes reach OAuth handling.
        let targets = [
            "/other?code=value&state=expected-state",
            "//example.test/oauth/callback?code=value&state=expected-state",
            "http://127.0.0.1/oauth/callback?code=value&state=expected-state",
            "http://user@example.test/oauth/callback?code=value&state=expected-state",
            "/oauth/callback/?code=value&state=expected-state",
            "/oauth/callback?code=value&state=expected-state#fragment",
            "/oauth/callback?code=value&state=expected-state&benign=value",
            "/oauth/callback?code=value&state=expected-state&iss=https://attacker.example",
            "/oauth/callback?code=value&state=expected-state&prompt=consent&prompt=consent",
            "/oauth/callback?error=access_denied&state=expected-state&prompt=consent",
            "/oauth/callback?code=value;state=expected-state",
        ]

        for target in targets {
            XCTAssertThrowsError(
                try GoogleOAuthCallback.parse(target: target, expectedState: "expected-state"),
                "Unexpectedly accepted \(target)"
            )
        }
    }

    func testCallbackRejectsMissingEmptyAndDuplicateAuthorizationCode() {
        // Break caught: a missing, empty, or duplicated authorization code is accepted.
        let targets = [
            "/oauth/callback?state=expected-state",
            "/oauth/callback?code=&state=expected-state",
            "/oauth/callback?code=one&code=two&state=expected-state",
        ]

        for target in targets {
            XCTAssertThrowsError(try GoogleOAuthCallback.parse(target: target, expectedState: "expected-state"))
        }
    }

    func testCallbackRejectsMissingEmptyDuplicateAndWrongState() {
        // Break caught: state is optional, duplicated, empty, or compared non-exactly.
        let targets = [
            "/oauth/callback?code=value",
            "/oauth/callback?code=value&state=",
            "/oauth/callback?code=value&state=expected-state&state=expected-state",
            "/oauth/callback?code=value&state=wrong-state",
            "/oauth/callback?code=value&state=expected",
        ]

        for target in targets {
            XCTAssertThrowsError(try GoogleOAuthCallback.parse(target: target, expectedState: "expected-state"))
        }
    }

    func testCallbackRejectsOAuthErrorControlCharactersAndMalformedPercentEncoding() {
        // Break caught: provider errors or parser-confusing bytes are treated as authorization grants.
        let targets = [
            "/oauth/callback?error=access_denied&state=expected-state",
            "/oauth/callback?code=value&state=expected-state\r\nInjected: true",
            "/oauth/callback?code=synthetic%0Acode&state=expected-state",
            "/oauth/callback?code=synthetic%code&state=expected-state",
            "/oauth/callback?code=synthetic%2&state=expected-state",
            "/oauth/callback?code=synthetic%252Fcode&state=expected-state",
            "/oauth/callback?c%6Fde=value&state=expected-state",
        ]

        for target in targets {
            XCTAssertThrowsError(try GoogleOAuthCallback.parse(target: target, expectedState: "expected-state"))
        }
    }

    func testCallbackErrorsNeverReflectSensitiveValues() {
        // Break caught: callback-controlled values are embedded in a finite error description.
        let canaries = ["synthetic-secret-code", "synthetic-secret-state"]

        do {
            _ = try GoogleOAuthCallback.parse(
                target: "/oauth/callback?code=synthetic-secret-code&state=synthetic-secret-state",
                expectedState: "expected-state"
            )
            XCTFail("Expected state mismatch")
        } catch {
            let description = String(reflecting: error)
            for canary in canaries {
                XCTAssertFalse(description.contains(canary))
            }
        }
    }

    func testRequestHeadParserAcceptsOnlyACompleteBoundedGETHead() throws {
        // Break caught: the listener accepts another method or an incomplete/malformed request head.
        let valid = Data("GET /oauth/callback?code=value&state=expected-state HTTP/1.1\r\nHost: 127.0.0.1:43117\r\n\r\n".utf8)
        XCTAssertEqual(try GoogleLoopbackRequestHead.parse(valid).target, "/oauth/callback?code=value&state=expected-state")

        let invalidHeads = [
            Data("POST /oauth/callback?code=value&state=expected-state HTTP/1.1\r\nHost: 127.0.0.1:43117\r\n\r\n".utf8),
            Data("GET /oauth/callback?code=value&state=expected-state HTTP/1.1\r\nHost: 127.0.0.1:43117\r\n".utf8),
            Data("GET  /oauth/callback?code=value&state=expected-state HTTP/1.1\r\nHost: 127.0.0.1:43117\r\n\r\n".utf8),
            Data("GET /oauth/callback?code=value&state=expected-state HTTP/1.0\r\nHost: 127.0.0.1:43117\r\n\r\n".utf8),
            Data("GET /oauth/callback?code=value&state=expected-state HTTP/1.1\nHost: 127.0.0.1:43117\n\n".utf8),
            Data("GET /oauth/callback?code=value&state=expected-state HTTP/1.1\r\nBroken\r\n\r\n".utf8),
        ]

        for head in invalidHeads {
            XCTAssertThrowsError(try GoogleLoopbackRequestHead.parse(head))
        }
    }

    func testRequestHeadParserRejectsTheFirstByteBeyondItsDocumentedLimit() throws {
        // Break caught: listener head accumulation can grow beyond the fixed 8 KiB boundary.
        let prefix = "GET /oauth/callback?code=value&state=expected-state HTTP/1.1\r\nX-Pad: "
        let suffix = "\r\n\r\n"
        let exactPadding = String(
            repeating: "a",
            count: GoogleLoopbackRequestHead.maximumByteCount - Data(prefix.utf8).count - Data(suffix.utf8).count
        )
        let exact = Data((prefix + exactPadding + suffix).utf8)
        XCTAssertNoThrow(try GoogleLoopbackRequestHead.parse(exact))

        let oversized = Data((prefix + exactPadding + "a" + suffix).utf8)
        XCTAssertThrowsError(try GoogleLoopbackRequestHead.parse(oversized))
    }

    func testStartupGatePreservesAcceptedConnectionsOnlyAfterReadinessWins() {
        // Break caught: a listener failure tears down accepted callback paths after readiness won.
        var readyFirst = GoogleLoopbackStartupGate()
        XCTAssertEqual(readyFirst.receive(.ready), .announceReady)
        XCTAssertEqual(readyFirst.receive(.failed), .preserveAcceptedConnections)

        var failedFirst = GoogleLoopbackStartupGate()
        XCTAssertEqual(failedFirst.receive(.failed), .failStartup)
        XCTAssertEqual(failedFirst.receive(.ready), .ignore)
    }

    func testResponseCancellationGateCancelsOnceAndRetiresFallbackAfterSendCompletion() {
        // Break caught: send completion and its fallback each cancel the same response connection.
        let counter = SynchronizedCounter()
        let gate = GoogleLoopbackResponseCancellationGate(cancel: counter.increment)
        let fallback = DispatchWorkItem {}
        gate.registerFallback(fallback)

        gate.sendCompleted()
        gate.fallbackFired()

        XCTAssertEqual(counter.value, 1)
        XCTAssertFalse(gate.hasPendingFallback)
        XCTAssertTrue(fallback.isCancelled)
    }
}

private final class SynchronizedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
