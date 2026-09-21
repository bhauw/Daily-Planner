import Foundation
import DailyPlannerDomain

public enum GoogleConnectionWorkflowState: Equatable, Sendable {
    case notConfigured, readyToConnect, connecting, awaitingConsent
    case confirmIdentity(displayEmail: String)
    /// Connected, and what that connection is actually allowed to do.
    ///
    /// Was `connectedReadOnly(displayEmail:)`, which stopped being true the moment a connection
    /// could carry write scopes. The UI read that name literally and told a user with send and
    /// schedule access that he did not have it, next to a button that deleted his working grant
    /// to "fix" it.
    case connected(displayEmail: String, capability: GoogleGrantedCapability)
    case cancelled, offline, scopeMismatch, identityMismatch
    case credentialUnavailable, providerUnavailable, cleanupRequired
}

public final class GoogleConnectionWorkflow: @unchecked Sendable {
    private enum ActiveOperation {
        case saving(UInt64)
        case beginning(UInt64)
        case confirming(UInt64)
        case cancelling(UInt64)
        case disconnecting(UInt64)

        var token: UInt64 {
            switch self {
            case .saving(let token),
                 .beginning(let token),
                 .confirming(let token),
                 .cancelling(let token),
                 .disconnecting(let token):
                return token
            }
        }
    }

    private struct RollbackWaiter {
        let token: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct Memory {
        var nextToken: UInt64 = 0
        var activeOperation: ActiveOperation?
        var pendingIdentity: GooglePendingIdentity?
        var pendingIdentityOperationToken: UInt64?
        var invalidatedOperationStates: [UInt64: GoogleConnectionWorkflowState] = [:]
        var unresolvedConnectionOperationTokens: Set<UInt64> = []
        var protectedConnectedOperationToken: UInt64?
        var rollbackOwners: Set<UInt64> = []
        var rollbackWaiters: [RollbackWaiter] = []
    }

    private let controller: any GoogleConnectionControlling
    private let settingsStore: any PrivateSettingsStore
    private let lock = NSLock()
    private var memory = Memory()

    public init(
        controller: any GoogleConnectionControlling,
        settingsStore: any PrivateSettingsStore
    ) {
        self.controller = controller
        self.settingsStore = settingsStore
    }

    public func loadState() async -> GoogleConnectionWorkflowState {
        let presence: GoogleCredentialPresence
        do {
            presence = try controller.credentialPresence()
        } catch {
            return Self.state(for: error)
        }

        let settings: PrivateSettings
        do {
            settings = try settingsStore.load()
        } catch {
            return .credentialUnavailable
        }

        return Self.loadedState(
            presence: presence,
            binding: settings.googleAccountBinding,
            capability: settings.googleGrantedCapability
        )
    }

    public func saveClientConfiguration(
        clientIdentifier: String,
        clientSecret: String
    ) async -> GoogleConnectionWorkflowState {
        guard let token = claimExclusiveOperation({ .saving($0) }) else {
            return .cleanupRequired
        }

        do {
            let configuration: GoogleOAuthClientConfiguration
            do {
                configuration = try GoogleOAuthClientConfiguration(
                    clientIdentifier: clientIdentifier,
                    clientSecret: clientSecret
                )
            } catch {
                throw GoogleConnectionControllerError.invalidConfiguration
            }
            try controller.saveClientConfiguration(configuration)
        } catch {
            finishOperation(token)
            return Self.state(for: error)
        }

        guard finishOperation(token) else {
            return staleOperationState(for: token)
        }
        return .readyToConnect
    }

