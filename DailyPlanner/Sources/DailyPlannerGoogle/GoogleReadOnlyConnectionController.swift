import DailyPlannerDomain
import Foundation
import os

public protocol GoogleAuthorizationAuthorizing: Sendable {
    func authorize(
        clientIdentifier: String,
        timeout: Duration,
        capability: GoogleGrantedCapability,
        onAwaitingConsent: @escaping @Sendable () async -> Void
    ) async throws -> GoogleAuthorizationGrant
    func cancel()
}

extension GoogleAuthorizationAuthorizing {
    /// Read-only stays the default so a caller that has not opted into writes cannot ask for
    /// them by omission.
    public func authorize(
        clientIdentifier: String,
        timeout: Duration,
        onAwaitingConsent: @escaping @Sendable () async -> Void
    ) async throws -> GoogleAuthorizationGrant {
        try await authorize(
            clientIdentifier: clientIdentifier,
            timeout: timeout,
            capability: .readOnly,
            onAwaitingConsent: onAwaitingConsent
        )
    }
}

extension GoogleAuthorizationSession: GoogleAuthorizationAuthorizing {}

enum ConnectDiagnostics {
    static let log = Logger(subsystem: "com.example.dailyplanner", category: "google-connect")
}

public final class GoogleReadOnlyConnectionController: GoogleConnectionControlling, @unchecked Sendable {
    private struct SecretMaterial {
        var authorizationCode: String?
        var accessToken: String?
        var refreshToken: String?

        var bestRevocationCredential: String? {
            refreshToken ?? accessToken
        }

        mutating func merge(_ other: SecretMaterial) {
            authorizationCode = other.authorizationCode ?? authorizationCode
            accessToken = other.accessToken ?? accessToken
            refreshToken = other.refreshToken ?? refreshToken
        }
    }

    private struct PendingGrant {
        let material: SecretMaterial
        let receipt: GoogleConnectionReceipt
    }

    private enum Phase {
        case idle
        case savingClient(identifier: UUID)
        case beginning(
            identifier: UUID,
            material: SecretMaterial,
            cancellationRequested: Bool
        )
        case pending(PendingGrant)
        case confirming(identifier: UUID, grant: PendingGrant)
        case cancellingConfirmation(
            identifier: UUID,
            grant: PendingGrant,
            coordination: ConfirmationCancellationCoordination
        )
        case cleaning(identifier: UUID, material: SecretMaterial)
        case cleanupRequired(material: SecretMaterial)
    }

    private struct CleanupClaim {
        let identifier: UUID
        let material: SecretMaterial
        let cancellationRequested: Bool
        let confirmationCoordination: ConfirmationCancellationCoordination?
    }

    private enum CancellationAction {
        case none
        case cleanup(CleanupClaim)
        case cancellingConfirmation(
            coordination: ConfirmationCancellationCoordination,
            material: SecretMaterial,
            startsEagerCleanup: Bool
        )
    }

    private enum ConfirmationCompletion {
        case confirmed
        case cleanup(CleanupClaim)
    }

    private final class ConfirmationCancellationCoordination: @unchecked Sendable {
        private struct State {
            var eagerCleanupFinished = false
            var eagerRevocationFailed = false
            var eagerCleanupWaiters: [CheckedContinuation<Bool, Never>] = []
            var finalCleanupFinished = false
            var finalCleanupWaiters: [CheckedContinuation<Void, Never>] = []
        }

        private let lock = NSLock()
        private var state = State()

        func waitForEagerCleanup() async -> Bool {
            await withCheckedContinuation { continuation in
                let completedFailure = lock.withLock { () -> Bool? in
                    guard !state.eagerCleanupFinished else {
                        return state.eagerRevocationFailed
                    }
                    state.eagerCleanupWaiters.append(continuation)
                    return nil
                }
                if let completedFailure {
                    continuation.resume(returning: completedFailure)
                }
            }
        }

        func finishEagerCleanup(revocationFailed: Bool) {
            let waiters = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
                state.eagerRevocationFailed = revocationFailed
                state.eagerCleanupFinished = true
                defer { state.eagerCleanupWaiters.removeAll() }
                return state.eagerCleanupWaiters
            }
            waiters.forEach { $0.resume(returning: revocationFailed) }
        }

