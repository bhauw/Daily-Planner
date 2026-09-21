import Foundation
import XCTest
@testable import SecurityBoundaryCore

final class SecurityBoundaryCoreTests: XCTestCase {
    private let fileManager = FileManager.default

    func testBookmarkProbeReportsEverySuccessfulStage() throws {
        let temporaryRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let vault = try makeFakeVault(in: temporaryRoot)
        let outcome = BookmarkBoundaryProbe(
            store: BookmarkStore(storageURL: temporaryRoot.appending(path: "bookmark.data"))
        ).run(
            fakeVault: vault,
            movedVault: temporaryRoot.appending(path: "MovedFakeVault", directoryHint: .isDirectory),
            noteRelativePath: "Daily/2026-08-30.md",
            expectedNote: Data("synthetic boundary probe note\n".utf8)
        )

        XCTAssertEqual(outcome.save, .passed)
        XCTAssertEqual(outcome.resolveRead, .passed)
        XCTAssertEqual(outcome.move, .passed)
        XCTAssertEqual(outcome.staleResolveRead, .passed)
        XCTAssertEqual(outcome.firstFailureStage, .none)
    }

    func testMoveFailureDoesNotEraseSuccessfulSaveOrResolveReadStages() throws {
        let temporaryRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let vault = try makeFakeVault(in: temporaryRoot)
        let occupiedDestination = temporaryRoot.appending(path: "MovedFakeVault", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: occupiedDestination, withIntermediateDirectories: true)

        let outcome = BookmarkBoundaryProbe(
            store: BookmarkStore(storageURL: temporaryRoot.appending(path: "bookmark.data"))
        ).run(
            fakeVault: vault,
            movedVault: occupiedDestination,
            noteRelativePath: "Daily/2026-08-30.md",
            expectedNote: Data("synthetic boundary probe note\n".utf8)
        )

        XCTAssertEqual(outcome.save, .passed)
        XCTAssertEqual(outcome.resolveRead, .passed)
        XCTAssertEqual(outcome.move, .failed)
        XCTAssertEqual(outcome.staleResolveRead, .notAttempted)
        XCTAssertEqual(outcome.firstFailureStage, .move)
    }

    func testFreshStoreResolvesAndReadsPersistedBookmark() throws {
        let temporaryRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let vault = try makeFakeVault(in: temporaryRoot)
        let bookmarkFile = temporaryRoot.appending(path: "persisted-bookmark.data")
        try BookmarkStore(storageURL: bookmarkFile).saveBookmark(for: vault)

        let freshStore = BookmarkStore(storageURL: bookmarkFile)
        XCTAssertEqual(
            try freshStore.resolveAndRead(
                relativePath: "Daily/2026-08-30.md",
                expectedContents: Data("synthetic boundary probe note\n".utf8)
            ),
            .matched
        )
    }

    func testCodexOutputAllowsOnlyNumericDottedVersion() {
        XCTAssertEqual(
            CodexVersionProbe.classify(terminationStatus: 0, stdout: Data("codex-cli 0.151.0\n".utf8)),
            CodexLaunchResult(status: .version, version: "0.151.0")
        )
    }

    func testCodexOutputRejectsPathsTokensExtraLinesAndMalformedVersions() {
        let adversarialOutputs = [
            "codex-cli /private/generated/path 0.151.0\n",
            "codex-cli 0.151.0\ntoken=synthetic-secret\n",
            "codex-cli 0.151.beta\n",
            "codex-cli 0.151.0 --config synthetic\n",
            "codex-cli 0.151.0/path\n",
            "codex-cli ٠.١\n",
        ]

        for output in adversarialOutputs {
            XCTAssertEqual(
                CodexVersionProbe.classify(terminationStatus: 0, stdout: Data(output.utf8)),
                CodexLaunchResult(status: .invalidOutput, version: nil),
                "Unexpectedly accepted adversarial output"
            )
        }
    }

    func testCodexFailureStatusesNeverCarryOutput() {
        XCTAssertEqual(
            CodexVersionProbe.classify(
                terminationStatus: 9,
                stdout: Data("token=synthetic-secret /private/generated/path".utf8)
            ),
            CodexLaunchResult(status: .nonzeroExit, version: nil)
        )

        XCTAssertEqual(
            CodexVersionProbe.attempt(executableURL: URL(filePath: "/path/that/does/not/exist")),
            CodexLaunchResult(status: .launchFailed, version: nil)
        )

        XCTAssertEqual(
            CodexLaunchResult(status: .version, version: "0.151.0/private/generated/path"),
            CodexLaunchResult(status: .invalidOutput, version: nil)
        )
    }

