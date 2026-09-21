import Foundation
import Testing
@testable import GoogleOAuthCore

@Suite("Loopback callback validation")
struct LoopbackCallbackTests {
    @Test("Listener request parser waits for fragmented request line and headers")
    func accumulatesFragmentedRequestHead() throws {
        var accumulator = LoopbackHTTPRequestAccumulator(maximumBytes: 1_024)

        #expect(try accumulator.append(Data("GET /oauth/".utf8)) == nil)
        #expect(try accumulator.append(Data("callback?code=synthetic-code".utf8)) == nil)
        #expect(try accumulator.append(Data("&state=expected-state HTTP/1.1\r\nHo".utf8)) == nil)
        let head = try #require(
            try accumulator.append(Data("st: 127.0.0.1:54321\r\nConnection: close\r\n\r\n".utf8))
        )

        #expect(head.requestTarget == "/oauth/callback?code=synthetic-code&state=expected-state")
        #expect(head.hostHeader == "127.0.0.1:54321")
    }

    @Test("Listener request parser rejects a head over its strict byte limit")
    func rejectsOversizedFragmentedRequestHead() throws {
        var accumulator = LoopbackHTTPRequestAccumulator(maximumBytes: 32)

        #expect(try accumulator.append(Data("GET /oauth/callback?".utf8)) == nil)
        #expect(throws: LoopbackCallbackError.requestTooLarge) {
            try accumulator.append(Data("code=synthetic-code&state=expected-state".utf8))
        }
    }

    @Test("A valid callback returns its authorization code once")
    func acceptsValidCallbackOnce() throws {
        var callback = LoopbackCallback(expectedState: "expected-state")

        let code = try callback.consume(
            requestTarget: "/oauth/callback?code=synthetic-code&state=expected-state",
            hostHeader: "127.0.0.1:54321"
        )

        #expect(code == "synthetic-code")
        #expect(throws: LoopbackCallbackError.duplicateCallback) {
            try callback.consume(
                requestTarget: "/oauth/callback?code=second-code&state=expected-state",
                hostHeader: "127.0.0.1:54321"
            )
        }
    }

    @Test("Callbacks from non-loopback hosts are rejected")
    func rejectsNonLoopbackHost() {
        var callback = LoopbackCallback(expectedState: "expected-state")

        #expect(throws: LoopbackCallbackError.nonLoopbackHost) {
            try callback.consume(
                requestTarget: "/oauth/callback?code=synthetic-code&state=expected-state",
                hostHeader: "localhost:54321"
            )
        }
    }

    @Test("A missing authorization code is rejected")
    func rejectsMissingCode() {
        var callback = LoopbackCallback(expectedState: "expected-state")

        #expect(throws: LoopbackCallbackError.missingCode) {
            try callback.consume(
                requestTarget: "/oauth/callback?state=expected-state",
                hostHeader: "127.0.0.1:54321"
            )
        }
    }

    @Test("A state mismatch is rejected")
    func rejectsStateMismatch() {
        var callback = LoopbackCallback(expectedState: "expected-state")

        #expect(throws: LoopbackCallbackError.stateMismatch) {
            try callback.consume(
                requestTarget: "/oauth/callback?code=synthetic-code&state=wrong-state",
                hostHeader: "127.0.0.1:54321"
            )
        }
    }

    @Test("Denied consent has a safe typed failure")
    func reportsDeniedConsent() {
        var callback = LoopbackCallback(expectedState: "expected-state")

        #expect(throws: LoopbackCallbackError.deniedConsent) {
            try callback.consume(
                requestTarget: "/oauth/callback?error=access_denied&state=expected-state",
                hostHeader: "127.0.0.1:54321"
            )
        }
    }

    @Test("Timeout and browser cancellation are distinct safe failures", arguments: [
        (LoopbackTermination.timeout, LoopbackCallbackError.timeout),
        (LoopbackTermination.browserCancelled, LoopbackCallbackError.browserCancelled),
    ])
    func reportsTermination(termination: LoopbackTermination, expected: LoopbackCallbackError) {
        var callback = LoopbackCallback(expectedState: "expected-state")
        callback.terminate(termination)

        #expect(throws: expected) {
            try callback.consume(
                requestTarget: "/oauth/callback?code=synthetic-code&state=expected-state",
                hostHeader: "127.0.0.1:54321"
            )
        }
    }
}
