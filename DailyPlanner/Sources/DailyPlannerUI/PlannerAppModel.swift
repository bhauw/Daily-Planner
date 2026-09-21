import Combine
import DailyPlannerApplication
import DailyPlannerDomain
import Foundation

public enum AssistantUnavailableReason: Equatable, Sendable {
    case notIncludedInM2
}

public enum AssistantState: Equatable, Sendable {
    case unavailable(AssistantUnavailableReason)
}

public enum PlannerAppFailure: Equatable, Sendable {
    case settingsUnavailable
    case catalogUnavailable
    case selectionUnavailable
    case refreshUnavailable
    case referenceViewUnavailable
}

public enum PlannerPreviewState: Equatable, Sendable {
    case empty
    case ready
    case requiresRefresh
}

@MainActor
public final class PlannerAppModel: ObservableObject {
    @Published public private(set) var preview: PlanningPreview
    @Published public private(set) var previewState: PlannerPreviewState
    @Published public private(set) var assistantState: AssistantState
    @Published public private(set) var calendarRoleRows: [CalendarRoleRow]
    @Published public private(set) var colorMappingRows: [ColorCategoryRow] = []
    @Published public private(set) var vaultPermissionLabel: String
    @Published public private(set) var isSettingsPresented: Bool
    @Published public private(set) var failure: PlannerAppFailure?
    @Published public private(set) var googleConnectionState: GoogleConnectionWorkflowState
    @Published public var googleClientIdentifierDraft: String
    @Published public var googleClientSecretDraft: String

