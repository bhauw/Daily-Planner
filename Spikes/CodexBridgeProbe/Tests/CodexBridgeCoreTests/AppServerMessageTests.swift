import Testing
import Foundation
@testable import CodexBridgeCore

@Test func decodesThreadStartResponse() throws {
    let line = #"{"id":10,"result":{"thread":{"id":"thr_synthetic"}}}"#
    let message = try AppServerMessage.decode(line)

    #expect(message.id == .integer(10))
    #expect(message.threadID == "thr_synthetic")
}

@Test func decodesStringRequestIDWithoutCoercion() throws {
    let line = #"{"id":"request_synthetic","result":{}}"#
    let message = try AppServerMessage.decode(line)

    #expect(message.id == .string("request_synthetic"))
}

@Test func rejectsMalformedJSONLine() {
    #expect(throws: (any Error).self) {
        try AppServerMessage.decode("not-json")
    }
}

@Test func runsFixedProbeAndRemovesTemporaryWorkingDirectory() async throws {
    let fixture = try ProbeFixture(script: ServerScripts.valid)
    defer { fixture.remove() }
    let client = AppServerProcess(
        executableURL: fixture.executableURL,
        temporaryDirectoryRoot: fixture.probeRoot
    )

    let result = try await client.runProbe(timeout: .seconds(3))

    #expect(result == CodexProbeResult(
        protocolVersion: "v2",
        threadStarted: true,
        turnCompleted: true,
        structuredStatus: "ok",
        cleanupSucceeded: true
    ))
    #expect(try fixture.probeContents().isEmpty)
    #expect(client.sanitizedStderr.isEmpty)
}

@Test func reportsMissingExecutable() async throws {
    let fixture = try ProbeFixture(script: ServerScripts.blocking)
    defer { fixture.remove() }
    let missingURL = fixture.executableURL.deletingLastPathComponent()
        .appendingPathComponent("missing-codex")
    let client = AppServerProcess(
        executableURL: missingURL,
        temporaryDirectoryRoot: fixture.probeRoot
    )

    let error = await capturedProbeError {
        try await client.runProbe(timeout: .seconds(3))
    }

    #expect(error == .missingExecutable)
    #expect(try fixture.probeContents().isEmpty)
}

@Test func reportsEarlyChildExitAndRedactsStderr() async throws {
    let fixture = try ProbeFixture(script: ServerScripts.earlyExit)
    defer { fixture.remove() }
    let client = AppServerProcess(
        executableURL: fixture.executableURL,
        temporaryDirectoryRoot: fixture.probeRoot
    )

    let error = await capturedProbeError {
        try await client.runProbe(timeout: .seconds(3))
    }

    #expect(error == .earlyChildExit)
    #expect(!client.sanitizedStderr.contains("/Users/synthetic/private"))
    #expect(!client.sanitizedStderr.contains("sk-synthetic-secret"))
    #expect(client.sanitizedStderr.contains("<redacted-path>"))
    #expect(client.sanitizedStderr.contains("<redacted-token>"))
    #expect(try fixture.probeContents().isEmpty)
}

@Test func reportsMalformedJSONFromChild() async throws {
    let fixture = try ProbeFixture(script: ServerScripts.malformed)
    defer { fixture.remove() }
    let client = AppServerProcess(
        executableURL: fixture.executableURL,
        temporaryDirectoryRoot: fixture.probeRoot
    )

    let error = await capturedProbeError {
        try await client.runProbe(timeout: .seconds(3))
    }

    #expect(error == .malformedJSON)
    #expect(try fixture.probeContents().isEmpty)
}

@Test func preservesOriginalFailureAfterAwaitingArchiveAcknowledgement() async throws {
    let fixture = try ProbeFixture(script: ServerScripts.postThreadFailureWithArchiveAck)
    defer { fixture.remove() }
    let client = AppServerProcess(
        executableURL: fixture.executableURL,
        temporaryDirectoryRoot: fixture.probeRoot
    )

    let error = await capturedProbeError {
        try await client.runProbe(timeout: .seconds(3))
    }

    #expect(error == .malformedJSON)
    #expect(client.sanitizedStderr.contains("archive-acknowledged"))
    #expect(!client.isChildRunning)
    #expect(try fixture.probeContents().isEmpty)
}

@Test func recordsMissingArchiveAcknowledgementWithoutMaskingOriginalFailure() async throws {
    let fixture = try ProbeFixture(script: ServerScripts.postThreadFailureWithoutArchiveAck)
    defer { fixture.remove() }
    let client = AppServerProcess(
        executableURL: fixture.executableURL,
        temporaryDirectoryRoot: fixture.probeRoot
    )

    let error = await capturedProbeError {
        try await client.runProbe(timeout: .seconds(3))
    }

    #expect(error == .malformedJSON)
    #expect(client.cleanupFailure == .archiveNotAcknowledged)
    #expect(!client.isChildRunning)
    #expect(try fixture.probeContents().isEmpty)
}

