import AppKit
import Foundation
import SecurityBoundaryCore

private final class ExactFakeVaultOpenPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    private let expectedVaultURL: URL

    init(expectedVaultURL: URL) {
        self.expectedVaultURL = expectedVaultURL
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        ExactFakeVaultPickerPolicy.shouldEnable(
            candidateURL: url,
            expectedVaultURL: expectedVaultURL
        )
    }
}

@MainActor
final class ProbeViewModel {
    private let fileManager = FileManager.default
    private let noteRelativePath = "Daily/2026-08-30.md"
    private let syntheticNote = Data("synthetic boundary probe note\n".utf8)

    func runAutomated(arguments: [String]) throws -> SecurityBoundaryProbeResult {
        let variant = try variant(in: arguments)
        let fakeVault = URL(filePath: try value(after: "--fake-vault", in: arguments), directoryHint: .isDirectory)
        let codex = URL(filePath: try value(after: "--codex", in: arguments))
        return run(variant: variant, fakeVault: fakeVault, codexExecutable: codex)
    }

    func runLockHelper(arguments: [String]) throws {
        let artifact = URL(filePath: try value(after: "--artifact", in: arguments))
        let delayText = try value(after: "--delay-seconds", in: arguments)
        guard let delay = TimeInterval(delayText), delay >= 1, delay <= 60 else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }

        let keychain = KeychainProbe(
            service: "com.example.dailyplanner.security-boundary-lock-check",
            account: "after-first-unlock"
        )
        defer { try? keychain.delete() }
        try keychain.delete()
        try keychain.store(Data("synthetic-lock-check".utf8))
        Thread.sleep(forTimeInterval: delay)

