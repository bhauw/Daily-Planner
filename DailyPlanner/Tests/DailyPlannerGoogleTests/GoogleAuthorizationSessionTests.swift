import Foundation
import XCTest
import DailyPlannerDomain
@testable import DailyPlannerGoogle

final class GoogleAuthorizationSessionTests: XCTestCase {
    func testConstructionAloneHasNoListenerOrBrowserSideEffects() {
        // Break caught: session construction starts OAuth without explicit user intent.
        let listener = ScriptedLoopbackListener()
        let browser = RecordingBrowser(result: true)
        let factory = RecordingListenerFactory(listener: listener)

        _ = GoogleAuthorizationSession(listenerFactory: factory.make, browser: browser)

        XCTAssertEqual(factory.makeCount, 0)
        XCTAssertEqual(listener.startCount, 0)
        XCTAssertEqual(browser.openCount, 0)
    }

    func testReadyThenFailedThenCallbackOpensBrowserAndConsentOnceAndSucceedsOnce() async throws {
        // Break caught: a late startup failure overrides readiness or causes duplicate completion/opening.
        let harness = SessionHarness(browserResult: true)
        let task = harness.authorize(timeout: .seconds(1))
        await harness.listener.waitUntilStarted()

        harness.listener.emit(.ready(port: 43_117))
        await harness.browser.waitForOpenCount(1)
        harness.listener.emit(.startupFailed)
        harness.listener.emit(.callback(
            target: try harness.validTarget(code: "synthetic-code"),
            acknowledgment: RecordingAcknowledgment()
        ))
        harness.listener.emit(.callback(
            target: try harness.validTarget(code: "late-code"),
            acknowledgment: RecordingAcknowledgment()
        ))

        let grant = try await task.value
        XCTAssertEqual(grant.authorizationCode, "synthetic-code")
        XCTAssertEqual(grant.request.redirectURL.absoluteString, "http://127.0.0.1:43117/oauth/callback")
        XCTAssertEqual(harness.consent.count, 1)
        XCTAssertEqual(harness.browser.openCount, 1)
        XCTAssertEqual(harness.listener.cancelCount, 1)
    }

    func testFailedThenReadyFailsWithoutOpeningBrowserAndCleansUpOnce() async {
        // Break caught: readiness can resurrect a session after startup failure won.
        let harness = SessionHarness(browserResult: true)
        let task = harness.authorize(timeout: .seconds(1))
        await harness.listener.waitUntilStarted()

        harness.listener.emit(.startupFailed)
        harness.listener.emit(.ready(port: 43_117))

        await assertSessionError(.listenerFailed, from: task)
        XCTAssertEqual(harness.consent.count, 0)
        XCTAssertEqual(harness.browser.openCount, 0)
        XCTAssertEqual(harness.listener.cancelCount, 1)
    }

    func testMultipleReadyAndCallbackEventsOpenAndCompleteAtMostOnce() async throws {
        // Break caught: duplicate listener events create multiple browser attempts or terminal results.
        let harness = SessionHarness(browserResult: true)
        let task = harness.authorize(timeout: .seconds(1))
        await harness.listener.waitUntilStarted()

        harness.listener.emit(.ready(port: 43_117))
        harness.listener.emit(.ready(port: 52_222))
        await harness.browser.waitForOpenCount(1)
        harness.listener.emit(.callback(
            target: try harness.validTarget(code: "first-code"),
            acknowledgment: RecordingAcknowledgment()
        ))
        harness.listener.emit(.callback(
            target: try harness.validTarget(code: "second-code"),
            acknowledgment: RecordingAcknowledgment()
        ))

        let grant = try await task.value
        XCTAssertEqual(grant.authorizationCode, "first-code")
        XCTAssertEqual(grant.request.redirectURL.port, 43_117)
        XCTAssertEqual(harness.browser.openCount, 1)
        XCTAssertEqual(harness.consent.count, 1)
        XCTAssertEqual(harness.listener.cancelCount, 1)
    }