    /// `capability` decides which approved scope set the consent screen asks for. Read-only is
    /// the default so no caller requests write access by omission.
    public func begin(
        capability: GoogleGrantedCapability = .readOnly,
        progress: @escaping @Sendable (GoogleConnectionWorkflowState) async -> Void
    ) async -> GoogleConnectionWorkflowState {
        guard let token = claimExclusiveOperation({ .beginning($0) }) else {
            return .cleanupRequired
        }

        let settings: PrivateSettings
        do {
            settings = try settingsStore.load()
        } catch {
            finishOperation(token)
            return .credentialUnavailable
        }
        guard ownsOperation(token) else {
            return staleOperationState(for: token)
        }

        let presence: GoogleCredentialPresence
        do {
            presence = try controller.credentialPresence()
        } catch {
            finishOperation(token)
            return Self.state(for: error)
        }
        guard ownsOperation(token) else {
            return staleOperationState(for: token)
        }

        switch presence {
        case .none:
            finishOperation(token)
            return settings.googleAccountBinding == nil ? .notConfigured : .cleanupRequired
        case .clientOnly:
            break
        case .complete:
            finishOperation(token)
            guard let binding = settings.googleAccountBinding else {
                return .cleanupRequired
            }
            return .connected(
                displayEmail: binding.normalizedEmail,
                capability: settings.googleGrantedCapability ?? .readOnly
            )
        case .inconsistent:
            finishOperation(token)
            return .cleanupRequired
        }

        let pendingIdentity: GooglePendingIdentity
        do {
            pendingIdentity = try await controller.begin(capability: capability) { [weak self] controllerProgress in
                guard let self, self.ownsOperation(token) else { return }
                await progress(Self.state(for: controllerProgress))
            }
        } catch {
            guard finishOperation(token) else {
                return staleOperationState(for: token)
            }
            return Self.state(for: error)
        }

        guard ownsOperation(token) else {
            await controller.cancelPendingConnection()
            return staleOperationState(for: token)
        }

        if let persistedBinding = settings.googleAccountBinding,
           persistedBinding != pendingIdentity.binding {
            await controller.cancelPendingConnection()
            finishOperation(token)
            return .identityMismatch
        }

        guard publishPendingIdentity(pendingIdentity, for: token) else {
            await controller.cancelPendingConnection()
            return staleOperationState(for: token)
        }
        return .confirmIdentity(displayEmail: pendingIdentity.displayEmail)
    }

    public func confirm() async -> GoogleConnectionWorkflowState {
        guard let (token, pendingIdentity) = claimPendingConfirmation() else {
            return .cleanupRequired
        }

        let receipt: GoogleConnectionReceipt
        do {
            receipt = try await controller.confirmPendingIdentity()
        } catch {
            guard finishOperation(token) else {
                return staleOperationState(for: token)
            }
            return Self.state(for: error)
        }

        guard ownsOperation(token) else {
            discardInvalidation(for: token)
            await rollbackConfirmedConnection(
                ownedBy: token,
                clearSettingsBinding: true
            )
            return .cleanupRequired
        }

        guard receipt.binding == pendingIdentity.binding else {
            await rollbackConfirmedConnection(
                ownedBy: token,
                clearSettingsBinding: false
            )
            releaseOperation(token)
            return .cleanupRequired
        }

        var settings: PrivateSettings
        do {
            settings = try settingsStore.load()
        } catch {
            await rollbackConfirmedConnection(
                ownedBy: token,
                clearSettingsBinding: false
            )
            releaseOperation(token)
            return .cleanupRequired
        }

        guard ownsOperation(token) else {
            discardInvalidation(for: token)
            await rollbackConfirmedConnection(
                ownedBy: token,
                clearSettingsBinding: true
            )
            return .cleanupRequired
        }

        settings.googleAccountBinding = receipt.binding
        // From the scopes Google actually granted, not from what was asked for.
        settings.googleGrantedCapability = GoogleGrantedCapability.matching(receipt.scopes)
        do {
            try settingsStore.replace(settings)
        } catch {
            await rollbackConfirmedConnection(
                ownedBy: token,
                clearSettingsBinding: false
            )
            releaseOperation(token)
            return .cleanupRequired
        }

        guard finishConnectedOperation(token) else {
            discardInvalidation(for: token)
            await rollbackConfirmedConnection(
                ownedBy: token,
                clearSettingsBinding: true
            )
            return .cleanupRequired
        }
        return .connected(
            displayEmail: pendingIdentity.displayEmail,
            capability: settings.googleGrantedCapability ?? .readOnly
        )
    }

    public func cancel() async -> GoogleConnectionWorkflowState {
        let token = claimPreemptingOperation(
            { .cancelling($0) },
            invalidatingWith: .cancelled
        )
        await controller.cancelPendingConnection()
        releaseOperation(token)
        return .cancelled
    }

    public func disconnect() async -> GoogleConnectionWorkflowState {
        await clearGrant(preservingClientConfiguration: false)
    }

    /// Clears the grant but keeps the OAuth client configuration, leaving the connection ready to
    /// consent again — the state `begin` requires. Used when upgrading to write access, which
    /// Google only grants through a fresh consent.
    public func disconnectForReconsent() async -> GoogleConnectionWorkflowState {
        await clearGrant(preservingClientConfiguration: true)
    }