        let readable = (try? keychain.read()) == Data("synthetic-lock-check".utf8)
        let output = Data("readable=\(readable ? "true" : "false")\n".utf8)
        try output.write(to: artifact, options: .atomic)
    }

    func selectAndSaveBookmark(arguments: [String]) throws -> InteractiveBookmarkResult {
        let variant = try variant(in: arguments)
        let fakeVault = URL(
            filePath: try value(after: "--fake-vault", in: arguments),
            directoryHint: .isDirectory
        )
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        let panelDelegate = ExactFakeVaultOpenPanelDelegate(expectedVaultURL: fakeVault)
        panel.delegate = panelDelegate
        panel.title = "Choose the generated Security Boundary fake vault"
        panel.message = "Choose the one enabled generated fake vault."
        panel.prompt = "Choose Generated Fake Vault"
        panel.directoryURL = fakeVault.deletingLastPathComponent()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        panel.showsHiddenFiles = false

        let response = withExtendedLifetime(panelDelegate) {
            panel.runModal()
        }
        guard response == .OK else {
            return InteractiveBookmarkResult(
                variant: variant,
                phase: .selectAndSave,
                status: .selectionCancelled,
                selectionValidation: .notAttempted,
                bookmark: .notAttempted,
                bookmarkDeleted: false
            )
        }
        let selectionValidation = InteractiveSelectionValidator.validate(
            selectedURL: panel.url,
            expectedVaultURL: fakeVault,
            noteRelativePath: noteRelativePath,
            expectedNote: syntheticNote,
            noteReader: { try Data(contentsOf: $0) }
        )
        guard selectionValidation == .validated, let selectedURL = panel.url else {
            return InteractiveBookmarkResult(
                variant: variant,
                phase: .selectAndSave,
                status: .invalidSelection,
                selectionValidation: selectionValidation,
                bookmark: .notAttempted,
                bookmarkDeleted: false
            )
        }

        let store = BookmarkStore(storageURL: interactiveBookmarkURL(variant: variant))
        do {
            try removeInteractiveBookmark(variant: variant)
            try store.saveBookmark(for: selectedURL)
            return InteractiveBookmarkResult(
                variant: variant,
                phase: .selectAndSave,
                status: .saved,
                selectionValidation: .validated,
                bookmark: BookmarkProbeOutcome(
                    save: .passed,
                    resolveRead: .notAttempted,
                    move: .notAttempted,
                    staleResolveRead: .notAttempted,
                    firstFailureStage: .none
                ),
                bookmarkDeleted: false
            )
        } catch {
            return InteractiveBookmarkResult(
                variant: variant,
                phase: .selectAndSave,
                status: .saveFailed,
                selectionValidation: .validated,
                bookmark: BookmarkProbeOutcome(
                    save: .failed,
                    resolveRead: .notAttempted,
                    move: .notAttempted,
                    staleResolveRead: .notAttempted,
                    firstFailureStage: .save
                ),
                bookmarkDeleted: false
            )
        }
    }

    func resolvePersistedBookmark(arguments: [String]) throws -> InteractiveBookmarkResult {
        let variant = try variant(in: arguments)
        let bookmarkURL = interactiveBookmarkURL(variant: variant)
        guard fileManager.fileExists(atPath: bookmarkURL.path) else {
            return InteractiveBookmarkResult(
                variant: variant,
                phase: .resolveRelaunch,
                status: .resolveReadFailed,
                selectionValidation: .notAttempted,
                bookmark: BookmarkProbeOutcome(
                    save: .failed,
                    resolveRead: .notAttempted,
                    move: .notAttempted,
                    staleResolveRead: .notAttempted,
                    firstFailureStage: .save
                ),
                bookmarkDeleted: true
            )
        }

        let store = BookmarkStore(storageURL: bookmarkURL)
        let matched = (try? store.resolveAndRead(
            relativePath: noteRelativePath,
            expectedContents: syntheticNote
        )) == .matched
        let deleted = (try? removeInteractiveBookmark(variant: variant)) != nil

        return InteractiveBookmarkResult(
            variant: variant,
            phase: .resolveRelaunch,
            status: matched ? .resolveReadPassed : .resolveReadFailed,
            selectionValidation: .notAttempted,
            bookmark: BookmarkProbeOutcome(
                save: .passed,
                resolveRead: matched ? .passed : .failed,
                move: .notAttempted,
                staleResolveRead: .notAttempted,
                firstFailureStage: matched ? .none : .resolveRead
            ),
            bookmarkDeleted: deleted && !fileManager.fileExists(atPath: bookmarkURL.path)
        )
    }

    func cleanupInteractiveArtifacts(arguments: [String]) throws -> InteractiveBookmarkResult {
        let variant = try variant(in: arguments)
        let bookmarkURL = interactiveBookmarkURL(variant: variant)
        let keychain = KeychainProbe(
            service: "com.example.dailyplanner.security-boundary-probe",
            account: variant.rawValue
        )
        var cleanupPassed = true
        do {
            try removeInteractiveBookmark(variant: variant)
            try keychain.delete()
        } catch {
            cleanupPassed = false
        }
        cleanupPassed = cleanupPassed && !fileManager.fileExists(atPath: bookmarkURL.path)
        return InteractiveBookmarkResult(
            variant: variant,
            phase: .cleanup,
            status: cleanupPassed ? .cleanupPassed : .cleanupFailed,
            selectionValidation: .notAttempted,
            bookmark: .notAttempted,
            bookmarkDeleted: !fileManager.fileExists(atPath: bookmarkURL.path)
        )
    }

    private func run(
        variant: SecurityBoundaryVariant,
        fakeVault: URL,
        codexExecutable: URL
    ) -> SecurityBoundaryProbeResult {
        let service = "com.example.dailyplanner.security-boundary-probe"
        let account = variant.rawValue
        let keychain = KeychainProbe(service: service, account: account)
        let bookmarkFile = fileManager.temporaryDirectory
            .appending(path: "security-boundary-bookmark-\(variant.rawValue).data")
        let store = BookmarkStore(storageURL: bookmarkFile)

        let movedVault = fakeVault.deletingLastPathComponent()
            .appending(path: "MovedFakeVault", directoryHint: .isDirectory)
        let bookmarkOutcome = BookmarkBoundaryProbe(store: store).run(
            fakeVault: fakeVault,
            movedVault: movedVault,
            noteRelativePath: noteRelativePath,
            expectedNote: syntheticNote
        )
        var keychainRoundTrip = false
        var bookmarkCleaned = false
        var keychainCleaned = false

        do {
            keychainRoundTrip = try keychain.roundTrip(value: Data("synthetic-keychain-value".utf8))
        } catch {
            keychainRoundTrip = false
        }

        do {
            if fileManager.fileExists(atPath: bookmarkFile.path) {
                try fileManager.removeItem(at: bookmarkFile)
            }
            bookmarkCleaned = !fileManager.fileExists(atPath: bookmarkFile.path)
        } catch {
            bookmarkCleaned = false
        }
        do {
            try keychain.delete()
            keychainCleaned = try keychain.read() == nil
        } catch {
            keychainCleaned = false
        }

        return SecurityBoundaryProbeResult(
            variant: variant,
            bookmark: bookmarkOutcome,
            keychainRoundTrip: keychainRoundTrip,
            codexLaunchResult: CodexVersionProbe.attempt(executableURL: codexExecutable),
            cleanupSucceeded: bookmarkCleaned && keychainCleaned
        )
    }

    private func value(after flag: String, in arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        return arguments[index + 1]
    }

    private func variant(in arguments: [String]) throws -> SecurityBoundaryVariant {
        let rawValue = try value(after: "--variant", in: arguments)
        guard let variant = SecurityBoundaryVariant(rawValue: rawValue) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        return variant
    }

    private func interactiveBookmarkURL(variant: SecurityBoundaryVariant) -> URL {
        fileManager.temporaryDirectory
            .appending(path: "security-boundary-interactive-\(variant.rawValue).bookmark")
    }

    private func removeInteractiveBookmark(variant: SecurityBoundaryVariant) throws {
        let bookmarkURL = interactiveBookmarkURL(variant: variant)
        if fileManager.fileExists(atPath: bookmarkURL.path) {
            try fileManager.removeItem(at: bookmarkURL)
        }
    }
}
