import AppKit
import DailyPlannerDomain
import Foundation

protocol WorkspaceURLOpening: Sendable {
    @MainActor
    func open(_ url: URL) -> Bool
}

private struct MacWorkspaceURLOpener: WorkspaceURLOpening {
    @MainActor
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

public struct MacSystemBrowser: SystemBrowserOpening, Sendable {
    private let workspace: any WorkspaceURLOpening

    public init() {
        workspace = MacWorkspaceURLOpener()
    }

    init(workspace: any WorkspaceURLOpening) {
        self.workspace = workspace
    }

    public func open(_ url: URL) async -> Bool {
        await workspace.open(url)
    }
}
