import Foundation

public struct BookmarkResolution: Sendable {
    public let url: URL
    public let isStale: Bool
    private let didStartSecurityScopedAccess: Bool

    init(url: URL, isStale: Bool, didStartSecurityScopedAccess: Bool) {
        self.url = url
        self.isStale = isStale
        self.didStartSecurityScopedAccess = didStartSecurityScopedAccess
    }

    public func stopAccessing() {
        if didStartSecurityScopedAccess {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

public struct BookmarkStore: Sendable {
    private let storageURL: URL

    public init(storageURL: URL) {
        self.storageURL = storageURL
    }

    public func saveBookmark(for url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bookmark.write(to: storageURL, options: .atomic)
    }

    public func resolveBookmark() throws -> BookmarkResolution {
        let bookmark = try Data(contentsOf: storageURL)
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        let didStart = url.startAccessingSecurityScopedResource()
        return BookmarkResolution(
            url: url,
            isStale: isStale,
            didStartSecurityScopedAccess: didStart
        )
    }

    public func resolveAndRead(
        relativePath: String,
        expectedContents: Data
    ) throws -> PersistedBookmarkReadStatus {
        let resolution = try resolveBookmark()
        defer { resolution.stopAccessing() }
        let contents = try Data(contentsOf: resolution.url.appending(path: relativePath))
        return contents == expectedContents ? .matched : .mismatched
    }
}

public enum ProbeStageStatus: String, Codable, Equatable, Sendable {
    case notAttempted
    case passed
    case failed
}

public enum BookmarkFailureStage: String, Codable, Equatable, Sendable {
    case none
    case save
    case resolveRead
    case move
    case staleResolveRead
}

public enum PersistedBookmarkReadStatus: String, Codable, Equatable, Sendable {
    case matched
    case mismatched
}

public struct BookmarkProbeOutcome: Codable, Equatable, Sendable {
    public let save: ProbeStageStatus
    public let resolveRead: ProbeStageStatus
    public let move: ProbeStageStatus
    public let staleResolveRead: ProbeStageStatus
    public let firstFailureStage: BookmarkFailureStage

    public init(
        save: ProbeStageStatus,
        resolveRead: ProbeStageStatus,
        move: ProbeStageStatus,
        staleResolveRead: ProbeStageStatus,
        firstFailureStage: BookmarkFailureStage
    ) {
        self.save = save
        self.resolveRead = resolveRead
        self.move = move
        self.staleResolveRead = staleResolveRead
        self.firstFailureStage = firstFailureStage
    }

    public static let notAttempted = BookmarkProbeOutcome(
        save: .notAttempted,
        resolveRead: .notAttempted,
        move: .notAttempted,
        staleResolveRead: .notAttempted,
        firstFailureStage: .none
    )
}

public struct BookmarkBoundaryProbe: Sendable {
    private let store: BookmarkStore

    public init(store: BookmarkStore) {
        self.store = store
    }

    public func run(
        fakeVault: URL,
        movedVault: URL,
        noteRelativePath: String,
        expectedNote: Data
    ) -> BookmarkProbeOutcome {
        let fileManager = FileManager.default
        do {
            try store.saveBookmark(for: fakeVault)
        } catch {
            return failed(at: .save, save: .failed)
        }

        do {
            guard try store.resolveAndRead(
                relativePath: noteRelativePath,
                expectedContents: expectedNote
            ) == .matched else {
                return failed(at: .resolveRead, save: .passed, resolveRead: .failed)
            }
        } catch {
            return failed(at: .resolveRead, save: .passed, resolveRead: .failed)
        }

        do {
            try fileManager.moveItem(at: fakeVault, to: movedVault)
        } catch {
            return failed(
                at: .move,
                save: .passed,
                resolveRead: .passed,
                move: .failed
            )
        }
        defer {
            if fileManager.fileExists(atPath: movedVault.path) {
                try? fileManager.moveItem(at: movedVault, to: fakeVault)
            }
        }

        do {
            let resolution = try store.resolveBookmark()
            defer { resolution.stopAccessing() }
            let noteMatches = try Data(
                contentsOf: resolution.url.appending(path: noteRelativePath)
            ) == expectedNote
            guard resolution.isStale,
                  resolution.url.standardizedFileURL == movedVault.standardizedFileURL,
                  noteMatches else {
                return failed(
                    at: .staleResolveRead,
                    save: .passed,
                    resolveRead: .passed,
                    move: .passed,
                    staleResolveRead: .failed
                )
            }
        } catch {
            return failed(
                at: .staleResolveRead,
                save: .passed,
                resolveRead: .passed,
                move: .passed,
                staleResolveRead: .failed
            )
        }

        return BookmarkProbeOutcome(
            save: .passed,
            resolveRead: .passed,
            move: .passed,
            staleResolveRead: .passed,
            firstFailureStage: .none
        )
    }

    private func failed(
        at stage: BookmarkFailureStage,
        save: ProbeStageStatus = .notAttempted,
        resolveRead: ProbeStageStatus = .notAttempted,
        move: ProbeStageStatus = .notAttempted,
        staleResolveRead: ProbeStageStatus = .notAttempted
    ) -> BookmarkProbeOutcome {
        BookmarkProbeOutcome(
            save: save,
            resolveRead: resolveRead,
            move: move,
            staleResolveRead: staleResolveRead,
            firstFailureStage: stage
        )
    }
}

public enum CodexLaunchStatus: String, Codable, Equatable, Sendable {
    case version
    case invalidOutput
    case nonzeroExit
    case launchFailed
}

public struct CodexLaunchResult: Codable, Equatable, Sendable {
    public let status: CodexLaunchStatus
    public let version: String?

    public init(status: CodexLaunchStatus, version: String?) {
        if status == .version, let version, isNumericDottedVersion(version) {
            self.status = .version
            self.version = version
        } else {
            self.status = status == .version ? .invalidOutput : status
            self.version = nil
        }
    }
}

public enum CodexVersionProbe {
    public static func attempt(executableURL: URL) -> CodexLaunchResult {
        let output = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--version"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let stdout = output.fileHandleForReading.readData(ofLength: 81)
            output.fileHandleForReading.closeFile()
            process.waitUntilExit()
            return classify(terminationStatus: process.terminationStatus, stdout: stdout)
        } catch {
            return CodexLaunchResult(status: .launchFailed, version: nil)
        }
    }

    public static func classify(terminationStatus: Int32, stdout: Data) -> CodexLaunchResult {
        guard terminationStatus == 0 else {
            return CodexLaunchResult(status: .nonzeroExit, version: nil)
        }
        guard stdout.count <= 80,
              var line = String(data: stdout, encoding: .utf8) else {
            return CodexLaunchResult(status: .invalidOutput, version: nil)
        }
        if line.hasSuffix("\n") {
            line.removeLast()
        }
        guard !line.contains("\n"), !line.contains("\r") else {
            return CodexLaunchResult(status: .invalidOutput, version: nil)
        }

        let fields = line.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 2, fields[0] == "codex-cli" else {
            return CodexLaunchResult(status: .invalidOutput, version: nil)
        }
        let version = String(fields[1])
        guard isNumericDottedVersion(version) else {
            return CodexLaunchResult(status: .invalidOutput, version: nil)
        }
        return CodexLaunchResult(status: .version, version: version)
    }
}

private func isNumericDottedVersion(_ version: String) -> Bool {
    let components = version.split(separator: ".", omittingEmptySubsequences: false)
    return components.count >= 2
        && components.allSatisfy { component in
            !component.isEmpty && component.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
        }
}

public enum SecurityBoundaryVariant: String, Codable, Equatable, Sendable {
    case unsandboxed
    case sandboxed
}

public struct SecurityBoundaryProbeResult: Codable, Equatable, Sendable {
    public let variant: SecurityBoundaryVariant
    public let bookmark: BookmarkProbeOutcome
    public let keychainRoundTrip: Bool
    public let codexLaunchResult: CodexLaunchResult
    public let cleanupSucceeded: Bool

    public init(
        variant: SecurityBoundaryVariant,
        bookmark: BookmarkProbeOutcome,
        keychainRoundTrip: Bool,
        codexLaunchResult: CodexLaunchResult,
        cleanupSucceeded: Bool
    ) {
        self.variant = variant
        self.bookmark = bookmark
        self.keychainRoundTrip = keychainRoundTrip
        self.codexLaunchResult = codexLaunchResult
        self.cleanupSucceeded = cleanupSucceeded
    }
}

public enum InteractiveBookmarkPhase: String, Codable, Equatable, Sendable {
    case selectAndSave
    case resolveRelaunch
    case cleanup
}

public enum InteractiveBookmarkStatus: String, Codable, Equatable, Sendable {
    case saved
    case selectionCancelled
    case invalidSelection
    case saveFailed
    case resolveReadPassed
    case resolveReadFailed
    case cleanupPassed
    case cleanupFailed
}

public enum InteractiveSelectionValidation: String, Codable, Equatable, Sendable {
    case notAttempted
    case missingURL
    case urlMismatch
    case noteUnreadable
    case noteMismatch
    case validated
}

public enum InteractiveSelectionValidator {
    public static func validate(
        selectedURL: URL?,
        expectedVaultURL: URL,
        noteRelativePath: String,
        expectedNote: Data,
        noteReader: (URL) throws -> Data
    ) -> InteractiveSelectionValidation {
        guard let selectedURL else {
            return .missingURL
        }
        guard selectedURL.standardizedFileURL == expectedVaultURL.standardizedFileURL else {
            return .urlMismatch
        }
        do {
            let note = try noteReader(selectedURL.appending(path: noteRelativePath))
            return note == expectedNote ? .validated : .noteMismatch
        } catch {
            return .noteUnreadable
        }
    }
}

public enum ExactFakeVaultPickerPolicy {
    public static func shouldEnable(candidateURL: URL, expectedVaultURL: URL) -> Bool {
        guard candidateURL.isFileURL, expectedVaultURL.isFileURL else {
            return false
        }
        return candidateURL.standardizedFileURL == expectedVaultURL.standardizedFileURL
    }
}

public struct InteractiveBookmarkResult: Codable, Equatable, Sendable {
    public let variant: SecurityBoundaryVariant
    public let phase: InteractiveBookmarkPhase
    public let status: InteractiveBookmarkStatus
    public let selectionValidation: InteractiveSelectionValidation
    public let bookmark: BookmarkProbeOutcome
    public let bookmarkDeleted: Bool

    public init(
        variant: SecurityBoundaryVariant,
        phase: InteractiveBookmarkPhase,
        status: InteractiveBookmarkStatus,
        selectionValidation: InteractiveSelectionValidation,
        bookmark: BookmarkProbeOutcome,
        bookmarkDeleted: Bool
    ) {
        self.variant = variant
        self.phase = phase
        self.status = status
        self.selectionValidation = selectionValidation
        self.bookmark = bookmark
        self.bookmarkDeleted = bookmarkDeleted
    }
}