    func testBrowserRejectionIsFiniteAndCleansUp() async {
        // Break caught: a false browser result leaves authorization pending.
        let harness = SessionHarness(browserResult: false)
        let task = harness.authorize(timeout: .seconds(1))
        await harness.listener.waitUntilStarted()
        harness.listener.emit(.ready(port: 43_117))

        await assertSessionError(.browserRejected, from: task)
        XCTAssertEqual(harness.browser.openCount, 1)
        XCTAssertEqual(harness.listener.cancelCount, 1)
    }

    func testExplicitCancelBeforeReadinessIsFiniteAndIgnoresLateReady() async {
        // Break caught: cancellation before readiness leaks the listener or permits a later browser open.
        let harness = SessionHarness(browserResult: true)
        let task = harness.authorize(timeout: .seconds(1))
        await harness.listener.waitUntilStarted()

        harness.session.cancel()
        harness.listener.emit(.ready(port: 43_117))

        await assertSessionError(.cancelled, from: task)
        XCTAssertEqual(harness.browser.openCount, 0)
        XCTAssertEqual(harness.listener.cancelCount, 1)
    }

    func testExplicitCancelAfterReadinessIsFiniteAndCleansUp() async {
        // Break caught: cancellation while waiting for callback cannot win the terminal gate.
        let harness = SessionHarness(browserResult: true)
        let task = harness.authorize(timeout: .seconds(1))
        await harness.listener.waitUntilStarted()
        harness.listener.emit(.ready(port: 43_117))
        await harness.browser.waitForOpenCount(1)

        harness.session.cancel()

        await assertSessionError(.cancelled, from: task)
        XCTAssertEqual(harness.listener.cancelCount, 1)
    }

    func testTimeoutBeforeReadinessIsFiniteAndCleansUp() async {
        // Break caught: timeout is armed only after readiness.
        let harness = SessionHarness(browserResult: true)
        let task = harness.authorize(timeout: .milliseconds(20))
        await harness.listener.waitUntilStarted()

        await assertSessionError(.timedOut, from: task)
        XCTAssertEqual(harness.browser.openCount, 0)
        XCTAssertEqual(harness.listener.cancelCount, 1)
    }

    func testTimeoutWhileWaitingForCallbackIsFiniteAndCleansUp() async {
        // Break caught: browser success disables the bounded session timeout.
        let harness = SessionHarness(browserResult: true)
        let task = harness.authorize(timeout: .milliseconds(40))
        await harness.listener.waitUntilStarted()
        harness.listener.emit(.ready(port: 43_117))
        await harness.browser.waitForOpenCount(1)

        await assertSessionError(.timedOut, from: task)
        XCTAssertEqual(harness.listener.cancelCount, 1)
    }

    func testCancelWhileConsentCallbackIsSuspendedPreventsBrowserOpen() async {
        // Break caught: the browser opens after cancellation because an awaited callback resumes late.
        let gate = ConsentGate()
        let harness = SessionHarness(browserResult: true, consent: gate)
        let task = harness.authorize(timeout: .seconds(1))
        await harness.listener.waitUntilStarted()
        harness.listener.emit(.ready(port: 43_117))
        await gate.waitUntilEntered()

        harness.session.cancel()
        gate.release()

        await assertSessionError(.cancelled, from: task)
        await Task.yield()
        XCTAssertEqual(harness.browser.openCount, 0)
        XCTAssertEqual(harness.listener.cancelCount, 1)
    }

    func testListenerFactoryThrowIsFiniteWithoutStartingOrOpening() async {
        // Break caught: factory errors escape as raw values or leave the authorization suspended.
        let browser = RecordingBrowser(result: true)
        let session = GoogleAuthorizationSession(
            listenerFactory: { throw SyntheticFailure.injected },
            browser: browser
        )

        do {
            _ = try await session.authorize(clientIdentifier: "synthetic-client", timeout: .seconds(1))
            XCTFail("Expected listener failure")
        } catch {
            XCTAssertEqual(error as? GoogleAuthorizationSessionError, .listenerFailed)
        }
        XCTAssertEqual(browser.openCount, 0)
    }

