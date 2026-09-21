import Darwin
import Foundation

public struct CodexProbeResult: Codable, Sendable, Equatable {
    public let protocolVersion: String
    public let threadStarted: Bool
    public let turnCompleted: Bool
    public let structuredStatus: String
    public let cleanupSucceeded: Bool

    public init(
        protocolVersion: String,
        threadStarted: Bool,
        turnCompleted: Bool,
        structuredStatus: String,
        cleanupSucceeded: Bool
    ) {
        self.protocolVersion = protocolVersion
        self.threadStarted = threadStarted
        self.turnCompleted = turnCompleted
        self.structuredStatus = structuredStatus
        self.cleanupSucceeded = cleanupSucceeded
    }
}

public enum ProbeError: Error, Sendable, Equatable {
    case missingExecutable
    case launchFailed
    case earlyChildExit
    case malformedJSON
    case responseIDMismatch(expected: RequestID, actual: RequestID)
    case timeout
    case cancelled
    case protocolError(code: Int?)
    case protocolViolation
    case structuredOutputRejected
}

public enum ProbeCleanupFailure: String, Sendable, Equatable {
    case archiveNotAcknowledged
    case workingDirectoryRemovalFailed
}

public final class AppServerProcess: @unchecked Sendable {
    private enum StopReason {
        case timeout
        case cancelled
    }

    private enum DeadlineState {
        case running
        case primaryFailureEstablished
        case timedOut
    }

    private enum RaceOutcome: Sendable {
        case sessionSucceeded(CodexProbeResult)
        case sessionFailed(ProbeError)
        case timedOut
        case deadlineSuppressed
    }

    private let executableURL: URL
    private let temporaryDirectoryRoot: URL
    private let waitUntilDeadline: @Sendable (Duration) async throws -> Void
    private let primaryFailureObserver: @Sendable () -> Void
    private let stateLock = NSLock()
    private var child: Process?
    private var stopReason: StopReason?
    private var deadlineState: DeadlineState = .running
    private var stopping = false
    private var retainedStderr = ""
    private var recordedCleanupFailure: ProbeCleanupFailure?

    public init(
        executableURL: URL,
        temporaryDirectoryRoot: URL = FileManager.default.temporaryDirectory
    ) {
        self.executableURL = executableURL
        self.temporaryDirectoryRoot = temporaryDirectoryRoot
        waitUntilDeadline = { duration in try await Task.sleep(for: duration) }
        primaryFailureObserver = {}
    }

    init(
        executableURL: URL,
        temporaryDirectoryRoot: URL,
        waitUntilDeadline: @escaping @Sendable (Duration) async throws -> Void,
        primaryFailureObserver: @escaping @Sendable () -> Void
    ) {
        self.executableURL = executableURL
        self.temporaryDirectoryRoot = temporaryDirectoryRoot
        self.waitUntilDeadline = waitUntilDeadline
        self.primaryFailureObserver = primaryFailureObserver
    }

    public var sanitizedStderr: String {
        stateLock.withLock { retainedStderr }
    }

    public var isChildRunning: Bool {
        stateLock.withLock { child?.isRunning ?? false }
    }

    public var cleanupFailure: ProbeCleanupFailure? {
        stateLock.withLock { recordedCleanupFailure }
    }

