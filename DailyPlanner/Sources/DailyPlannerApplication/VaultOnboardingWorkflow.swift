import Foundation
import DailyPlannerDomain

public protocol VaultFolderSelecting: Sendable {
    @MainActor func selectRootBookmark() async throws -> Data?
}

public enum VaultOnboardingState: Equatable, Sendable {
    case notSelected
    case selected
    case cancelled
    case failed(VaultOnboardingFailure)
}

public enum VaultOnboardingFailure: Equatable, Sendable {
    case selectionUnavailable
    case settingsUnavailable
}

public struct VaultOnboardingWorkflow: Sendable {
    private let picker: any VaultFolderSelecting
    private let settingsStore: any PrivateSettingsStore

    public init(
        picker: any VaultFolderSelecting,
        settingsStore: any PrivateSettingsStore
    ) {
        self.picker = picker
        self.settingsStore = settingsStore
    }

    @MainActor
    public func chooseVaultRoot() async -> VaultOnboardingState {
        let bookmark: Data?
        do {
            bookmark = try await picker.selectRootBookmark()
        } catch {
            return .failed(.selectionUnavailable)
        }

        guard let bookmark else {
            return .cancelled
        }

        do {
            var settings = try settingsStore.load()
            settings.vaultBookmark = bookmark
            try settingsStore.replace(settings)
            return .selected
        } catch {
            return .failed(.settingsUnavailable)
        }
    }
}