    func testKeychainItemsAreIsolatedByExactServiceAndAccountAndDeleted() throws {
        let namespace = UUID().uuidString
        let service = "com.example.dailyplanner.security-boundary.tests.\(namespace)"
        let first = KeychainProbe(service: service, account: "first")
        let second = KeychainProbe(service: service, account: "second")
        defer {
            try? first.delete()
            try? second.delete()
        }

        try first.delete()
        try second.delete()
        XCTAssertNil(try first.read())
        XCTAssertNil(try second.read())

        try first.store(Data("synthetic-first".utf8))
        try second.store(Data("synthetic-second".utf8))

        XCTAssertEqual(try first.read(), Data("synthetic-first".utf8))
        XCTAssertEqual(try second.read(), Data("synthetic-second".utf8))

        try first.delete()
        XCTAssertNil(try first.read())
        XCTAssertEqual(try second.read(), Data("synthetic-second".utf8))

        try second.delete()
        XCTAssertNil(try second.read())
    }

    func testKeychainRoundTripUsesAfterFirstUnlockThisDeviceOnlyAndCleansUp() throws {
        let probe = KeychainProbe(
            service: "com.example.dailyplanner.security-boundary.tests.\(UUID().uuidString)",
            account: "round-trip"
        )
        defer { try? probe.delete() }

        XCTAssertTrue(try probe.roundTrip(value: Data("synthetic-round-trip".utf8)))
        XCTAssertNil(try probe.read())
    }

    func testCodexVersionAttemptPassesOneLiteralArgumentWithoutShellInterpolation() throws {
        XCTAssertEqual(
            CodexVersionProbe.attempt(executableURL: URL(filePath: "/bin/echo")),
            CodexLaunchResult(status: .invalidOutput, version: nil)
        )
    }

    func testProbeResultJSONContainsOnlySanitizedBoundaryOutcomes() throws {
        let result = SecurityBoundaryProbeResult(
            variant: .sandboxed,
            bookmark: BookmarkProbeOutcome(
                save: .passed,
                resolveRead: .passed,
                move: .failed,
                staleResolveRead: .notAttempted,
                firstFailureStage: .move
            ),
            keychainRoundTrip: true,
            codexLaunchResult: CodexLaunchResult(status: .launchFailed, version: nil),
            cleanupSucceeded: true
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(SecurityBoundaryProbeResult.self, from: data)

        XCTAssertEqual(decoded, result)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(FileManager.default.homeDirectoryForCurrentUser.path))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("synthetic-secret"))