@Test func primaryFailureOwnsResultWhileCleanupCrossesOuterDeadline() async throws {
    let fixture = try ProbeFixture(script: ServerScripts.failureBeforeDeadlineAckAfterDeadline)
    defer { fixture.remove() }
    let primaryFailure = LockedSignal()
    let client = AppServerProcess(
        executableURL: fixture.executableURL,
        temporaryDirectoryRoot: fixture.probeRoot,
        waitUntilDeadline: { _ in
            let waitLimit = ContinuousClock.now.advanced(by: .seconds(3))
            while !primaryFailure.isSet && ContinuousClock.now < waitLimit {
                try await Task.sleep(for: .milliseconds(5))
            }
            try await Task.sleep(for: .milliseconds(20))
        },
        primaryFailureObserver: { primaryFailure.set() }
    )
    let clock = ContinuousClock()
    let startedAt = clock.now

    let error = await capturedProbeError {
        try await client.runProbe(timeout: .milliseconds(500))
    }
    let elapsed = startedAt.duration(to: clock.now)

    #expect(error == .malformedJSON)
    #expect(client.cleanupFailure == nil)
    #expect(client.sanitizedStderr.contains("boundary-archive-acknowledged"))
    #expect(elapsed < .seconds(5))
    #expect(!client.isChildRunning)
    #expect(try fixture.probeContents().isEmpty)
}

@Test func rejectsMismatchedResponseID() async throws {
    let fixture = try ProbeFixture(script: ServerScripts.mismatchedID)
    defer { fixture.remove() }
    let client = AppServerProcess(
        executableURL: fixture.executableURL,
        temporaryDirectoryRoot: fixture.probeRoot
    )

    let error = await capturedProbeError {
        try await client.runProbe(timeout: .seconds(3))
    }

    #expect(error == .responseIDMismatch(expected: .integer(1), actual: .integer(99)))
    #expect(try fixture.probeContents().isEmpty)
}

@Test func rejectsResponseIDWithMismatchedType() async throws {
    let fixture = try ProbeFixture(script: ServerScripts.stringID)
    defer { fixture.remove() }
    let client = AppServerProcess(
        executableURL: fixture.executableURL,
        temporaryDirectoryRoot: fixture.probeRoot
    )

    let error = await capturedProbeError {
        try await client.runProbe(timeout: .seconds(3))
    }

    #expect(error == .responseIDMismatch(
        expected: .integer(1),
        actual: .string("1")
    ))
    #expect(try fixture.probeContents().isEmpty)
}

@Test func rejectsMessageContainingBothIDAndMethod() async throws {
    let fixture = try ProbeFixture(script: ServerScripts.idAndMethod)
    defer { fixture.remove() }
    let client = AppServerProcess(
        executableURL: fixture.executableURL,
        temporaryDirectoryRoot: fixture.probeRoot
    )

    let error = await capturedProbeError {
        try await client.runProbe(timeout: .seconds(3))
    }

    #expect(error == .protocolViolation)
    #expect(try fixture.probeContents().isEmpty)
}

@Test func terminatesChildOnTimeout() async throws {
    let fixture = try ProbeFixture(script: ServerScripts.blocking)
    defer { fixture.remove() }
    let client = AppServerProcess(
        executableURL: fixture.executableURL,
        temporaryDirectoryRoot: fixture.probeRoot
    )

    let error = await capturedProbeError {
        try await client.runProbe(timeout: .milliseconds(150))
    }

    #expect(error == .timeout)
    #expect(!client.isChildRunning)
    #expect(try fixture.probeContents().isEmpty)
}

@Test func terminatesChildOnCancellation() async throws {
    let fixture = try ProbeFixture(script: ServerScripts.blocking)
    defer { fixture.remove() }
    let client = AppServerProcess(
        executableURL: fixture.executableURL,
        temporaryDirectoryRoot: fixture.probeRoot
    )
    let task = Task {
        try await client.runProbe(timeout: .seconds(5))
    }
    try await Task.sleep(for: .milliseconds(100))

    task.cancel()
    let error = await capturedProbeError { try await task.value }

    #expect(error == .cancelled)
    #expect(!client.isChildRunning)
    #expect(try fixture.probeContents().isEmpty)
}

@Test func reportsProtocolErrorWithoutLeakingServerMessage() async throws {
    let fixture = try ProbeFixture(script: ServerScripts.protocolError)
    defer { fixture.remove() }
    let client = AppServerProcess(
        executableURL: fixture.executableURL,
        temporaryDirectoryRoot: fixture.probeRoot
    )

    let error = await capturedProbeError {
        try await client.runProbe(timeout: .seconds(3))
    }

    #expect(error == .protocolError(code: -32600))
    #expect(try fixture.probeContents().isEmpty)
}