    public let safetyBanner: String
    public let googleConnectionGuidance: String?
    public var canExecuteExternalAction: Bool { false }
    public var canSaveGoogleClientConfiguration: Bool {
        !googleClientIdentifierDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !googleClientSecretDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var isColorMappingAvailable: Bool { colorMapping != nil }

    private let vaultOnboarding: VaultOnboardingWorkflow
    private let roles: CalendarRoleWorkflow
    private let colorMapping: ColorCategoryWorkflow?
    private let planning: PlanningPreviewWorkflow
    private let referenceView: ReferenceCalendarWorkflow
    private let googleConnection: GoogleConnectionWorkflow
    private let previewInterval: DateInterval
    private var inFlightGoogleConnectionStarts = 0

    public convenience init(
        vaultOnboarding: VaultOnboardingWorkflow,
        roles: CalendarRoleWorkflow,
        planning: PlanningPreviewWorkflow,
        referenceView: ReferenceCalendarWorkflow,
        googleConnection: GoogleConnectionWorkflow,
        previewInterval: DateInterval,
        colorMapping: ColorCategoryWorkflow? = nil,
        startsWithSettingsPresented: Bool = false,
        googleConnectionGuidance: String? = nil
    ) {
        self.init(
            vaultOnboarding: vaultOnboarding,
            roles: roles,
            planning: planning,
            referenceView: referenceView,
            googleConnection: googleConnection,
            previewInterval: previewInterval,
            initialGoogleConnectionState: .notConfigured,
            colorMapping: colorMapping,
            startsWithSettingsPresented: startsWithSettingsPresented,
            googleConnectionGuidance: googleConnectionGuidance
        )
    }

    init(
        vaultOnboarding: VaultOnboardingWorkflow,
        roles: CalendarRoleWorkflow,
        planning: PlanningPreviewWorkflow,
        referenceView: ReferenceCalendarWorkflow,
        googleConnection: GoogleConnectionWorkflow,
        previewInterval: DateInterval,
        initialGoogleConnectionState: GoogleConnectionWorkflowState,
        colorMapping: ColorCategoryWorkflow? = nil,
        startsWithSettingsPresented: Bool = false,
        googleConnectionGuidance: String? = nil
    ) {
        self.vaultOnboarding = vaultOnboarding
        self.roles = roles
        self.colorMapping = colorMapping
        self.planning = planning
        self.referenceView = referenceView
        self.googleConnection = googleConnection
        self.previewInterval = previewInterval
        preview = .empty
        previewState = .empty
        assistantState = .unavailable(.notIncludedInM2)
        calendarRoleRows = []
        vaultPermissionLabel = "Permission not selected"
        isSettingsPresented = startsWithSettingsPresented
        failure = nil
        googleConnectionState = initialGoogleConnectionState
        googleClientIdentifierDraft = ""
        googleClientSecretDraft = ""
        safetyBanner = "Read-only · no actions executed"
        self.googleConnectionGuidance = googleConnectionGuidance
    }

    /// Advice about what is currently typed in the client fields, or nil when it looks right.
    ///
    /// Advisory only — it never blocks a save. These are Google's formats, not ours, and a hard
    /// reject on a heuristic would lock the user out of their own app the day Google changes a
    /// prefix. See `GoogleClientFieldAdvice`.
    public var googleClientIdentifierAdvice: String? {
        GoogleClientFieldAdvice.clientIdentifierAdvice(googleClientIdentifierDraft)
    }

    public var googleClientSecretAdvice: String? {
        GoogleClientFieldAdvice.clientSecretAdvice(googleClientSecretDraft)
    }

    public func showSettings() {
        isSettingsPresented = true
    }

    func dismissSettings() async {
        isSettingsPresented = false
        if googleConnectionState.isPendingConnection || inFlightGoogleConnectionStarts > 0 {
            await cancelGoogleConnection()
        }
    }

    public func loadGoogleConnectionState() async {
        googleConnectionState = await googleConnection.loadState()
    }

    public func saveGoogleClientConfiguration() async {
        let clientIdentifier = googleClientIdentifierDraft
        let clientSecret = googleClientSecretDraft
        defer {
            googleClientIdentifierDraft = ""
            googleClientSecretDraft = ""
        }
        googleConnectionState = await googleConnection.saveClientConfiguration(
            clientIdentifier: clientIdentifier,
            clientSecret: clientSecret
        )
    }

    /// Connects, or reconnects, asking Google for `capability`.
    ///
    /// Write access cannot be added to an existing grant — a refresh token never gains scopes —
    /// so enabling sending and scheduling means consenting again from scratch.
    /// Disconnects and immediately reconnects asking for send + event-creation access.
    ///
    /// Two steps because `begin` requires there to be no complete credential — and because a
    /// refresh token cannot gain scopes, so there is no way to widen a grant in place. If the
    /// user abandons the consent screen they end up disconnected rather than half-upgraded,
    /// which is why the disconnect is reported rather than swallowed.
    public func enableGoogleWriteAccess() async {
        // Keeps the OAuth client configuration: a plain disconnect deletes it along with the
        // grant, which would leave the user disconnected and having to re-enter their client id
        // and secret just to get back to where they were.
        googleConnectionState = await googleConnection.disconnectForReconsent()
        await connectGoogle(capability: .readWrite)
    }

    public func connectGoogle(capability: GoogleGrantedCapability = .readOnly) async {
        inFlightGoogleConnectionStarts += 1
        defer { inFlightGoogleConnectionStarts -= 1 }
        let outcome = await googleConnection.begin(capability: capability) { [weak self] progress in
            await self?.publishGoogleConnectionProgress(progress)
        }
        switch outcome {
        case .connecting, .awaitingConsent:
            break
        default:
            googleConnectionState = outcome
        }
    }

    public func confirmGoogleIdentity() async {
        googleConnectionState = await googleConnection.confirm()
    }

    public func cancelGoogleConnection() async {
        googleConnectionState = await googleConnection.cancel()
    }

    public func disconnectGoogle() async {
        googleConnectionState = await googleConnection.disconnect()
    }

    public func loadCalendarRoles() async {
        do {
            calendarRoleRows = try await roles.rows()
            failure = nil
        } catch PlanningWorkflowError.settingsUnavailable {
            failure = .settingsUnavailable
        } catch PlanningWorkflowError.catalogUnavailable {
            failure = .catalogUnavailable
        } catch {
            failure = .catalogUnavailable
        }
    }

    public func loadColorMappings() async {
        guard let colorMapping else { return }
        do {
            colorMappingRows = try await colorMapping.rows()
            failure = nil
        } catch PlanningWorkflowError.settingsUnavailable {
            failure = .settingsUnavailable
        } catch {
            failure = .catalogUnavailable
        }
    }

    public func setColorCategory(_ category: PlannerCategory?, forColorID colorID: String) async {
        guard let colorMapping else { return }
        do {
            try colorMapping.setCategory(category, forColorID: colorID)
            await loadColorMappings()
        } catch {
            failure = .settingsUnavailable
        }
    }

    public func chooseVaultRoot() async {
        switch await vaultOnboarding.chooseVaultRoot() {
        case .selected:
            vaultPermissionLabel = "Permission remembered"
            failure = nil
        case .notSelected, .cancelled:
            break
        case .failed(.selectionUnavailable):
            failure = .selectionUnavailable
        case .failed(.settingsUnavailable):
            failure = .settingsUnavailable
        }
    }

    public func refresh() async {
        do {
            preview = try await planning.refresh(interval: previewInterval)
            previewState = .ready
            failure = nil
        } catch PlanningWorkflowError.settingsUnavailable {
            replacePreviewAfterRefreshFailure(.settingsUnavailable)
        } catch PlanningWorkflowError.catalogUnavailable {
            replacePreviewAfterRefreshFailure(.catalogUnavailable)
        } catch PlanningWorkflowError.referenceViewUnavailable {
            replacePreviewAfterRefreshFailure(.referenceViewUnavailable)
        } catch {
            replacePreviewAfterRefreshFailure(.refreshUnavailable)
        }
    }

    public func setRole(_ role: CalendarRole, for calendarID: CalendarID) async {
        do {
            let result = try roles.setRole(role, for: calendarID, at: Date())
            switch result {
            case .unchanged:
                failure = nil
            case .saved:
                calendarRoleRows = calendarRoleRows.map { row in
                    guard row.calendarID == calendarID else { return row }
                    return CalendarRoleRow(
                        calendarID: row.calendarID,
                        displayName: row.displayName,
                        role: role
                    )
                }
                preview = .empty
                previewState = .requiresRefresh
                failure = nil
            }
        } catch {
            failure = .settingsUnavailable
        }
    }

    private func replacePreviewAfterRefreshFailure(_ failure: PlannerAppFailure) {
        preview = .empty
        previewState = .empty
        self.failure = failure
    }

    private func publishGoogleConnectionProgress(_ progress: GoogleConnectionWorkflowState) {
        switch progress {
        case .connecting, .awaitingConsent:
            googleConnectionState = progress
        default:
            break
        }
    }
}

extension GoogleConnectionWorkflowState {
    var isPendingConnection: Bool {
        switch self {
        case .connecting, .awaitingConsent, .confirmIdentity:
            true
        default:
            false
        }
    }
}