    func testListenerStartThrowIsFiniteAndCancelsOwnedListener() async {
        // Break caught: a listener acquired by the session is not cleaned up when start throws.
        let listener = ScriptedLoopbackListener(startError: SyntheticFailure.injected)
        let browser = RecordingBrowser(result: true)
        let session = GoogleAuthorizationSession(listenerFactory: { listener }, browser: browser)

        do {
            _ = try await session.authorize(clientIdentifier: "synthetic-client", timeout: .seconds(1))
            XCTFail("Expected listener failure")
        } catch {
            XCTAssertEqual(error as? GoogleAuthorizationSessionError, .listenerFailed)
        }
        XCTAssertEqual(listener.cancelCount, 1)
        XCTAssertEqual(browser.openCount, 0)
    }

    func testInvalidCallbackAndListenerRequestFailureAreFiniteAndSanitized() async throws {
        // Break caught: malformed callback input hangs or appears inside the surfaced error.
        let harness = SessionHarness(browserResult: true)
        let task = harness.authorize(timeout: .seconds(1))
        await harness.listener.waitUntilStarted()
        harness.listener.emit(.ready(port: 43_117))
        await harness.browser.waitForOpenCount(1)
        harness.listener.emit(.callback(
            target: "/oauth/callback?code=secret-code&state=secret-state",
            acknowledgment: RecordingAcknowledgment()
        ))

        await assertSessionError(.invalidCallback, from: task)
        XCTAssertEqual(harness.listener.cancelCount, 1)

        let second = SessionHarness(browserResult: true)
        let secondTask = second.authorize(timeout: .seconds(1))
        await second.listener.waitUntilStarted()
        second.listener.emit(.invalidRequest)
        await assertSessionError(.invalidCallback, from: secondTask)
        XCTAssertEqual(second.listener.cancelCount, 1)
    }

    func testAccessDeniedCallbackIsCancellationAndCleansUp() async throws {
        // Break caught: a user-denied consent callback is collapsed into an invalid provider callback.
        let harness = SessionHarness(browserResult: true)
        let task = harness.authorize(timeout: .seconds(1))
        await harness.listener.waitUntilStarted()
        harness.listener.emit(.ready(port: 43_117))
        await harness.browser.waitForOpenCount(1)
        let acknowledgment = RecordingAcknowledgment()

        harness.listener.emit(.callback(
            target: "/oauth/callback?error=access_denied&state=\(try harness.authorizationState())",
            acknowledgment: acknowledgment
        ))

        await assertSessionError(.cancelled, from: task)
        XCTAssertEqual(acknowledgment.responses, [.failure])
        XCTAssertEqual(harness.listener.cancelCount, 1)
    }

    func testMalformedOrWrongStateAccessDeniedCallbacksRemainInvalid() async throws {
        // Break caught: an unvalidated error parameter can cancel a session without the exact state and shape.
        for variant in DeniedCallbackVariant.allCases {
            let harness = SessionHarness(browserResult: true)
            let task = harness.authorize(timeout: .seconds(1))
            await harness.listener.waitUntilStarted()
            harness.listener.emit(.ready(port: 43_117))
            await harness.browser.waitForOpenCount(1)
            let acknowledgment = RecordingAcknowledgment()
            let state = try harness.authorizationState()

            harness.listener.emit(.callback(
                target: variant.target(validState: state),
                acknowledgment: acknowledgment
            ))

            await assertSessionError(.invalidCallback, from: task)
            XCTAssertEqual(acknowledgment.responses, [.failure])
            XCTAssertEqual(harness.listener.cancelCount, 1)
        }
    }