@Test func rejectsFinalAgentMessageOutsideOutputSchema() async throws {
    let fixture = try ProbeFixture(script: ServerScripts.invalidStructuredOutput)
    defer { fixture.remove() }
    let client = AppServerProcess(
        executableURL: fixture.executableURL,
        temporaryDirectoryRoot: fixture.probeRoot
    )

    let error = await capturedProbeError {
        try await client.runProbe(timeout: .seconds(3))
    }

    #expect(error == .structuredOutputRejected)
    #expect(try fixture.probeContents().isEmpty)
}

private func capturedProbeError(
    _ operation: () async throws -> CodexProbeResult
) async -> ProbeError? {
    do {
        _ = try await operation()
        return nil
    } catch let error as ProbeError {
        return error
    } catch {
        return nil
    }
}

private final class LockedSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() {
        lock.withLock { value = true }
    }
}

private struct ProbeFixture {
    let fixtureRoot: URL
    let probeRoot: URL
    let executableURL: URL

    init(script: String) throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
        fixtureRoot = temporaryRoot.appendingPathComponent(
            "codex-bridge-fixture-\(UUID().uuidString)",
            isDirectory: true
        )
        probeRoot = temporaryRoot.appendingPathComponent(
            "codex-bridge-probe-root-\(UUID().uuidString)",
            isDirectory: true
        )
        executableURL = fixtureRoot.appendingPathComponent("codex-fixture")
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: probeRoot,
            withIntermediateDirectories: false
        )
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
    }

    func probeContents() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: probeRoot,
            includingPropertiesForKeys: nil
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: fixtureRoot)
        try? FileManager.default.removeItem(at: probeRoot)
    }
}

