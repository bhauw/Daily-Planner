import DailyPlannerDomain
import Foundation
import XCTest
@testable import DailyPlannerPlatform

/// The subprocess mechanics, driven against ordinary system tools rather than the real CLI.
///
/// `/bin/cat` echoes stdin, so it proves the prompt is delivered on stdin and the reply is read
/// back off stdout. `/usr/bin/yes` never stops printing, which is the case that matters: an
/// unbounded read is a memory problem, not a slow one. Using the real `claude` here would make
/// the suite slow, non-deterministic, and would spend Braxton's subscription on every run.
final class ClaudeCodeReplyWriterTests: XCTestCase {
    /// The system tools used below do not accept the real CLI's flags, so the arguments are
    /// injected empty. Everything being exercised — stdin delivery, bounded reads, timeouts,
    /// exit status — is independent of them.
    private func writer(
        _ path: String,
        timeout: Duration = .seconds(10),
        arguments: [String] = []
    ) -> ClaudeCodeReplyWriter {
        ClaudeCodeReplyWriter(executable: URL(filePath: path), timeout: timeout, arguments: arguments)
    }

    func testThePromptGoesInOnStdinAndTheReplyComesBackOffStdout() async throws {
        // `cat` returns exactly what it was given, so what comes back IS what was sent.
        let echoed = try await writer("/bin/cat").run(prompt: "Subject: Interview\nCan you do 14:30?")
        XCTAssertTrue(echoed.contains("Can you do 14:30?"))
    }

    func testTheEmailNeverAppearsInTheProcessArguments() async throws {
        // Break caught: the prompt is moved to argv for convenience. Arguments are readable by
        // every process on the machine through `ps`, so that would publish locally the exact
        // content this app is otherwise careful about.
        let request = try PlannerReplyRequest(
            subject: "Interview Thursday",
            sender: "recruiter@example.com",
            snippet: "Can you do 14:30?",
            intent: .accept,
            isPrivate: false
        )
        let prompt = PlannerReplyPrompt.text(for: request)
        XCTAssertTrue(prompt.contains("recruiter@example.com"), "the prompt is what carries it")

        // Production's arguments are a fixed triple with no request data in them at all.
        let production = ClaudeCodeReplyWriter(executable: URL(filePath: "/bin/cat"))
        XCTAssertEqual(production.arguments, ["-p", "--max-turns", "1"])
        for argument in production.arguments {
            XCTAssertFalse(argument.contains("recruiter@example.com"))
            XCTAssertFalse(argument.contains("14:30"))
            XCTAssertFalse(argument.contains("Interview"))
        }
    }

    func testANonZeroExitIsUnavailableRatherThanAnEmptyDraft() async {
        // Break caught: a failed CLI yields "" and the user is shown a blank reply as though it
        // were an answer.
        await assertThrows(.unavailable) { try await self.writer("/usr/bin/false").run(prompt: "x") }
    }

    func testAMissingExecutableIsUnavailable() async {
        await assertThrows(.unavailable) {
            try await self.writer("/nonexistent/claude").run(prompt: "x")
        }
    }

    func testATimeoutTerminatesTheProcessAndDiscardsWhateverItSaid() async {
        // A half-written reply is worse than none: it would be presented as complete.
        // The assertion that matters is the ELAPSED TIME, not the error. Racing the read
        // against a sleep inside a task group produced the right error after 30 seconds,
        // because a task group waits for every child and a blocked read cannot be cancelled.
        // The timeout has to kill the child; that is what releases the read.
        let start = Date()
        await assertThrows(.unavailable) {
            try await self.writer(
                "/bin/sleep", timeout: .milliseconds(300), arguments: ["30"]
            ).run(prompt: "x")
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(start), 5,
            "the timeout must bound the call, not merely report on it afterwards"
        )
    }

    func testAnEndlessTalkerIsCutOffRatherThanReadIntoMemory() async {
        // `yes` prints forever. The ceiling has to apply DURING the read — checking the size
        // after `readToEnd` would mean growing without bound first and only then complaining.
        await assertThrows(.tooLarge) {
            try await self.writer("/usr/bin/yes", timeout: .seconds(20)).run(prompt: "x")
        }
    }

    // MARK: - Finding the CLI

    func testLocateFindsAnExecutableAndIgnoresOneThatIsNot() throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "locate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let home = directory.appending(path: "home")
        let binary = home.appending(path: ".local/bin")
        try FileManager.default.createDirectory(at: binary, withIntermediateDirectories: true)
        let claude = binary.appending(path: "claude")