    func testCallbackAcknowledgesSuccessOnlyAfterSemanticValidation() async throws {
        // Break caught: syntactically valid but semantically invalid callbacks receive success HTML.
        let valid = SessionHarness(browserResult: true)
        let validTask = valid.authorize(timeout: .seconds(1))
        await valid.listener.waitUntilStarted()
        valid.listener.emit(.ready(port: 43_117))
        await valid.browser.waitForOpenCount(1)
        let successAcknowledgment = RecordingAcknowledgment()
        valid.listener.emit(.callback(
            target: try valid.validTarget(code: "synthetic-code"),
            acknowledgment: successAcknowledgment
        ))

        _ = try await validTask.value
        XCTAssertEqual(successAcknowledgment.responses, [.success])

        let rejectedTargets = [
            "/oauth/callback?code=secret-code&state=wrong-state",
            "/wrong?code=secret-code&state=secret-state",
        ]
        for target in rejectedTargets {
            let invalid = SessionHarness(browserResult: true)
            let invalidTask = invalid.authorize(timeout: .seconds(1))
            await invalid.listener.waitUntilStarted()
            invalid.listener.emit(.ready(port: 43_117))
            await invalid.browser.waitForOpenCount(1)
            let failureAcknowledgment = RecordingAcknowledgment()
            invalid.listener.emit(.callback(target: target, acknowledgment: failureAcknowledgment))

            await assertSessionError(.invalidCallback, from: invalidTask)
            XCTAssertEqual(failureAcknowledgment.responses, [.failure])
            let responseDescription = String(reflecting: failureAcknowledgment.responses)
            XCTAssertFalse(responseDescription.contains("secret-code"))
            XCTAssertFalse(responseDescription.contains("secret-state"))
        }
    }

    func testSuccessfulCallbackClaimsTerminalResultBeforeAcknowledgment() async throws {
        // Break caught: reentrant cancellation can win after success HTML is selected but before completion.
        let harness = SessionHarness(browserResult: true)
        let task = harness.authorize(timeout: .seconds(1))
        await harness.listener.waitUntilStarted()
        harness.listener.emit(.ready(port: 43_117))
        await harness.browser.waitForOpenCount(1)
        let acknowledgment = ReentrantCancellingAcknowledgment(session: harness.session)

        harness.listener.emit(.callback(
            target: try harness.validTarget(code: "claimed-code"),
            acknowledgment: acknowledgment
        ))

        let grant = try await task.value
        XCTAssertEqual(grant.authorizationCode, "claimed-code")
        XCTAssertEqual(acknowledgment.responses, [.success])
        XCTAssertEqual(harness.listener.cancelCount, 1)
    }

    func testTaskCancellationUsesTheSameTerminalGate() async {
        // Break caught: Swift task cancellation does not cancel the owned listener and continuation.
        let harness = SessionHarness(browserResult: true)
        let task = harness.authorize(timeout: .seconds(1))
        await harness.listener.waitUntilStarted()

        task.cancel()

        await assertSessionError(.cancelled, from: task)
        XCTAssertEqual(harness.listener.cancelCount, 1)
    }

    func testAlreadyCancelledAuthorizationSkipsAThrowingListenerFactory() async {
        // Break caught: an already-cancelled call performs factory work and surfaces listener failure.
        let factory = RecordingThrowingListenerFactory()
        let session = GoogleAuthorizationSession(
            listenerFactory: factory.make,
            browser: RecordingBrowser(result: true)
        )
        let task = Task<GoogleAuthorizationGrant, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await session.authorize(
                clientIdentifier: "synthetic-client",
                timeout: .seconds(1)
            )
        }