private enum ServerScripts {
    static let blocking = #"""
    #!/bin/sh
    IFS= read -r line
    while IFS= read -r line; do :; done
    """#

    static let earlyExit = #"""
    #!/bin/sh
    printf '%s\n' 'failure path=/Users/synthetic/private token=sk-synthetic-secret' >&2
    exit 7
    """#

    static let malformed = #"""
    #!/bin/sh
    IFS= read -r line
    printf '%s\n' 'not-json'
    """#

    static let postThreadFailureWithArchiveAck = #"""
    #!/bin/sh
    IFS= read -r initialize
    printf '%s\n' '{"id":1,"result":{}}'
    IFS= read -r initialized
    IFS= read -r thread_start
    printf '%s\n' '{"id":2,"result":{"thread":{"id":"thr_synthetic"}}}'
    IFS= read -r turn_start
    printf '%s\n' 'not-json'
    IFS= read -r archive
    case "$archive" in *'"id":999'*) ;; *) exit 61 ;; esac
    case "$archive" in *'"method":"thread/archive"'*) ;; *) exit 62 ;; esac
    /bin/sleep 0.2
    printf '%s\n' 'archive-acknowledged' >&2
    printf '%s\n' '{"id":999,"result":{}}'
    """#

    static let postThreadFailureWithoutArchiveAck = #"""
    #!/bin/sh
    IFS= read -r initialize
    printf '%s\n' '{"id":1,"result":{}}'
    IFS= read -r initialized
    IFS= read -r thread_start
    printf '%s\n' '{"id":2,"result":{"thread":{"id":"thr_synthetic"}}}'
    IFS= read -r turn_start
    printf '%s\n' 'not-json'
    IFS= read -r archive
    case "$archive" in *'"id":999'*) ;; *) exit 63 ;; esac
    while IFS= read -r line; do :; done
    """#

    static let failureBeforeDeadlineAckAfterDeadline = #"""
    #!/bin/sh
    IFS= read -r initialize
    printf '%s\n' '{"id":1,"result":{}}'
    IFS= read -r initialized
    IFS= read -r thread_start
    printf '%s\n' '{"id":2,"result":{"thread":{"id":"thr_synthetic"}}}'
    IFS= read -r turn_start
    printf '%s\n' 'not-json'
    IFS= read -r archive
    case "$archive" in *'"id":999'*) ;; *) exit 64 ;; esac
    /bin/sleep 0.2
    printf '%s\n' 'boundary-archive-acknowledged' >&2
    printf '%s\n' '{"id":999,"result":{}}'
    """#

    static let mismatchedID = #"""
    #!/bin/sh
    IFS= read -r line
    printf '%s\n' '{"id":99,"result":{}}'
    """#

    static let stringID = #"""
    #!/bin/sh
    IFS= read -r line
    printf '%s\n' '{"id":"1","result":{}}'
    """#

    static let idAndMethod = #"""
    #!/bin/sh
    IFS= read -r line
    printf '%s\n' '{"id":1,"method":"thread/started","params":{}}'
    """#

    static let protocolError = #"""
    #!/bin/sh
    IFS= read -r line
    printf '%s\n' '{"id":1,"error":{"code":-32600,"message":"private server detail"}}'
    """#

    static let valid = #"""
    #!/bin/sh
    [ "$1" = "app-server" ] || { printf 'exit 41\n' >&2; exit 41; }
    [ "$2" = "--stdio" ] || { printf 'exit 42\n' >&2; exit 42; }
    IFS= read -r initialize
    case "$initialize" in *'"method":"initialize"'*) ;; *) printf 'exit 43a\n' >&2; exit 43 ;; esac
    case "$initialize" in *'"name":"daily_planner_probe"'*) ;; *) printf 'exit 43b\n' >&2; exit 43 ;; esac
    case "$initialize" in *'"version":"0.1.0"'*) ;; *) printf 'exit 43c\n' >&2; exit 43 ;; esac
    case "$initialize" in *experimentalApi*) printf 'exit 44\n' >&2; exit 44 ;; esac
    printf '%s\n' '{"id":1,"result":{"userAgent":"synthetic","platformFamily":"unix","platformOs":"macos","codexHome":"/synthetic"}}'
    IFS= read -r initialized
    case "$initialized" in *'"method":"initialized"'*) ;; *) printf 'exit 45\n' >&2; exit 45 ;; esac
    IFS= read -r thread_start
    case "$thread_start" in *'"method":"thread/start"'*) ;; *) printf 'exit 46a\n' >&2; exit 46 ;; esac
    case "$thread_start" in *'"approvalPolicy":"never"'*) ;; *) printf 'exit 46b\n' >&2; exit 46 ;; esac
    case "$thread_start" in *'"sandbox":"read-only"'*) ;; *) printf 'exit 46c\n' >&2; exit 46 ;; esac
    case "$thread_start" in *'"serviceName":"daily_planner_probe"'*) ;; *) printf 'exit 46d\n' >&2; exit 46 ;; esac
    case "$thread_start" in *dynamicTools*) printf 'exit 47\n' >&2; exit 47 ;; esac
    printf '%s\n' '{"id":2,"result":{"thread":{"id":"thr_synthetic"}}}'
    IFS= read -r turn_start
    case "$turn_start" in *'"method":"turn/start"'*) ;; *) printf 'exit 48a\n' >&2; exit 48 ;; esac
    case "$turn_start" in *'Return exactly the structured probe result.'*) ;; *) printf 'exit 48b\n' >&2; exit 48 ;; esac
    case "$turn_start" in *'"const":"daily-planner-probe"'*) ;; *) printf 'exit 48c\n' >&2; exit 48 ;; esac
    case "$turn_start" in *'"enum":["ok"]'*) ;; *) printf 'exit 48d\n' >&2; exit 48 ;; esac
    printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn_synthetic","status":"inProgress"}}}'
    printf '%s\n' '{"method":"item/completed","params":{"threadId":"thr_synthetic","turnId":"turn_synthetic","completedAtMs":1,"item":{"id":"item_synthetic","type":"agentMessage","text":"{\"source\":\"daily-planner-probe\",\"status\":\"ok\"}"}}}'
    printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thr_synthetic","turn":{"id":"turn_synthetic","items":[],"status":"completed"}}}'
    IFS= read -r archive
    case "$archive" in *'"method":"thread/archive"'*) ;; *) printf 'exit 49a\n' >&2; exit 49 ;; esac
    case "$archive" in *'"threadId":"thr_synthetic"'*) ;; *) printf 'exit 49b\n' >&2; exit 49 ;; esac
    printf '%s\n' '{"id":4,"result":{}}'
    """#

    static let invalidStructuredOutput = #"""
    #!/bin/sh
    IFS= read -r initialize
    printf '%s\n' '{"id":1,"result":{}}'
    IFS= read -r initialized
    IFS= read -r thread_start
    printf '%s\n' '{"id":2,"result":{"thread":{"id":"thr_synthetic"}}}'
    IFS= read -r turn_start
    printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn_synthetic","status":"inProgress"}}}'
    printf '%s\n' '{"method":"item/completed","params":{"threadId":"thr_synthetic","turnId":"turn_synthetic","completedAtMs":1,"item":{"id":"item_synthetic","type":"agentMessage","text":"{\"source\":\"unexpected\",\"status\":\"nope\"}"}}}'
    printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thr_synthetic","turn":{"id":"turn_synthetic","items":[],"status":"completed"}}}'
    IFS= read -r archive
    printf '%s\n' '{"id":4,"result":{}}'
    """#
}
