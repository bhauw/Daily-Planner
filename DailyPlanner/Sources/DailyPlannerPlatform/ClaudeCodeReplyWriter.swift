import DailyPlannerDomain
import Foundation

/*
 * Drafting a reply through the Claude Code CLI, on Braxton's own subscription.
 *
 * He asked for generation that does not need an API key. The CLI already on this machine is
 * signed in to his subscription, so the app spawns it rather than holding a credential of its
 * own — there is no key here to leak, and nothing to configure.
 *
 * The prompt goes in on STDIN, never as an argument. Arguments are visible to every process on
 * the machine through `ps`; a reply prompt contains someone's email, so putting it in argv would
 * publish locally the thing this app is otherwise careful about. Stdin is also why there is no
 * length limit to work around and nothing to quote or escape.
 *
 * `Process` with an argument array, never a shell. There is no command string for a subject line
 * to end up inside of.
 *
 * This provider sends content off the machine. It says so — `contentLeavesMachine` is true — and
 * the safety rail reads that rather than assuming. A local-model adapter implementing the same
 * port would answer false, and the rail would change on its own.
 */
public struct ClaudeCodeReplyWriter: PlannerReplyDrafting, Sendable {
    /// Where the CLI is. Resolved once at composition time, not searched for per request.
    public let executable: URL
    public let timeout: Duration
    /// The CLI flags.
    ///
    /// `--max-turns 1` because this is one question and one answer: without it the CLI is an
    /// agent that could decide to go and DO something, and the only thing wanted here is text.
    ///
    /// Injectable so the tests can drive the subprocess machinery with ordinary system tools —
    /// `cat`, `false`, `yes` — which do not accept these flags. Production never passes it.
    public let arguments: [String]

    public var providerLabel: String { "Claude (your subscription)" }
    public var contentLeavesMachine: Bool { true }

    public init(
        executable: URL,
        timeout: Duration = .seconds(90),
        arguments: [String] = ["-p", "--max-turns", "1"]
    ) {
        self.executable = executable
        self.timeout = timeout
        self.arguments = arguments
    }

    /// The usual places a Node-installed CLI lands, plus anything already on PATH.
    ///
    /// `which` is not used: it runs a shell, and the shell it runs depends on the user's
    /// profile. This checks paths directly, so the answer does not depend on how the app
    /// happened to be launched — a GUI app has a very different PATH from a terminal.
    /// `searchPath` is passed in rather than read from the environment here, so the answer is a
    /// function of its arguments. Reading ambient `PATH` inside made this untestable: a test
    /// pointing at a fixture home still found the real CLI through `PATH` and passed for the
    /// wrong reason.
    public static func locate(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        searchPath: String? = ProcessInfo.processInfo.environment["PATH"],
        fileManager: FileManager = .default
    ) -> URL? {
        var candidates = [
            home.appending(path: ".local/bin/claude"),
            home.appending(path: ".claude/local/claude"),
            URL(filePath: "/opt/homebrew/bin/claude"),
            URL(filePath: "/usr/local/bin/claude"),
        ]
        if let searchPath {
            candidates += searchPath.split(separator: ":").map {
                URL(filePath: String($0)).appending(path: "claude")
            }
        }
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    public func draft(_ request: PlannerReplyRequest) async throws -> PlannerProposedReply {
        let output = try await run(prompt: PlannerReplyPrompt.text(for: request))
        return try PlannerProposedReply(body: output, provider: providerLabel)
    }

    /// The environment the CLI is given. A decision, not a detail — so it is a pure function of
    /// its input and is tested without spawning anything.
    ///
    /// Deliberately bare: nothing belonging to whatever launched the app is passed along, so no
    /// token or setting of the parent's leaks into the child.
    ///
    /// THREE variables, and USER is not optional however redundant it looks. The CLI resolves the
    /// signed-in subscription against the current user; with only HOME and PATH it does not find
    /// the credentials, prints "Not logged in - Please run /login" and exits 1. That surfaced as
    /// a flat `provider-unavailable` on every draft while the same CLI worked fine from a
    /// terminal — because a terminal passes USER and this did not. Established by elimination:
    /// HOME+PATH fails, HOME+PATH+USER succeeds.
    ///
    /// The fallbacks are APIs rather than literals because a GUI-launched app inherits far less
    /// than a shell does, and that is exactly the case this has to work in.
    static func childEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        [
            "HOME": environment["HOME"] ?? NSHomeDirectory(),
            "PATH": environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
            "USER": environment["USER"] ?? NSUserName(),
        ]
    }