        await assertSessionError(.cancelled, from: task)
        XCTAssertEqual(factory.makeCount, 0)
    }

    func testCancelledCompetingAuthorizationCannotCancelTheActiveAuthorization() async throws {
        // Break caught: the competing task's cancellation handler targets another task's active session.
        let firstListener = ScriptedLoopbackListener()
        let secondListener = ScriptedLoopbackListener()
        let factory = SequencedListenerFactory(listeners: [firstListener, secondListener])
        let browser = RecordingBrowser(result: true)
        let session = GoogleAuthorizationSession(listenerFactory: factory.make, browser: browser)
        let firstTask = Task<GoogleAuthorizationGrant, Error> {
            try await session.authorize(clientIdentifier: "synthetic-client", timeout: .seconds(1))
        }
        await firstListener.waitUntilStarted()

        let competingTask = Task<GoogleAuthorizationGrant, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await session.authorize(clientIdentifier: "synthetic-client", timeout: .seconds(1))
        }

        await assertSessionError(.cancelled, from: competingTask)
        firstListener.emit(.ready(port: 43_117))
        await browser.waitForOpenCount(1)
        let authorizationURL = try XCTUnwrap(browser.openedURLs.first)
        let components = try XCTUnwrap(URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false))
        let state = try XCTUnwrap(components.queryItems?.first(where: { $0.name == "state" })?.value)
        firstListener.emit(.callback(
            target: "/oauth/callback?code=first-code&state=\(state)",
            acknowledgment: RecordingAcknowledgment()
        ))

        let grant = try await firstTask.value
        XCTAssertEqual(grant.authorizationCode, "first-code")
        XCTAssertEqual(firstListener.cancelCount, 1)
        XCTAssertEqual(secondListener.startCount, 0)
        XCTAssertEqual(factory.makeCount, 1)
    }
}

private final class SessionHarness: @unchecked Sendable {
    let listener: ScriptedLoopbackListener
    let browser: RecordingBrowser
    let consent: ConsentGate
    let session: GoogleAuthorizationSession

    init(browserResult: Bool, consent: ConsentGate = ConsentGate(autoRelease: true)) {
        let listener = ScriptedLoopbackListener()
        let browser = RecordingBrowser(result: browserResult)
        self.listener = listener
        self.browser = browser
        self.consent = consent
        self.session = GoogleAuthorizationSession(listenerFactory: { listener }, browser: browser)
    }

    func authorize(timeout: Duration) -> Task<GoogleAuthorizationGrant, Error> {
        Task {
            try await session.authorize(
                clientIdentifier: "synthetic-client",
                timeout: timeout,
                onAwaitingConsent: { [consent] in await consent.enter() }
            )
        }
    }

    func validTarget(code: String) throws -> String {
        "/oauth/callback?code=\(code)&state=\(try authorizationState())"
    }

    func authorizationState() throws -> String {
        let url = try XCTUnwrap(browser.openedURLs.first)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return try XCTUnwrap(components.queryItems?.first(where: { $0.name == "state" })?.value)
    }
}

private enum DeniedCallbackVariant: CaseIterable {
    case wrongState
    case duplicateError
    case extraField

    func target(validState: String) -> String {
        switch self {
        case .wrongState:
            return "/oauth/callback?error=access_denied&state=wrong-state"
        case .duplicateError:
            return "/oauth/callback?error=access_denied&error=access_denied&state=\(validState)"
        case .extraField:
            return "/oauth/callback?error=access_denied&state=\(validState)&unexpected=value"
        }
    }
}

private final class ScriptedLoopbackListener: GoogleLoopbackListening, @unchecked Sendable {
    private struct State {
        var startCount = 0
        var cancelCount = 0
        var handler: (@Sendable (GoogleLoopbackEvent) -> Void)?
    }

    private let lock = NSLock()
    private var state = State()
    private let startError: Error?

    init(startError: Error? = nil) {
        self.startError = startError
    }

    var startCount: Int { locked { $0.startCount } }
    var cancelCount: Int { locked { $0.cancelCount } }

    func start(timeout: Duration, handler: @escaping @Sendable (GoogleLoopbackEvent) -> Void) throws {
        locked {
            $0.startCount += 1
            $0.handler = handler
        }
        if let startError { throw startError }
    }

    func cancel() {
        locked { $0.cancelCount += 1 }
    }

    func emit(_ event: GoogleLoopbackEvent) {
        let handler = locked { $0.handler }
        handler?(event)
    }

    func waitUntilStarted() async {
        await waitUntil { self.startCount == 1 }
    }

    @discardableResult
    private func locked<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

private final class RecordingBrowser: SystemBrowserOpening, @unchecked Sendable {
    private struct State {
        var openedURLs: [URL] = []
    }

    private let lock = NSLock()
    private var state = State()
    private let result: Bool

    init(result: Bool) {
        self.result = result
    }