    private func clearGrant(
        preservingClientConfiguration: Bool
    ) async -> GoogleConnectionWorkflowState {
        let token = claimPreemptingOperation(
            { .disconnecting($0) },
            invalidatingWith: .cleanupRequired
        )

        var controllerCleanupSucceeded = true
        do {
            if preservingClientConfiguration {
                try await controller.disconnectForReconsent()
            } else {
                try await controller.disconnect()
            }
        } catch {
            controllerCleanupSucceeded = false
        }

        let settingsCleanupSucceeded = clearPersistedBinding()
        let operationStayedCurrent = finishOperation(token)
        if !operationStayedCurrent {
            discardInvalidation(for: token)
        }
        return controllerCleanupSucceeded && settingsCleanupSucceeded && operationStayedCurrent
            ? .notConfigured
            : .cleanupRequired
    }

    private static func loadedState(
        presence: GoogleCredentialPresence,
        binding: GoogleIdentityBinding?,
        /// Absent on grants made before write access existed, which read as read-only.
        capability: GoogleGrantedCapability?
    ) -> GoogleConnectionWorkflowState {
        switch (presence, binding) {
        case (.none, nil):
            return .notConfigured
        case (.clientOnly, nil):
            return .readyToConnect
        case (.complete, .some(let binding)):
            return .connected(
                displayEmail: binding.normalizedEmail,
                capability: capability ?? .readOnly
            )
        case (.none, .some), (.clientOnly, .some), (.complete, nil), (.inconsistent, _):
            return .cleanupRequired
        }
    }

    private static func state(
        for progress: GoogleConnectionProgress
    ) -> GoogleConnectionWorkflowState {
        switch progress {
        case .connecting:
            return .connecting
        case .awaitingConsent:
            return .awaitingConsent
        }
    }

    private static func state(for error: Error) -> GoogleConnectionWorkflowState {
        guard let error = error as? GoogleConnectionControllerError else {
            return .providerUnavailable
        }
        switch error {
        case .notConfigured:
            return .notConfigured
        case .invalidConfiguration:
            return .cleanupRequired
        case .cancelled:
            return .cancelled
        case .offline:
            return .offline
        case .scopeMismatch:
            return .scopeMismatch
        case .identityMismatch:
            return .identityMismatch
        case .credentialUnavailable:
            return .credentialUnavailable
        case .providerUnavailable:
            return .providerUnavailable
        case .cleanupRequired:
            return .cleanupRequired
        }
    }

    private func claimExclusiveOperation(
        _ makeOperation: (UInt64) -> ActiveOperation
    ) -> UInt64? {
        lock.withLock {
            guard memory.activeOperation == nil,
                  memory.pendingIdentity == nil,
                  memory.rollbackOwners.isEmpty else {
                return nil
            }
            memory.nextToken &+= 1
            let token = memory.nextToken
            memory.activeOperation = makeOperation(token)
            memory.unresolvedConnectionOperationTokens.insert(token)
            return token
        }
    }

    private func claimPendingConfirmation() -> (UInt64, GooglePendingIdentity)? {
        lock.withLock {
            guard memory.activeOperation == nil,
                  let pendingIdentity = memory.pendingIdentity,
                  memory.rollbackOwners.isEmpty else {
                return nil
            }
            memory.nextToken &+= 1
            let token = memory.nextToken
            memory.pendingIdentity = nil
            if let pendingToken = memory.pendingIdentityOperationToken {
                memory.unresolvedConnectionOperationTokens.remove(pendingToken)
            }
            memory.pendingIdentityOperationToken = nil
            memory.activeOperation = .confirming(token)
            memory.unresolvedConnectionOperationTokens.insert(token)
            return (token, pendingIdentity)
        }
    }

    private func claimPreemptingOperation(
        _ makeOperation: (UInt64) -> ActiveOperation,
        invalidatingWith state: GoogleConnectionWorkflowState
    ) -> UInt64 {
        let (token, resumptions) = lock.withLock {
            if let displacedToken = memory.activeOperation?.token {
                memory.invalidatedOperationStates[displacedToken] = state
                memory.unresolvedConnectionOperationTokens.remove(displacedToken)
            }
            if let pendingToken = memory.pendingIdentityOperationToken {
                memory.unresolvedConnectionOperationTokens.remove(pendingToken)
            }
            memory.nextToken &+= 1
            let token = memory.nextToken
            memory.pendingIdentity = nil
            memory.pendingIdentityOperationToken = nil
            memory.activeOperation = makeOperation(token)
            return (token, resolveRollbackWaitersLocked())
        }
        resumeRollbackWaiters(resumptions)
        return token
    }