    public static func resolveCodexExecutable() throws -> URL {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["codex"]
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw ProbeError.missingExecutable
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let data = try? stdout.fileHandleForReading.readToEnd(),
              let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path)
        else {
            throw ProbeError.missingExecutable
        }
        return URL(fileURLWithPath: path)
    }

    public func runProbe(timeout: Duration = .seconds(60)) async throws -> CodexProbeResult {
        stateLock.withLock {
            stopReason = nil
            deadlineState = .running
            stopping = false
            retainedStderr = ""
            recordedCleanupFailure = nil
        }

        let result = await withTaskCancellationHandler {
            await withTaskGroup(
                of: RaceOutcome.self,
                returning: Result<CodexProbeResult, ProbeError>.self
            ) { group in
                group.addTask {
                    do {
                        return .sessionSucceeded(try await self.runSession())
                    } catch {
                        return .sessionFailed(self.normalizedError(error))
                    }
                }
                group.addTask {
                    do {
                        try await self.waitUntilDeadline(timeout)
                    } catch {
                        return .deadlineSuppressed
                    }
                    guard self.claimTimeout() else {
                        return .deadlineSuppressed
                    }
                    self.stopChild(reason: nil)
                    return .timedOut
                }

                defer { group.cancelAll() }
                while let outcome = await group.next() {
                    switch outcome {
                    case let .sessionSucceeded(value): return .success(value)
                    case let .sessionFailed(error): return .failure(error)
                    case .timedOut: return .failure(.timeout)
                    case .deadlineSuppressed: continue
                    }
                }
                return .failure(.earlyChildExit)
            }
        } onCancel: {
            self.stopChild(reason: .cancelled)
        }
        return try result.get()
    }

    private func runSession() async throws -> CodexProbeResult {
        let fileManager = FileManager.default
        let workingDirectory = temporaryDirectoryRoot.appendingPathComponent(
            "daily-planner-codex-probe-\(UUID().uuidString)",
            isDirectory: true
        )
        var threadID: String?
        var archiveAcknowledged = false

        do {
            try fileManager.createDirectory(
                at: workingDirectory,
                withIntermediateDirectories: false
            )
        } catch {
            throw ProbeError.launchFailed
        }

        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            try? fileManager.removeItem(at: workingDirectory)
            throw ProbeError.missingExecutable
        }

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        do {
            try process.run()
        } catch {
            try? fileManager.removeItem(at: workingDirectory)
            throw ProbeError.launchFailed
        }
        register(process)
        stdin.fileHandleForReading.closeFile()
        stdout.fileHandleForWriting.closeFile()
        stderr.fileHandleForWriting.closeFile()

        let stderrCollector = DataCollector()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stderrCollector.append(data) }
        }
        var lines = stdout.fileHandleForReading.bytes.lines.makeAsyncIterator()

        do {
            try write(
                method: "initialize",
                id: .integer(1),
                params: [
                    "clientInfo": .object([
                        "name": .string("daily_planner_probe"),
                        "version": .string("0.1.0"),
                    ]),
                ],
                to: stdin.fileHandleForWriting
            )
            _ = try await readResponse(expectedID: .integer(1), from: &lines)

            try write(
                method: "initialized",
                params: [:],
                to: stdin.fileHandleForWriting
            )
            try write(
                method: "thread/start",
                id: .integer(2),
                params: [
                    "cwd": .string(workingDirectory.path),
                    "approvalPolicy": .string("never"),
                    "sandbox": .string("read-only"),
                    "serviceName": .string("daily_planner_probe"),
                ],
                to: stdin.fileHandleForWriting
            )
            let threadResponse = try await readResponse(expectedID: .integer(2), from: &lines)
            guard let startedThreadID = threadResponse.threadID else {
                throw ProbeError.malformedJSON
            }
            threadID = startedThreadID

            try write(
                method: "turn/start",
                id: .integer(3),
                params: [
                    "threadId": .string(startedThreadID),
                    "input": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string("Return exactly the structured probe result."),
                        ]),
                    ]),
                    "outputSchema": Self.outputSchema,
                ],
                to: stdin.fileHandleForWriting
            )
            let turnResponse = try await readResponse(expectedID: .integer(3), from: &lines)
            guard let startedTurnID = turnResponse.turnID else {
                throw ProbeError.malformedJSON
            }

            var state = ProbeStateMachine()
            state.accept(.thread(id: startedThreadID))
            state.accept(.turnStarted(id: startedTurnID))
            var agentMessage: String?

            while state.phase != .completed {
                let message = try await readMessage(from: &lines)
                switch message.envelope {
                case .notification:
                    break
                case .response, .invalid:
                    throw ProbeError.protocolViolation
                }
                guard message.threadID == startedThreadID,
                      message.turnID == startedTurnID
                else { continue }

                if let text = message.agentMessageText {
                    agentMessage = text
                }
                if message.method == "turn/completed",
                   let status = message.turnStatus {
                    if status != "completed" {
                        throw ProbeError.protocolError(code: nil)
                    }
                    state.accept(.turnCompleted(id: startedTurnID, status: status))
                }
            }

            try write(
                method: "thread/archive",
                id: .integer(4),
                params: ["threadId": .string(startedThreadID)],
                to: stdin.fileHandleForWriting
            )
            _ = try await readResponse(expectedID: .integer(4), from: &lines)
            archiveAcknowledged = true

            guard Self.isValidStructuredOutput(agentMessage) else {
                throw ProbeError.structuredOutputRejected
            }

            stopChild(reason: nil)
            let rawStderr = finishCollectingStderr(stderr, collector: stderrCollector)
            retainSanitizedStderr(rawStderr, workingDirectory: workingDirectory)
            let cleanupSucceeded = removeWorkingDirectory(workingDirectory)
            if !cleanupSucceeded { recordCleanupFailure(.workingDirectoryRemovalFailed) }
            clearChild()
            return CodexProbeResult(
                protocolVersion: "v2",
                threadStarted: true,
                turnCompleted: true,
                structuredStatus: "ok",
                cleanupSucceeded: cleanupSucceeded
            )
        } catch {
            establishPrimaryFailure()
            let originalError = normalizedError(error)
            if let threadID, !archiveAcknowledged {
                let acknowledged = await archiveAfterFailure(
                    threadID: threadID,
                    lines: &lines,
                    stdin: stdin.fileHandleForWriting
                )
                if !acknowledged { recordCleanupFailure(.archiveNotAcknowledged) }
            }
            stopChild(reason: nil)
            let rawStderr = finishCollectingStderr(stderr, collector: stderrCollector)
            retainSanitizedStderr(rawStderr, workingDirectory: workingDirectory)
            if !removeWorkingDirectory(workingDirectory) {
                recordCleanupFailure(.workingDirectoryRemovalFailed)
            }
            clearChild()
            throw originalError
        }
    }

    private func archiveAfterFailure<Iterator: AsyncIteratorProtocol>(
        threadID: String,
        lines: inout Iterator,
        stdin: FileHandle
    ) async -> Bool where Iterator.Element == String {
        do {
            try write(
                method: "thread/archive",
                id: .integer(999),
                params: ["threadId": .string(threadID)],
                to: stdin
            )
        } catch {
            return false
        }

        let deadline = Task {
            try await Task.sleep(for: .milliseconds(750))
            self.stopChild(reason: nil)
        }
        defer { deadline.cancel() }

        do {
            _ = try await readResponse(expectedID: .integer(999), from: &lines)
            return true
        } catch {
            return false
        }
    }

    private func normalizedError(_ error: any Error) -> ProbeError {
        if let reason = currentStopReason() {
            switch reason {
            case .timeout: return .timeout
            case .cancelled: return .cancelled
            }
        }
        if error is CancellationError { return .cancelled }
        if let probeError = error as? ProbeError { return probeError }
        return .earlyChildExit
    }

    private func readResponse<Iterator: AsyncIteratorProtocol>(
        expectedID: RequestID,
        from lines: inout Iterator
    ) async throws -> AppServerMessage where Iterator.Element == String {
        while true {
            let message = try await readMessage(from: &lines)
            let actualID: RequestID
            switch message.envelope {
            case let .response(id): actualID = id
            case .notification: continue
            case .invalid: throw ProbeError.protocolViolation
            }
            guard actualID == expectedID else {
                throw ProbeError.responseIDMismatch(expected: expectedID, actual: actualID)
            }
            if let error = message.error {
                throw ProbeError.protocolError(code: error.code)
            }
            return message
        }
    }

    private func readMessage<Iterator: AsyncIteratorProtocol>(
        from lines: inout Iterator
    ) async throws -> AppServerMessage where Iterator.Element == String {
        guard let line = try await lines.next() else {
            throw ProbeError.earlyChildExit
        }
        do {
            return try AppServerMessage.decode(line)
        } catch {
            throw ProbeError.malformedJSON
        }
    }

    private func write(
        method: String,
        id: RequestID? = nil,
        params: [String: JSONValue],
        to handle: FileHandle
    ) throws {
        var request: [String: JSONValue] = [
            "method": .string(method),
            "params": .object(params),
        ]
        if let id {
            switch id {
            case let .integer(value): request["id"] = .integer(Int(value))
            case let .string(value): request["id"] = .string(value)
            }
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            var data = try encoder.encode(request)
            data.append(0x0A)
            try handle.write(contentsOf: data)
        } catch {
            throw ProbeError.earlyChildExit
        }
    }

    private static let outputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "source": .object([
                "type": .string("string"),
                "const": .string("daily-planner-probe"),
            ]),
            "status": .object([
                "type": .string("string"),
                "enum": .array([.string("ok")]),
            ]),
        ]),
        "required": .array([.string("source"), .string("status")]),
        "additionalProperties": .boolean(false),
    ])

    private static func isValidStructuredOutput(_ text: String?) -> Bool {
        guard let text,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              dictionary.count == 2,
              dictionary["source"] as? String == "daily-planner-probe",
              dictionary["status"] as? String == "ok"
        else { return false }
        return true
    }

    private func register(_ process: Process) {
        stateLock.withLock {
            child = process
            stopping = false
        }
    }

    private func stopChild(reason: StopReason?) {
        let process: Process? = stateLock.withLock {
            guard !stopping else { return nil }
            if let reason, stopReason == nil { stopReason = reason }
            stopping = true
            return child
        }
        guard let process else { return }
        guard process.isRunning else { return }

        process.standardInput.flatMap { $0 as? Pipe }?.fileHandleForWriting.closeFile()
        process.terminate()
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while process.isRunning && ContinuousClock.now < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private func clearChild() {
        stateLock.withLock {
            child = nil
            stopping = false
        }
    }

    private func currentStopReason() -> StopReason? {
        stateLock.withLock { stopReason }
    }

    private func establishPrimaryFailure() {
        let didEstablish = stateLock.withLock {
            guard deadlineState == .running else { return false }
            deadlineState = .primaryFailureEstablished
            return true
        }
        if didEstablish { primaryFailureObserver() }
    }

    private func claimTimeout() -> Bool {
        stateLock.withLock {
            guard deadlineState == .running else { return false }
            deadlineState = .timedOut
            if stopReason == nil { stopReason = .timeout }
            return true
        }
    }

    private func retainSanitizedStderr(_ data: Data, workingDirectory: URL) {
        let raw = String(data: data, encoding: .utf8) ?? ""
        let sanitized = Self.redact(raw, workingDirectory: workingDirectory)
        stateLock.withLock { retainedStderr = sanitized }
    }

    private func recordCleanupFailure(_ failure: ProbeCleanupFailure) {
        stateLock.withLock {
            if recordedCleanupFailure == nil { recordedCleanupFailure = failure }
        }
    }

    private func finishCollectingStderr(_ pipe: Pipe, collector: DataCollector) -> Data {
        pipe.fileHandleForReading.readabilityHandler = nil
        if let remainder = try? pipe.fileHandleForReading.readToEnd() {
            collector.append(remainder)
        }
        return collector.data
    }

    private func removeWorkingDirectory(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return !FileManager.default.fileExists(atPath: url.path)
        } catch {
            return false
        }
    }

    private static func redact(_ text: String, workingDirectory: URL) -> String {
        var result = text
            .replacingOccurrences(of: workingDirectory.path, with: "<redacted-path>")
            .replacingOccurrences(of: NSHomeDirectory(), with: "<redacted-path>")
        let replacements = [
            (#"/(?:Users|private|tmp|var|Volumes)/[^\s\"']+"#, "<redacted-path>"),
            (#"sk-[A-Za-z0-9_-]+"#, "<redacted-token>"),
            (#"Bearer\s+[^\s\"']+"#, "Bearer <redacted-token>"),
        ]
        for (pattern, replacement) in replacements {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: replacement
            )
        }
        return result
    }
}

private final class DataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data { lock.withLock { storage } }

    func append(_ data: Data) {
        lock.withLock { storage.append(data) }
    }
}