    /// Runs the CLI once and returns what it printed.
    func run(prompt: String) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = Self.childEnvironment()

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw PlannerDraftingError.unavailable
        }

        stdin.fileHandleForWriting.write(Data(prompt.utf8))
        try? stdin.fileHandleForWriting.close()

        // Read while it runs, in chunks, with a hard ceiling.
        //
        // Draining matters: a pipe buffer that fills with nobody reading it deadlocks the
        // child, which would present as a timeout that no amount of waiting fixes. The ceiling
        // matters separately — reading to end from a process that never stops printing grows
        // without bound, so the limit applies DURING the read, not after it.
        //
        // The read happens on a DISPATCH QUEUE, not in a `Task`. `availableData` blocks, and a
        // blocking call inside a task occupies one of Swift concurrency's cooperative threads;
        // with a few in flight the pool starves and nothing finishes.
        //
        // The timeout works by KILLING THE CHILD, not by abandoning the read. That distinction
        // is the whole correctness of this function. Racing the read against a sleep inside a
        // task group does not work: a task group does not return until every child finishes,
        // and a blocked `withCheckedContinuation` cannot be cancelled — so a hung CLI held the
        // call for as long as it chose to live, timeout or not. Terminating closes the pipe,
        // which is what actually releases the reader.
        let watchdog = Timeout()
        let deadline = Task { [timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            watchdog.fire()
            process.terminate()
        }

        let (data, overflowed) = await Self.readBounded(
            stdout.fileHandleForReading,
            limit: PlannerProposedReply.maxBodyBytes
        )
        deadline.cancel()

        if watchdog.didFire {
            // Terminated by the deadline. Whatever was read is discarded: a half-written reply
            // is worse than none, because it would be presented as a complete draft.
            throw PlannerDraftingError.unavailable
        }

        if overflowed {
            // Still talking. Stop it, which closes the pipe.
            process.terminate()
            throw PlannerDraftingError.tooLarge
        }

        // The pipe is closed, so the child is exiting; this returns promptly.
        process.waitUntilExit()
        let errorText = String(data: (try? stderr.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            // "Your assistant is unavailable" and "you are signed out" need different actions
            // from the person reading them, so they are not collapsed into one message. The CLI
            // says so on stdout, not stderr, which is why both are checked.
            let said = Self.sayingItIsSignedOut(String(data: data, encoding: .utf8) ?? "")
                || Self.sayingItIsSignedOut(errorText)
            throw said ? PlannerDraftingError.notSignedIn : PlannerDraftingError.unavailable
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw PlannerDraftingError.emptyReply
        }
        return text
    }

    /// Whether the CLI refused because nobody is signed in to it.
    ///
    /// Matched on the phrases it actually prints rather than on an exit code: exit 1 covers every
    /// way it can fail, and telling someone to run `/login` when the real problem is something
    /// else would send them off fixing the wrong thing.
    static func sayingItIsSignedOut(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("not logged in")
            || text.contains("please run /login")
            || text.contains("invalid api key")
    }

    /// Whether the deadline fired, shared between the watchdog task and the caller.
    ///
    /// A class with a lock rather than a captured `var`: the watchdog writes it from another
    /// task while the caller reads it, and that is a data race however small.
    private final class Timeout: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false

        func fire() {
            lock.lock()
            fired = true
            lock.unlock()
        }

        var didFire: Bool {
            lock.lock()
            defer { lock.unlock() }
            return fired
        }
    }

    /// Drains a pipe up to `limit` bytes, off the cooperative pool.
    ///
    /// Returns the bytes read and whether the limit was passed. Stopping at the limit rather
    /// than reading to the end is what keeps a runaway generation from becoming a memory
    /// problem instead of merely a rejected one.
    private static func readBounded(_ handle: FileHandle, limit: Int) async -> (Data, Bool) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var data = Data()
                var overflowed = false
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    data.append(chunk)
                    if data.count > limit {
                        overflowed = true
                        break
                    }
                }
                continuation.resume(returning: (data, overflowed))
            }
        }
    }
}