    private func publishPendingIdentity(
        _ pendingIdentity: GooglePendingIdentity,
        for token: UInt64
    ) -> Bool {
        lock.withLock {
            guard memory.activeOperation?.token == token else { return false }
            memory.pendingIdentity = pendingIdentity
            memory.pendingIdentityOperationToken = token
            memory.activeOperation = nil
            return true
        }
    }

    @discardableResult
    private func finishOperation(_ token: UInt64) -> Bool {
        let (didFinish, resumptions): (
            Bool,
            [(CheckedContinuation<Bool, Never>, Bool)]
        ) = lock.withLock {
            guard memory.activeOperation?.token == token else { return (false, []) }
            memory.activeOperation = nil
            memory.unresolvedConnectionOperationTokens.remove(token)
            return (true, resolveRollbackWaitersLocked())
        }
        resumeRollbackWaiters(resumptions)
        return didFinish
    }

    private func finishConnectedOperation(_ token: UInt64) -> Bool {
        let (didFinish, resumptions): (
            Bool,
            [(CheckedContinuation<Bool, Never>, Bool)]
        ) = lock.withLock {
            guard memory.activeOperation?.token == token else { return (false, []) }
            memory.activeOperation = nil
            memory.unresolvedConnectionOperationTokens.remove(token)
            memory.protectedConnectedOperationToken = token
            return (true, resolveRollbackWaitersLocked())
        }
        resumeRollbackWaiters(resumptions)
        return didFinish
    }

    private func ownsOperation(_ token: UInt64) -> Bool {
        lock.withLock { memory.activeOperation?.token == token }
    }

    private func staleOperationState(for token: UInt64) -> GoogleConnectionWorkflowState {
        lock.withLock {
            memory.invalidatedOperationStates.removeValue(forKey: token) ?? .cleanupRequired
        }
    }

    private func discardInvalidation(for token: UInt64) {
        lock.withLock {
            memory.invalidatedOperationStates[token] = nil
        }
    }

    private func releaseOperation(_ token: UInt64) {
        if !finishOperation(token) {
            discardInvalidation(for: token)
        }
    }

    private func rollbackConfirmedConnection(
        ownedBy token: UInt64,
        clearSettingsBinding: Bool
    ) async {
        guard await claimRollbackOwnership(for: token) else { return }
        try? await controller.disconnect()
        if clearSettingsBinding {
            _ = clearPersistedBinding()
        }
        releaseRollbackOwnership(for: token)
    }

    private func claimRollbackOwnership(for token: UInt64) async -> Bool {
        await withCheckedContinuation { continuation in
            let immediateDecision: Bool? = lock.withLock {
                if let protectedToken = memory.protectedConnectedOperationToken,
                   protectedToken > token {
                    return false
                }
                if memory.unresolvedConnectionOperationTokens.contains(where: { $0 > token }) {
                    memory.rollbackWaiters.append(
                        RollbackWaiter(token: token, continuation: continuation)
                    )
                    return nil
                }
                memory.rollbackOwners.insert(token)
                return true
            }
            if let immediateDecision {
                continuation.resume(returning: immediateDecision)
            }
        }
    }

    private func resolveRollbackWaitersLocked()
        -> [(CheckedContinuation<Bool, Never>, Bool)] {
        var pendingWaiters: [RollbackWaiter] = []
        var resumptions: [(CheckedContinuation<Bool, Never>, Bool)] = []

        for waiter in memory.rollbackWaiters {
            if let protectedToken = memory.protectedConnectedOperationToken,
               protectedToken > waiter.token {
                resumptions.append((waiter.continuation, false))
            } else if memory.unresolvedConnectionOperationTokens.contains(
                where: { $0 > waiter.token }
            ) {
                pendingWaiters.append(waiter)
            } else {
                memory.rollbackOwners.insert(waiter.token)
                resumptions.append((waiter.continuation, true))
            }
        }
        memory.rollbackWaiters = pendingWaiters
        return resumptions
    }

    private func resumeRollbackWaiters(
        _ resumptions: [(CheckedContinuation<Bool, Never>, Bool)]
    ) {
        for (continuation, decision) in resumptions {
            continuation.resume(returning: decision)
        }
    }

    private func releaseRollbackOwnership(for token: UInt64) {
        _ = lock.withLock {
            memory.rollbackOwners.remove(token)
        }
    }

    private func clearPersistedBinding() -> Bool {
        do {
            var settings = try settingsStore.load()
            guard settings.googleAccountBinding != nil else { return true }
            settings.googleAccountBinding = nil
            try settingsStore.replace(settings)
            return true
        } catch {
            return false
        }
    }
}