        // `searchPath: nil` so the real CLI on this machine cannot answer for the fixture.
        // Without that the test passed for the wrong reason: it found ~/.local/bin/claude.
        // Present but not executable is not a usable answer.
        try Data("#!/bin/sh\n".utf8).write(to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: claude.path)
        XCTAssertNil(ClaudeCodeReplyWriter.locate(home: home, searchPath: nil))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        XCTAssertEqual(
            ClaudeCodeReplyWriter.locate(home: home, searchPath: nil)?.path, claude.path
        )
    }

    func testLocateFindsNothingWhenThereIsNothingToFind() {
        // Break caught: an absent CLI resolves to some path anyway, so the app reports that it
        // can draft and every attempt fails at the point of use instead of the offer never
        // appearing.
        let nowhere = URL(filePath: "/nonexistent-home-\(UUID().uuidString)")
        XCTAssertNil(ClaudeCodeReplyWriter.locate(home: nowhere, searchPath: nil))
        XCTAssertNil(ClaudeCodeReplyWriter.locate(home: nowhere, searchPath: "/nonexistent-bin"))
    }

    // MARK: - The environment the child gets

    /*
     * Every draft failed with a flat "provider-unavailable" while the same CLI worked perfectly
     * from a terminal. The cause was the deliberately bare environment: with only HOME and PATH
     * the CLI cannot resolve the signed-in subscription and exits 1 saying "Not logged in".
     * A terminal passes USER; this did not.
     *
     * These pin the fix from both ends — that USER is passed, and that the bareness it was
     * protecting is still real.
     */

    func testTheChildIsGivenUSER_withoutItTheCLIReportsItIsNotLoggedIn() {
        let environment = ClaudeCodeReplyWriter.childEnvironment(
            ["HOME": "/Users/x", "PATH": "/usr/bin", "USER": "x"]
        )
        XCTAssertEqual(environment["USER"], "x")
    }

    func testUSERFallsBackToTheCurrentUserWhenTheAppDidNotInheritIt() {
        // The case that actually bites: a GUI-launched app inherits far less than a shell.
        let environment = ClaudeCodeReplyWriter.childEnvironment(["HOME": "/Users/x", "PATH": "/usr/bin"])
        XCTAssertEqual(environment["USER"], NSUserName())
        XCTAssertFalse(environment["USER"]?.isEmpty ?? true)
    }

    func testHomeAndPathFallBackRatherThanGoingMissing() {
        let environment = ClaudeCodeReplyWriter.childEnvironment([:])
        XCTAssertEqual(environment["HOME"], NSHomeDirectory())
        XCTAssertFalse(environment["PATH"]?.isEmpty ?? true)
    }

    func testTheChildIsGivenNothingElse() {
        // The point of the bare environment: no token or setting belonging to whatever launched
        // the app reaches the child. Adding USER must not have become "pass everything".
        let environment = ClaudeCodeReplyWriter.childEnvironment([
            "HOME": "/Users/x",
            "PATH": "/usr/bin",
            "USER": "x",
            "AWS_SECRET_ACCESS_KEY": "shhh",
            "GOOGLE_OAUTH_TOKEN": "shhh",
        ])
        XCTAssertEqual(Set(environment.keys), ["HOME", "PATH", "USER"])
    }

    // MARK: - Signed out is not the same as unreachable

    func testASignedOutCLIIsReportedAsSignedOutRatherThanUnreachable() async {
        // `printf` writes the CLI's own refusal to stdout and exits non-zero, which is exactly
        // what the real one does when nobody is logged in.
        let signedOut = ClaudeCodeReplyWriter(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "printf 'Not logged in \u{00B7} Please run /login'; exit 1"]
        )
        do {
            _ = try await signedOut.run(prompt: "anything")
            XCTFail("a signed-out CLI must not look like a successful draft")
        } catch let error as PlannerDraftingError {
            XCTAssertEqual(error, .notSignedIn)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testAnOrdinaryFailureIsStillUnavailableAndNotBlamedOnSigningIn() async {
        // Telling someone to run /login when the CLI crashed would send them to fix the wrong
        // thing, so only the CLI's own sign-in phrases may produce that answer.
        let broken = ClaudeCodeReplyWriter(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "printf 'segmentation fault'; exit 1"]
        )
        do {
            _ = try await broken.run(prompt: "anything")
            XCTFail("a crashing CLI must not look like a successful draft")
        } catch let error as PlannerDraftingError {
            XCTAssertEqual(error, .unavailable)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testTheSignedOutPhrasesAreMatchedCaseInsensitivelyAndNothingElseIs() {
        XCTAssertTrue(ClaudeCodeReplyWriter.sayingItIsSignedOut("Not Logged In"))
        XCTAssertTrue(ClaudeCodeReplyWriter.sayingItIsSignedOut("please run /login"))
        XCTAssertTrue(ClaudeCodeReplyWriter.sayingItIsSignedOut("Invalid API key"))
        XCTAssertFalse(ClaudeCodeReplyWriter.sayingItIsSignedOut("could not connect to host"))
        XCTAssertFalse(ClaudeCodeReplyWriter.sayingItIsSignedOut(""))
    }

    func testTheProviderSaysContentLeavesTheMachine() {
        // The safety rail reads this rather than assuming. A local-model adapter implementing
        // the same port answers false, and the rail changes on its own.
        let writer = writer("/bin/cat")
        XCTAssertTrue(writer.contentLeavesMachine)
        XCTAssertFalse(writer.providerLabel.isEmpty)
    }

    private func assertThrows(
        _ expected: PlannerDraftingError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> String
    ) async {
        do {
            let value = try await body()
            XCTFail("expected \(expected), got \(value.prefix(40))", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? PlannerDraftingError, expected, file: file, line: line)
        }
    }
}
