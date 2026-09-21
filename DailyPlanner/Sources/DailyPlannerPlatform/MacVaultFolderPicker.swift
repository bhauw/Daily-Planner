import AppKit
import Foundation
import DailyPlannerApplication

public struct MacVaultFolderPicker: VaultFolderSelecting, Sendable {
    private let selectURL: @MainActor @Sendable () -> URL?

    public init() {
        self.selectURL = {
            let panel = NSOpenPanel()
            panel.title = "Choose your Obsidian vault root"
            panel.message = "Choose the folder that contains your Obsidian vault. Daily Planner will remember permission but will not read or write it in M1."
            panel.prompt = "Choose Vault Root"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = false
            panel.resolvesAliases = false
            panel.showsHiddenFiles = false
            return panel.runModal() == .OK ? panel.url : nil
        }
    }

    init(selectURL: @escaping @MainActor @Sendable () -> URL?) {
        self.selectURL = selectURL
    }

    @MainActor
    public func selectRootBookmark() async throws -> Data? {
        guard let url = selectURL() else { return nil }
        return try url.bookmarkData(options: [.withSecurityScope])
    }
}