        func waitForFinalCleanup() async {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock { () -> Bool in
                    guard !state.finalCleanupFinished else { return true }
                    state.finalCleanupWaiters.append(continuation)
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        }

        func finishFinalCleanup() {
            let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                state.finalCleanupFinished = true
                defer { state.finalCleanupWaiters.removeAll() }
                return state.finalCleanupWaiters
            }
            waiters.forEach { $0.resume() }
        }
    }

    private struct GmailProfile: Decodable {
        let emailAddress: String
    }

    private struct ResourceKind: Decodable {
        let kind: String
    }

    private let lock = NSLock()
    private let authorization: any GoogleAuthorizationAuthorizing
    private let credentials: any GoogleOAuthCredentialStoring
    private let transport: any GoogleHTTPTransport
    private let tokenService: GoogleOAuthTokenService
    private let authorizationTimeout: Duration
    private var phase: Phase = .idle

    public init(
        authorization: any GoogleAuthorizationAuthorizing,
        credentials: any GoogleOAuthCredentialStoring,
        transport: any GoogleHTTPTransport,
        authorizationTimeout: Duration = .seconds(300)
    ) {
        self.authorization = authorization
        self.credentials = credentials
        self.transport = transport
        tokenService = GoogleOAuthTokenService(transport: transport)
        self.authorizationTimeout = authorizationTimeout
    }

    public func saveClientConfiguration(_ value: GoogleOAuthClientConfiguration) throws {
        let identifier = try reserveClientSave()
        defer { finishClientSave(identifier: identifier) }
        let refreshToken = try mappedCredentialOperation { try credentials.loadRefreshToken() }
        guard refreshToken == nil else {
            throw GoogleConnectionControllerError.invalidConfiguration
        }
        try mappedCredentialOperation { try credentials.storeClientConfiguration(value) }
    }

    public func credentialPresence() throws -> GoogleCredentialPresence {
        try rejectIfCleanupIsPending()
        return try mappedCredentialOperation { try credentials.presence() }
    }

    /// `capability` selects which approved scope set the consent screen asks for. Read-only
    /// remains the default, so connecting without asking for writes behaves exactly as before.
    public func begin(
        capability: GoogleGrantedCapability = .readOnly,
        progress: @escaping @Sendable (GoogleConnectionProgress) async -> Void
    ) async throws -> GooglePendingIdentity {
        let identifier = try reserveBegin()
        var latestMaterial = SecretMaterial()
        return try await withTaskCancellationHandler {
            do {
                let presence = try mappedCredentialOperation { try credentials.presence() }
                switch presence {
                case .clientOnly:
                    break
                case .none:
                    clearBeginWithoutCleanup(identifier: identifier)
                    throw GoogleConnectionControllerError.notConfigured
                case .complete, .inconsistent:
                    clearBeginWithoutCleanup(identifier: identifier)
                    throw GoogleConnectionControllerError.invalidConfiguration
                }

                let clientConfiguration = try mappedCredentialOperation {
                    try credentials.loadClientConfiguration()
                }
                guard let clientConfiguration else {
                    throw GoogleConnectionControllerError.invalidConfiguration
                }
                try checkpoint(identifier: identifier)
                stage("authorize")
                await progress(.connecting)
                try checkpoint(identifier: identifier)

                let grant = try await authorization.authorize(
                    clientIdentifier: clientConfiguration.clientIdentifier,
                    timeout: authorizationTimeout,
                    capability: capability,
                    onAwaitingConsent: { [weak self] in
                        guard self?.mayForwardProgress(identifier: identifier) == true else { return }
                        await progress(.awaitingConsent)
                    }
                )
                latestMaterial.authorizationCode = grant.authorizationCode
                try updateMaterial(identifier: identifier) {
                    $0.authorizationCode = grant.authorizationCode
                }

                stage("exchange")
                let exchange = try await exchange(
                    grant: grant,
                    clientConfiguration: clientConfiguration
                )
                latestMaterial.accessToken = exchange.accessToken
                latestMaterial.refreshToken = exchange.refreshToken
                try captureIssuedMaterial(
                    identifier: identifier,
                    material: latestMaterial
                )
                guard let refreshToken = exchange.refreshToken else {
                    throw GoogleConnectionControllerError.providerUnavailable
                }
                _ = try GoogleOAuthTokenService.validatedAccessToken(from: exchange)

                stage("refresh")
                let refreshed = try await tokenService.refresh(
                    clientConfiguration: clientConfiguration,
                    refreshToken: refreshToken
                )
                refreshed.withUnsafeRawValue { latestMaterial.accessToken = $0 }
                try captureIssuedMaterial(
                    identifier: identifier,
                    material: latestMaterial
                )

                stage("gmail-profile")
                let displayEmail = try await readGmailProfile(accessToken: refreshed)
                let binding: GoogleIdentityBinding
                do {
                    binding = try GoogleIdentityBinding(normalizing: displayEmail)
                } catch {
                    throw GoogleConnectionControllerError.identityMismatch
                }
                try checkpoint(identifier: identifier)

                stage("calendar-list")
                try await readResourceKind(
                    url: Self.calendarListURL,
                    expectedKind: "calendar#calendarList",
                    accessToken: refreshed
                )
                try checkpoint(identifier: identifier)
                stage("task-lists")
                try await readResourceKind(
                    url: Self.taskListsURL,
                    expectedKind: "tasks#taskLists",
                    accessToken: refreshed
                )
                try checkpoint(identifier: identifier)

                let receipt = GoogleConnectionReceipt(
                    scopes: capability.scopes,
                    refreshSucceeded: true,
                    gmailProfileRead: true,
                    calendarListRead: true,
                    taskListsRead: true,
                    binding: binding
                )
                let pendingIdentity = GooglePendingIdentity(
                    displayEmail: displayEmail,
                    binding: binding
                )
                try installPending(
                    identifier: identifier,
                    receipt: receipt
                )
                return pendingIdentity
            } catch {
                failed("begin", error)
                if isEligibilityErrorAlreadyCleared(error) {
                    throw error
                }
                guard let cleanupClaim = claimBeginForCleanup(
                    identifier: identifier,
                    fallback: latestMaterial
                ) else {
                    throw GoogleConnectionControllerError.cleanupRequired
                }
                let cleanupFailed = await cleanup(material: cleanupClaim.material)
                finishCleanup(
                    identifier: cleanupClaim.identifier,
                    material: cleanupClaim.material,
                    failed: cleanupFailed
                )
                if cleanupFailed {
                    throw GoogleConnectionControllerError.cleanupRequired
                }
                if cleanupClaim.cancellationRequested || Task.isCancelled {
                    throw GoogleConnectionControllerError.cancelled
                }
                throw finiteError(error)
            }
        } onCancel: {
            self.requestBeginCancellation(identifier: identifier)
            self.authorization.cancel()
        }
    }

    public func confirmPendingIdentity() async throws -> GoogleConnectionReceipt {
        let identifier = UUID()
        let pending = try claimPendingForConfirmation(identifier: identifier)
        do {
            guard let refreshToken = pending.material.refreshToken else {
                throw GoogleConnectionControllerError.providerUnavailable
            }
            try mappedCredentialOperation { try credentials.storeRefreshToken(refreshToken) }
        } catch {
            guard let cleanupClaim = claimConfirmationForCleanup(
                identifier: identifier,
                material: pending.material
            ) else {
                throw GoogleConnectionControllerError.cleanupRequired
            }
            let cleanupFailed = await performConfirmationCleanup(cleanupClaim)
            if cleanupFailed {
                throw GoogleConnectionControllerError.cleanupRequired
            }
            if cleanupClaim.cancellationRequested {
                throw GoogleConnectionControllerError.cancelled
            }
            throw finiteError(error)
        }
        guard let completion = claimConfirmationCompletion(identifier: identifier) else {
            throw GoogleConnectionControllerError.cleanupRequired
        }
        switch completion {
        case .confirmed:
            return pending.receipt
        case .cleanup(let cleanupClaim):
            let cleanupFailed = await performConfirmationCleanup(cleanupClaim)
            throw cleanupFailed
                ? GoogleConnectionControllerError.cleanupRequired
                : GoogleConnectionControllerError.cancelled
        }
    }

    public func cancelPendingConnection() async {
        authorization.cancel()
        let action: CancellationAction = locked { phase in
            switch phase {
            case .idle, .savingClient, .cleaning, .cleanupRequired:
                return .none
            case .beginning(let identifier, let material, _):
                phase = .beginning(
                    identifier: identifier,
                    material: material,
                    cancellationRequested: true
                )
                return .none
            case .pending(let pending):
                let identifier = UUID()
                phase = .cleaning(identifier: identifier, material: pending.material)
                return .cleanup(CleanupClaim(
                    identifier: identifier,
                    material: pending.material,
                    cancellationRequested: true,
                    confirmationCoordination: nil
                ))
            case .confirming(let identifier, let pending):
                let coordination = ConfirmationCancellationCoordination()
                phase = .cancellingConfirmation(
                    identifier: identifier,
                    grant: pending,
                    coordination: coordination
                )
                return .cancellingConfirmation(
                    coordination: coordination,
                    material: pending.material,
                    startsEagerCleanup: true
                )
            case .cancellingConfirmation(_, let pending, let coordination):
                return .cancellingConfirmation(
                    coordination: coordination,
                    material: pending.material,
                    startsEagerCleanup: false
                )
            }
        }
        switch action {
        case .none:
            return
        case .cleanup(let cleanup):
            let cleanupFailed = await self.cleanup(material: cleanup.material)
            finishCleanup(
                identifier: cleanup.identifier,
                material: cleanup.material,
                failed: cleanupFailed
            )
        case .cancellingConfirmation(let coordination, let material, let startsEagerCleanup):
            if startsEagerCleanup {
                let revocationFailed = await performEagerConfirmationCleanup(material: material)
                coordination.finishEagerCleanup(revocationFailed: revocationFailed)
            }
            await coordination.waitForFinalCleanup()
        }
    }

    /// Revokes and clears the grant, then restores the client configuration that `disconnect()`
    /// necessarily removed along with it. Reuses the whole tested cleanup path rather than
    /// reimplementing a partial teardown, so revocation still happens exactly as it does on a
    /// real disconnect.
    public func disconnectForReconsent() async throws {
        // Read the client configuration FIRST and refuse to go any further without it.
        //
        // This previously used `try?`, so a failed read — a denied or unanswered Keychain
        // prompt, which is exactly the situation a reconnect happens in — silently became nil.
        // The disconnect then deleted both keychain items and there was nothing to restore, so
        // the user lost their client id and secret and had to re-enter them from the Google
        // Cloud console. That is destroying data because we could not read it, which is the
        // worst possible response. It cost Braxton his credentials once; never again.
        let clientConfiguration: GoogleOAuthClientConfiguration?
        do {
            clientConfiguration = try credentials.loadClientConfiguration()
        } catch {
            throw GoogleConnectionControllerError.credentialUnavailable
        }
        guard let clientConfiguration else {
            // Nothing stored to preserve, so there is also nothing to re-consent with.
            throw GoogleConnectionControllerError.notConfigured
        }

        try await disconnect()

        // Restoring is not optional: if it fails, say so rather than reporting a successful
        // "upgrade" that has actually left the account unconfigured.
        try mappedCredentialOperation {
            try credentials.storeClientConfiguration(clientConfiguration)
        }
    }

    public func disconnect() async throws {
        authorization.cancel()
        let cleanup = try reserveDisconnectCleanup()

        var cleanupFailed = false
        var persistedRefresh: String?
        do {
            persistedRefresh = try credentials.loadRefreshToken()
        } catch {
            cleanupFailed = true
        }

        var material = cleanup.material
        if let persistedRefresh {
            material.refreshToken = persistedRefresh
        }
        if await revokeBestCredential(in: material) == false {
            cleanupFailed = true
        }
        do {
            try credentials.deleteAll()
        } catch {
            cleanupFailed = true
        }
        finishCleanup(
            identifier: cleanup.identifier,
            material: material,
            failed: cleanupFailed
        )
        if cleanupFailed {
            throw GoogleConnectionControllerError.cleanupRequired
        }
    }

    private func exchange(
        grant: GoogleAuthorizationGrant,
        clientConfiguration: GoogleOAuthClientConfiguration
    ) async throws -> GoogleOAuthTokenService.TokenResponse {
        let request = Self.formRequest(
            url: Self.tokenURL,
            fields: [
                ("code", grant.authorizationCode),
                ("client_id", clientConfiguration.clientIdentifier),
                ("client_secret", clientConfiguration.clientSecret),
                ("redirect_uri", grant.request.redirectURL.absoluteString),
                ("code_verifier", grant.request.pkce.verifier),
                ("grant_type", "authorization_code"),
            ]
        )
        return try await tokenResponse(for: request)
    }

    private func tokenResponse(
        for request: URLRequest
    ) async throws -> GoogleOAuthTokenService.TokenResponse {
        let response = try await send(request)
        guard (200...299).contains(response.statusCode) else {
            // The status separates the two things this failure is usually made of: a 400/401
            // means Google rejected the credentials themselves (a mistyped client secret is
            // `invalid_client`), while a 5xx means Google is having a bad day and retrying is
            // the right response. Collapsing both into `providerUnavailable` told the user to
            // wait when the fix was in their hands. The status is an integer, so no token,
            // secret or account content can travel with it.
            ConnectDiagnostics.log.error(
                "google connect: token exchange rejected, status \(response.statusCode, privacy: .public)"
            )
            throw GoogleConnectionControllerError.providerUnavailable
        }
        do {
            return try GoogleOAuthTokenService.decodeTokenResponse(response.data)
        } catch {
            ConnectDiagnostics.log.error("google connect: token response did not decode")
            throw GoogleConnectionControllerError.providerUnavailable
        }
    }

    private func readGmailProfile(accessToken: GoogleAccessToken) async throws -> String {
        let response = try await send(Self.providerRequest(
            url: Self.gmailProfileURL,
            accessToken: accessToken
        ))
        guard (200...299).contains(response.statusCode),
              let profile = try? JSONDecoder().decode(GmailProfile.self, from: response.data) else {
            throw GoogleConnectionControllerError.providerUnavailable
        }
        return profile.emailAddress
    }

    private func readResourceKind(
        url: URL,
        expectedKind: String,
        accessToken: GoogleAccessToken
    ) async throws {
        let response = try await send(Self.providerRequest(url: url, accessToken: accessToken))
        guard (200...299).contains(response.statusCode),
              let resource = try? JSONDecoder().decode(ResourceKind.self, from: response.data),
              resource.kind == expectedKind else {
            throw GoogleConnectionControllerError.providerUnavailable
        }
    }

    private func send(_ request: URLRequest) async throws -> GoogleHTTPResponse {
        do {
            return try await transport.send(request)
        } catch is CancellationError {
            throw GoogleConnectionControllerError.cancelled
        } catch let error as GoogleHTTPTransportError {
            switch error {
            case .cancelled:
                throw GoogleConnectionControllerError.cancelled
            case .requestFailed:
                throw GoogleConnectionControllerError.offline
            case .nonHTTPResponse:
                throw GoogleConnectionControllerError.providerUnavailable
            }
        } catch {
            throw GoogleConnectionControllerError.providerUnavailable
        }
    }

    private func cleanup(material: SecretMaterial?) async -> Bool {
        var failed = false
        if let material, await revokeBestCredential(in: material) == false {
            failed = true
        }
        if deleteGrantFailed() {
            failed = true
        }
        return failed
    }

    private func revokeBestCredential(in material: SecretMaterial) async -> Bool {
        guard let value = material.bestRevocationCredential else { return true }
        let response: GoogleHTTPResponse
        do {
            response = try await transport.send(Self.formRequest(
                url: Self.revokeURL,
                fields: [("token", value)]
            ))
        } catch {
            return false
        }
        return (200...299).contains(response.statusCode)
    }

    private func reserveBegin() throws -> UUID {
        try locked { phase in
            switch phase {
            case .idle:
                let identifier = UUID()
                phase = .beginning(
                    identifier: identifier,
                    material: SecretMaterial(),
                    cancellationRequested: false
                )
                return identifier
            case .cancellingConfirmation, .cleaning, .cleanupRequired:
                throw GoogleConnectionControllerError.cleanupRequired
            default:
                throw GoogleConnectionControllerError.invalidConfiguration
            }
        }
    }

    private func reserveClientSave() throws -> UUID {
        try locked { phase in
            switch phase {
            case .idle:
                let identifier = UUID()
                phase = .savingClient(identifier: identifier)
                return identifier
            case .cancellingConfirmation, .cleaning, .cleanupRequired:
                throw GoogleConnectionControllerError.cleanupRequired
            default:
                throw GoogleConnectionControllerError.invalidConfiguration
            }
        }
    }

    private func finishClientSave(identifier: UUID) {
        locked { phase in
            guard case .savingClient(let activeIdentifier) = phase,
                  activeIdentifier == identifier else { return }
            phase = .idle
        }
    }

    private func rejectIfCleanupIsPending() throws {
        try locked { phase in
            switch phase {
            case .cancellingConfirmation, .cleaning, .cleanupRequired:
                throw GoogleConnectionControllerError.cleanupRequired
            default:
                return
            }
        }
    }

    private func reserveDisconnectCleanup() throws -> CleanupClaim {
        try locked { phase in
            let material: SecretMaterial
            switch phase {
            case .idle:
                material = SecretMaterial()
            case .pending(let pending):
                material = pending.material
            case .cleanupRequired(let pending):
                material = pending
            case .cancellingConfirmation, .cleaning:
                throw GoogleConnectionControllerError.cleanupRequired
            case .beginning, .savingClient, .confirming:
                throw GoogleConnectionControllerError.invalidConfiguration
            }
            let identifier = UUID()
            phase = .cleaning(identifier: identifier, material: material)
            return CleanupClaim(
                identifier: identifier,
                material: material,
                cancellationRequested: false,
                confirmationCoordination: nil
            )
        }
    }

    private func finishCleanup(
        identifier: UUID,
        material: SecretMaterial,
        failed: Bool
    ) {
        locked { phase in
            guard case .cleaning(let activeIdentifier, _) = phase,
                  activeIdentifier == identifier else { return }
            phase = failed ? .cleanupRequired(material: material) : .idle
        }
    }

    private func performConfirmationCleanup(_ claim: CleanupClaim) async -> Bool {
        let cleanupFailed: Bool
        if let coordination = claim.confirmationCoordination {
            // A synchronous store may complete after eager deletion, so delete once more after it returns.
            let revocationFailed = await coordination.waitForEagerCleanup()
            let deletionFailed = deleteGrantFailed()
            cleanupFailed = revocationFailed || deletionFailed
        } else {
            cleanupFailed = await cleanup(material: claim.material)
        }
        finishCleanup(
            identifier: claim.identifier,
            material: claim.material,
            failed: cleanupFailed
        )
        claim.confirmationCoordination?.finishFinalCleanup()
        return cleanupFailed
    }

    private func performEagerConfirmationCleanup(material: SecretMaterial) async -> Bool {
        let revocationFailed = await revokeBestCredential(in: material) == false
        // The post-store deletion is authoritative; this first attempt closes the common fast path.
        _ = deleteGrantFailed()
        return revocationFailed
    }

    /// Cleanup after a failed, cancelled or timed-out attempt clears the grant only.
    ///
    /// This used to call `deleteAll()`, which also removed the client id and secret. Sitting on
    /// Google's unverified-app interstitial for longer than `authorizationTimeout` was therefore
    /// enough to wipe the OAuth client the user had entered by hand, and the only way back was
    /// the Google Cloud console. Same mistake as the one `disconnectForReconsent` made: treating
    /// "this did not finish" as licence to destroy something the user gave us. It is not.
    /// Names the step a connection attempt reached, and the finite reason it stopped.
    ///
    /// A failed `begin()` had no logger anywhere on its path, so a connection that died after
    /// Google had already returned an authorization code left nothing behind: the workflow maps
    /// the error to a state, and the next `loadGoogleConnectionState()` overwrites that state
    /// with a neutral "ready to connect" derived from credential presence. The user sees a
    /// button, not a failure, and there is nothing to read afterwards.
    ///
    /// `providerUnavailable` is the catch-all for six different steps, so the stage matters as
    /// much as the error. Both are `StaticString` literals written here, exactly like the
    /// calendar decoder's reasons, so no email address, token, URL or account content can reach
    /// the log through this path.
    private func stage(_ step: StaticString) {
        ConnectDiagnostics.log.notice("google connect: \(step, privacy: .public)")
    }

    private func failed(_ step: StaticString, _ error: Error) {
        let reason: StaticString = (error as? GoogleConnectionControllerError)?.diagnosticName ?? "unknown"
        ConnectDiagnostics.log.error(
            "google connect failed at \(step, privacy: .public): \(reason, privacy: .public)"
        )
    }

    private func deleteGrantFailed() -> Bool {
        do {
            try credentials.deleteGrant()
            return false
        } catch {
            return true
        }
    }

    private func checkpoint(identifier: UUID) throws {
        let mayContinue = locked { phase -> Bool in
            guard case .beginning(let activeIdentifier, _, let cancellationRequested) = phase else {
                return false
            }
            return activeIdentifier == identifier && !cancellationRequested
        }
        guard mayContinue, !Task.isCancelled else {
            throw GoogleConnectionControllerError.cancelled
        }
    }

    private func mayForwardProgress(identifier: UUID) -> Bool {
        locked { phase in
            guard case .beginning(let activeIdentifier, _, let cancellationRequested) = phase else {
                return false
            }
            return activeIdentifier == identifier && !cancellationRequested
        }
    }

    private func updateMaterial(
        identifier: UUID,
        update: (inout SecretMaterial) -> Void
    ) throws {
        try locked { phase in
            guard case .beginning(
                let activeIdentifier,
                var material,
                let cancellationRequested
            ) = phase,
            activeIdentifier == identifier,
            !cancellationRequested else {
                throw GoogleConnectionControllerError.cancelled
            }
            update(&material)
            phase = .beginning(
                identifier: activeIdentifier,
                material: material,
                cancellationRequested: false
            )
        }
    }

    private func captureIssuedMaterial(
        identifier: UUID,
        material issued: SecretMaterial
    ) throws {
        let cancellationRequested = try locked { phase -> Bool in
            guard case .beginning(
                let activeIdentifier,
                var material,
                let cancellationRequested
            ) = phase,
            activeIdentifier == identifier else {
                throw GoogleConnectionControllerError.cancelled
            }
            material.merge(issued)
            phase = .beginning(
                identifier: activeIdentifier,
                material: material,
                cancellationRequested: cancellationRequested
            )
            return cancellationRequested
        }
        if cancellationRequested || Task.isCancelled {
            throw GoogleConnectionControllerError.cancelled
        }
    }

    private func installPending(
        identifier: UUID,
        receipt: GoogleConnectionReceipt
    ) throws {
        try locked { phase in
            guard case .beginning(
                let activeIdentifier,
                let material,
                let cancellationRequested
            ) = phase,
            activeIdentifier == identifier,
            !cancellationRequested else {
                throw GoogleConnectionControllerError.cancelled
            }
            phase = .pending(PendingGrant(
                material: material,
                receipt: receipt
            ))
        }
    }

    private func requestBeginCancellation(identifier: UUID) {
        locked { phase in
            guard case .beginning(let activeIdentifier, let material, _) = phase,
                  activeIdentifier == identifier else { return }
            phase = .beginning(
                identifier: activeIdentifier,
                material: material,
                cancellationRequested: true
            )
        }
    }

    private func clearBeginWithoutCleanup(identifier: UUID) {
        locked { phase in
            guard case .beginning(let activeIdentifier, _, _) = phase,
                  activeIdentifier == identifier else { return }
            phase = .idle
        }
    }

    private func claimBeginForCleanup(
        identifier: UUID,
        fallback: SecretMaterial
    ) -> CleanupClaim? {
        locked { phase in
            guard case .beginning(
                let activeIdentifier,
                var material,
                let cancellationRequested
            ) = phase,
            activeIdentifier == identifier else {
                return nil
            }
            material.merge(fallback)
            let cleanupIdentifier = UUID()
            phase = .cleaning(identifier: cleanupIdentifier, material: material)
            return CleanupClaim(
                identifier: cleanupIdentifier,
                material: material,
                cancellationRequested: cancellationRequested,
                confirmationCoordination: nil
            )
        }
    }

    private func claimPendingForConfirmation(identifier: UUID) throws -> PendingGrant {
        try locked { phase in
            switch phase {
            case .pending(let pending):
                phase = .confirming(identifier: identifier, grant: pending)
                return pending
            case .cancellingConfirmation, .cleaning, .cleanupRequired:
                throw GoogleConnectionControllerError.cleanupRequired
            default:
                throw GoogleConnectionControllerError.notConfigured
            }
        }
    }

    private func claimConfirmationCompletion(identifier: UUID) -> ConfirmationCompletion? {
        locked { phase in
            switch phase {
            case .confirming(let activeIdentifier, _):
                guard activeIdentifier == identifier else { return nil }
                phase = .idle
                return .confirmed
            case .cancellingConfirmation(
                let activeIdentifier,
                let pending,
                let coordination
            ):
                guard activeIdentifier == identifier else { return nil }
                let cleanupIdentifier = UUID()
                phase = .cleaning(identifier: cleanupIdentifier, material: pending.material)
                return .cleanup(CleanupClaim(
                    identifier: cleanupIdentifier,
                    material: pending.material,
                    cancellationRequested: true,
                    confirmationCoordination: coordination
                ))
            default:
                return nil
            }
        }
    }

    private func claimConfirmationForCleanup(
        identifier: UUID,
        material: SecretMaterial
    ) -> CleanupClaim? {
        locked { phase in
            let cancellationRequested: Bool
            let coordination: ConfirmationCancellationCoordination?
            switch phase {
            case .confirming(let activeIdentifier, _):
                guard activeIdentifier == identifier else { return nil }
                cancellationRequested = false
                coordination = nil
            case .cancellingConfirmation(
                let activeIdentifier,
                _,
                let activeCoordination
            ):
                guard activeIdentifier == identifier else { return nil }
                cancellationRequested = true
                coordination = activeCoordination
            default:
                return nil
            }
            let cleanupIdentifier = UUID()
            phase = .cleaning(identifier: cleanupIdentifier, material: material)
            return CleanupClaim(
                identifier: cleanupIdentifier,
                material: material,
                cancellationRequested: cancellationRequested,
                confirmationCoordination: coordination
            )
        }
    }

    private var isIdle: Bool {
        locked { phase in
            if case .idle = phase { return true }
            return false
        }
    }

    private func isEligibilityErrorAlreadyCleared(_ error: Error) -> Bool {
        guard let error = error as? GoogleConnectionControllerError,
              error == .notConfigured || error == .invalidConfiguration else { return false }
        return isIdle
    }

    private func mappedCredentialOperation<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch let error as GoogleOAuthCredentialStoreError {
            switch error {
            case .unavailable, .malformed:
                throw GoogleConnectionControllerError.credentialUnavailable
            case .invalidValue:
                throw GoogleConnectionControllerError.invalidConfiguration
            }
        } catch {
            throw GoogleConnectionControllerError.credentialUnavailable
        }
    }

    private func finiteError(_ error: Error) -> GoogleConnectionControllerError {
        if let error = error as? GoogleConnectionControllerError {
            return error
        }
        if let error = error as? GoogleAuthorizationSessionError {
            switch error {
            case .cancelled:
                return .cancelled
            case .timedOut, .listenerFailed:
                return .offline
            case .requestConstructionFailed:
                return .invalidConfiguration
            case .alreadyAuthorizing, .invalidCallback, .browserRejected:
                return .providerUnavailable
            }
        }
        if let error = error as? GoogleAccessTokenProviderError {
            switch error {
            case .cancelled:
                return .cancelled
            case .offline:
                return .offline
            case .scopeMismatch:
                return .scopeMismatch
            case .credentialUnavailable:
                return .credentialUnavailable
            case .notConfigured:
                return .invalidConfiguration
            case .rejected, .malformedResponse:
                return .providerUnavailable
            }
        }
        if error is CancellationError {
            return .cancelled
        }
        return .providerUnavailable
    }

    private static func formRequest(url: URL, fields: [(String, String)]) -> URLRequest {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.0, value: $0.1) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        return request
    }

    private static func providerRequest(url: URL, accessToken: GoogleAccessToken) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        accessToken.withUnsafeRawValue {
            request.setValue("Bearer \($0)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    @discardableResult
    private func locked<T>(_ body: (inout Phase) throws -> T) rethrows -> T {
        try lock.withLock { try body(&phase) }
    }

    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let revokeURL = URL(string: "https://oauth2.googleapis.com/revoke")!
    private static let gmailProfileURL = URL(
        string: "https://gmail.googleapis.com/gmail/v1/users/me/profile"
    )!
    private static let calendarListURL = URL(
        string: "https://www.googleapis.com/calendar/v3/users/me/calendarList?maxResults=1"
    )!
    private static let taskListsURL = URL(
        string: "https://tasks.googleapis.com/tasks/v1/users/@me/lists?maxResults=1"
    )!
}