    var openCount: Int { locked { $0.openedURLs.count } }
    var openedURLs: [URL] { locked { $0.openedURLs } }

    func open(_ url: URL) async -> Bool {
        locked { $0.openedURLs.append(url) }
        return result
    }

    func waitForOpenCount(_ count: Int) async {
        await waitUntil { self.openCount == count }
    }

    @discardableResult
    private func locked<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

private final class RecordingAcknowledgment: GoogleLoopbackAcknowledging, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedResponses: [GoogleLoopbackResponse] = []

    var responses: [GoogleLoopbackResponse] {
        lock.lock()
        defer { lock.unlock() }
        return recordedResponses
    }

    func respond(_ response: GoogleLoopbackResponse) {
        lock.lock()
        recordedResponses.append(response)
        lock.unlock()
    }
}

private final class ReentrantCancellingAcknowledgment: GoogleLoopbackAcknowledging, @unchecked Sendable {
    private let lock = NSLock()
    private let session: GoogleAuthorizationSession
    private var recordedResponses: [GoogleLoopbackResponse] = []

    init(session: GoogleAuthorizationSession) {
        self.session = session
    }

    var responses: [GoogleLoopbackResponse] {
        lock.lock()
        defer { lock.unlock() }
        return recordedResponses
    }

    func respond(_ response: GoogleLoopbackResponse) {
        lock.lock()
        recordedResponses.append(response)
        lock.unlock()

        if response == .success {
            session.cancel()
        }
    }
}

private final class RecordingListenerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let listener: ScriptedLoopbackListener

    init(listener: ScriptedLoopbackListener) {
        self.listener = listener
    }

    var makeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func make() throws -> any GoogleLoopbackListening {
        lock.lock()
        count += 1
        lock.unlock()
        return listener
    }
}

private final class RecordingThrowingListenerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var makeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func make() throws -> any GoogleLoopbackListening {
        lock.lock()
        count += 1
        lock.unlock()
        throw SyntheticFailure.injected
    }
}

private final class SequencedListenerFactory: @unchecked Sendable {
    private struct State {
        var listeners: [ScriptedLoopbackListener]
        var makeCount = 0
    }

    private let lock = NSLock()
    private var state: State

    init(listeners: [ScriptedLoopbackListener]) {
        state = State(listeners: listeners)
    }

    var makeCount: Int { locked { $0.makeCount } }

    func make() throws -> any GoogleLoopbackListening {
        try locked { state in
            guard !state.listeners.isEmpty else { throw SyntheticFailure.injected }
            state.makeCount += 1
            return state.listeners.removeFirst()
        }
    }

    @discardableResult
    private func locked<T>(_ body: (inout State) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}

private final class ConsentGate: @unchecked Sendable {
    private struct State {
        var count = 0
        var autoRelease: Bool
        var continuation: CheckedContinuation<Void, Never>?
    }

    private let lock = NSLock()
    private var state: State

    init(autoRelease: Bool = false) {
        self.state = State(autoRelease: autoRelease)
    }

    var count: Int { locked { $0.count } }

    func enter() async {
        await withCheckedContinuation { continuation in
            let releaseNow = locked { state -> Bool in
                state.count += 1
                if state.autoRelease { return true }
                state.continuation = continuation
                return false
            }
            if releaseNow { continuation.resume() }
        }
    }

    func release() {
        let continuation = locked { state -> CheckedContinuation<Void, Never>? in
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume()
    }

    func waitUntilEntered() async {
        await waitUntil { self.count == 1 }
    }

    @discardableResult
    private func locked<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

private enum SyntheticFailure: Error {
    case injected
}

private func assertSessionError(
    _ expected: GoogleAuthorizationSessionError,
    from task: Task<GoogleAuthorizationGrant, Error>,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await task.value
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? GoogleAuthorizationSessionError, expected, file: file, line: line)
    }
}

private func waitUntil(
    _ predicate: @escaping @Sendable () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while !predicate(), clock.now < deadline {
        await Task.yield()
    }
    XCTAssertTrue(predicate(), "Condition was not met before deadline", file: file, line: line)
}