        var adversarialObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        adversarialObject["variant"] = "/private/generated/path token=synthetic-secret"
        let adversarialData = try JSONSerialization.data(withJSONObject: adversarialObject)
        XCTAssertThrowsError(
            try JSONDecoder().decode(SecurityBoundaryProbeResult.self, from: adversarialData)
        )
    }

    func testInteractiveBookmarkResultEncodesOnlyFiniteStatuses() throws {
        let result = InteractiveBookmarkResult(
            variant: .sandboxed,
            phase: .resolveRelaunch,
            status: .resolveReadFailed,
            selectionValidation: .notAttempted,
            bookmark: BookmarkProbeOutcome(
                save: .passed,
                resolveRead: .failed,
                move: .notAttempted,
                staleResolveRead: .notAttempted,
                firstFailureStage: .resolveRead
            ),
            bookmarkDeleted: true
        )

        let data = try JSONEncoder().encode(result)
        let encoded = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(try JSONDecoder().decode(InteractiveBookmarkResult.self, from: data), result)
        XCTAssertFalse(encoded.contains("/private/generated/path"))
        XCTAssertFalse(encoded.contains("synthetic-secret"))
    }

    func testInteractiveSelectionValidationClassifiesEachFiniteOutcome() throws {
        let temporaryRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let exactVault = try makeFakeVault(in: temporaryRoot, named: "ExactVault")
        let siblingVault = try makeFakeVault(in: temporaryRoot, named: "SiblingVault")
        let unreadableVault = try makeVault(in: temporaryRoot, named: "UnreadableVault", note: nil)
        let mismatchedVault = try makeVault(
            in: temporaryRoot,
            named: "MismatchedVault",
            note: Data("wrong synthetic note\n".utf8)
        )
        let expectedNote = Data("synthetic boundary probe note\n".utf8)
        let notePath = "Daily/2026-08-30.md"

        let cases: [(name: String, selectedURL: URL?, expectedVault: URL, validate: Bool, expected: InteractiveSelectionValidation)] = [
            ("missing URL", nil, exactVault, true, .missingURL),
            ("sibling URL", siblingVault, exactVault, true, .urlMismatch),
            ("unreadable note", unreadableVault, unreadableVault, true, .noteUnreadable),
            ("mismatched note", mismatchedVault, mismatchedVault, true, .noteMismatch),
            ("exact generated note", exactVault, exactVault, true, .validated),
            ("no validation", exactVault, exactVault, false, .notAttempted),
        ]

        for testCase in cases {
            let actual = testCase.validate
                ? InteractiveSelectionValidator.validate(
                    selectedURL: testCase.selectedURL,
                    expectedVaultURL: testCase.expectedVault,
                    noteRelativePath: notePath,
                    expectedNote: expectedNote,
                    noteReader: { try Data(contentsOf: $0) }
                )
                : .notAttempted
            XCTAssertEqual(actual, testCase.expected, testCase.name)
        }
    }

    func testInteractiveSelectionValidationCodableRejectsPathLikeValues() throws {
        let rawValues = [
            "notAttempted",
            "missingURL",
            "urlMismatch",
            "noteUnreadable",
            "noteMismatch",
            "validated",
        ]

        for rawValue in rawValues {
            let validation = try XCTUnwrap(InteractiveSelectionValidation(rawValue: rawValue))
            let data = try JSONEncoder().encode(validation)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"\(rawValue)\"")
            XCTAssertEqual(try JSONDecoder().decode(InteractiveSelectionValidation.self, from: data), validation)
        }

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                InteractiveSelectionValidation.self,
                from: Data("\"/private/generated/path\"".utf8)
            )
        )
    }

    func testExactFakeVaultPickerPolicyEnablesExactStandardizedFileIdentity() throws {
        let temporaryRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let exactVault = try makeFakeVault(in: temporaryRoot, named: "ExactVault")
        let equivalentPath = exactVault
            .appending(path: "..", directoryHint: .isDirectory)
            .appending(path: "ExactVault", directoryHint: .isDirectory)

        XCTAssertTrue(
            ExactFakeVaultPickerPolicy.shouldEnable(
                candidateURL: exactVault,
                expectedVaultURL: exactVault
            )
        )
        XCTAssertTrue(
            ExactFakeVaultPickerPolicy.shouldEnable(
                candidateURL: equivalentPath,
                expectedVaultURL: exactVault
            )
        )
    }

    func testExactFakeVaultPickerPolicyDisablesNonExactAndNonFileCandidates() throws {
        let temporaryRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let exactVault = try makeFakeVault(in: temporaryRoot, named: "ExactVault")
        let child = exactVault.appending(path: "Daily", directoryHint: .isDirectory)
        let sibling = try makeFakeVault(in: temporaryRoot, named: "SiblingVault")
        let alias = temporaryRoot.appending(path: "ExactVaultAlias", directoryHint: .isDirectory)
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: exactVault)

        let cases: [(name: String, candidateURL: URL, expectedVaultURL: URL)] = [
            ("parent", temporaryRoot, exactVault),
            ("child", child, exactVault),
            ("sibling", sibling, exactVault),
            ("symlink alias", alias, exactVault),
            ("non-file candidate", URL(string: "https://example.invalid/ExactVault")!, exactVault),
            ("non-file expected vault", exactVault, URL(string: "https://example.invalid/ExactVault")!),
        ]

        for testCase in cases {
            XCTAssertFalse(
                ExactFakeVaultPickerPolicy.shouldEnable(
                    candidateURL: testCase.candidateURL,
                    expectedVaultURL: testCase.expectedVaultURL
                ),
                testCase.name
            )
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appending(path: "security-boundary-probe-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeFakeVault(in temporaryRoot: URL, named name: String = "FakeVault") throws -> URL {
        try makeVault(
            in: temporaryRoot,
            named: name,
            note: Data("synthetic boundary probe note\n".utf8)
        )
    }

    private func makeVault(in temporaryRoot: URL, named name: String, note: Data?) throws -> URL {
        let vault = temporaryRoot.appending(path: name, directoryHint: .isDirectory)
        let daily = vault.appending(path: "Daily", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: daily, withIntermediateDirectories: true)
        if let note {
            try note.write(to: daily.appending(path: "2026-08-30.md"))
        }
        return vault
    }
}
