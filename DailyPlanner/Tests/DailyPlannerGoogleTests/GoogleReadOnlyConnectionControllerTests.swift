import DailyPlannerDomain
import Foundation
import XCTest
@testable import DailyPlannerGoogle

final class GoogleReadOnlyConnectionControllerTests: XCTestCase {
    func testBeginRefreshesAndPerformsOnlyThreeReadsBeforeReturningPendingIdentity() async throws {
        // Break caught: begin persists early, skips refresh, or broadens the three-read canary.
        let harness = ControllerHarness.success(email: "Owner@Example.Test")

        let pending = try await harness.controller.begin(progress: { _ in })

        XCTAssertEqual(pending.displayEmail, "Owner@Example.Test")
        XCTAssertEqual(pending.binding.normalizedEmail, "owner@example.test")
        XCTAssertEqual(harness.transport.recordedMethodsAndPaths, [
            "POST /token", "POST /token", "GET /gmail/v1/users/me/profile",
            "GET /calendar/v3/users/me/calendarList", "GET /tasks/v1/users/@me/lists",
        ])
        XCTAssertTrue(harness.authorization.receivedExpectedClientIdentifier)
        XCTAssertTrue(harness.transport.exchangeFormWasExact)
        XCTAssertTrue(harness.transport.refreshFormWasExact)
        XCTAssertTrue(harness.transport.providerAuthorizationWasBearerOnly)
        XCTAssertEqual(try harness.credentials.presence(), .clientOnly)
        XCTAssertEqual(harness.credentials.refreshStoreCount, 0)
        XCTAssertTrue(harness.authorization.authorizationURLWasSecretFree)

        await harness.controller.cancelPendingConnection()
        XCTAssertTrue(harness.transport.clientSecretWasAbsentFromNonTokenRequests)
    }

    func testBeginForwardsConnectingThenAuthorizationReadinessProgress() async throws {
        // Break caught: awaiting-consent is invented before the authorization boundary reports readiness.
        let harness = ControllerHarness.success()
        let progress = ProgressRecorder()

        _ = try await harness.controller.begin { value in progress.append(value) }

        XCTAssertEqual(progress.values, [.connecting, .awaitingConsent])
        XCTAssertEqual(harness.authorization.awaitingConsentCallbackCount, 1)
    }

    func testConfirmPersistsRefreshAndReturnsSanitizedReceipt() async throws {
        // Break caught: confirmation omits persistence, returns incomplete proof, or leaks pending secrets.
        let harness = ControllerHarness.success(email: "owner@example.test")
        _ = try await harness.controller.begin(progress: { _ in })

        let receipt = try await harness.controller.confirmPendingIdentity()

        XCTAssertEqual(try harness.credentials.presence(), .complete)
        XCTAssertTrue(receipt.refreshSucceeded && receipt.gmailProfileRead)
        XCTAssertTrue(receipt.calendarListRead && receipt.taskListsRead)
        XCTAssertEqual(receipt.scopes, ApprovedGoogleScopes.readOnly)
        XCTAssertEqual(receipt.binding.normalizedEmail, "owner@example.test")
        assertSecretCanariesAbsent(from: String(reflecting: receipt))
    }

    func testEveryBeginFailureRevokesClearsTheGrantKeepsTheClientAndClearsPendingGrant() async throws {
        // Break caught: any failure branch leaves a grant persisted or confirmable — or destroys
        // the client configuration, which no failed attempt is ever allowed to touch.
        for point in ControllerFailurePoint.allCases {
            let harness = ControllerHarness.failure(at: point)
            do {
                _ = try await harness.controller.begin(progress: { _ in })
                XCTFail("Expected injected failure at \(point)")
            } catch {
                XCTAssertNotNil(error as? GoogleConnectionControllerError, "Failure point \(point)")
                assertSecretCanariesAbsent(from: String(reflecting: error))
            }
            XCTAssertEqual(try harness.credentials.presence(), .clientOnly, "Failure point \(point)")
            XCTAssertTrue(
                harness.transport.revocationAttemptedWhenCredentialExisted,
                "Failure point \(point)"
            )
            XCTAssertEqual(harness.credentials.deleteGrantCount, 1, "Failure point \(point)")
            XCTAssertEqual(harness.credentials.deleteAllCount, 0, "Failure point \(point)")
            do {
                _ = try await harness.controller.confirmPendingIdentity()
                XCTFail("A failed begin must not leave a confirmable grant")
            } catch {
                let expected: GoogleConnectionControllerError =
                    point.hasIncompleteCleanup ? .cleanupRequired : .notConfigured
                XCTAssertEqual(error as? GoogleConnectionControllerError, expected)
            }
        }
    }

    func testScopeMustBeTheExactApprovedSet() async {
        // Break caught: missing, duplicate, reordered-membership, or added scopes are accepted.
        let variants = [
            Array(ApprovedGoogleScopes.readOnly.dropLast()),
            ApprovedGoogleScopes.readOnly + ["https://scope.example.test/unapproved"],
            ApprovedGoogleScopes.readOnly + [ApprovedGoogleScopes.readOnly[0]],
        ]

        for grantedScopes in variants {
            let harness = ControllerHarness.success(grantedScopes: grantedScopes)
            await assertControllerError(.scopeMismatch) {
                _ = try await harness.controller.begin(progress: { _ in })
            }
            XCTAssertEqual(try? harness.credentials.presence(), Optional(GoogleCredentialPresence.clientOnly))
        }
    }

    func testEmailScopeAliasIsEquivalentWithoutExpandingReceipt() async throws {
        // Break caught: Google's email alias is rejected or leaks into the connection receipt.
        let alias = "https://www.googleapis.com/auth/userinfo.email"
        let providerScopes = ApprovedGoogleScopes.readOnly.map { $0 == "email" ? alias : $0 }

        let harness = ControllerHarness.success(grantedScopes: providerScopes)

        _ = try await harness.controller.begin(progress: { _ in })
        let receipt = try await harness.controller.confirmPendingIdentity()

        XCTAssertEqual(receipt.scopes, ApprovedGoogleScopes.readOnly)
    }

    func testEmailScopeAndAliasTogetherAreRejectedAsCanonicalDuplicate() async {
        // Break caught: the alias and canonical email scope collapse to one set member and hide a duplicate.
        let alias = "https://www.googleapis.com/auth/userinfo.email"
        let harness = ControllerHarness.success(
            grantedScopes: ApprovedGoogleScopes.readOnly + [alias]
        )

        await assertControllerError(.scopeMismatch) {
            _ = try await harness.controller.begin(progress: { _ in })
        }
    }

    func testWrongGrantedScopeRevokesTheIssuedRefreshCredential() async {
        // Break caught: scope validation fails before the newly issued refresh credential is retained for cleanup.
        let harness = ControllerHarness.failure(at: .wrongGrantedScope)

        await assertControllerError(.scopeMismatch) {
            _ = try await harness.controller.begin(progress: { _ in })
        }

        XCTAssertEqual(harness.transport.lastRevokedCredentialKind, .refresh)
    }

    func testMalformedIssuedTokenResponseRevokesTheIssuedRefreshCredential() async {
        // Break caught: semantic token validation falls back to revoking the consumed authorization code.
        let harness = ControllerHarness.failure(at: .malformedIssuedToken)

        await assertControllerError(.providerUnavailable) {
            _ = try await harness.controller.begin(progress: { _ in })
        }

        XCTAssertEqual(harness.transport.lastRevokedCredentialKind, .refresh)
    }

    func testCancellationAfterExchangeResponseRevokesTheIssuedRefreshCredential() async {
        // Break caught: cancellation between exchange completion and state update loses issued credentials.
        let transport = RecordingControllerTransport(pauseExchangeResponse: true)
        let harness = ControllerHarness(transport: transport)
        let task = Task<GooglePendingIdentity, Error> {
            try await harness.controller.begin(progress: { _ in })
        }
        await transport.waitUntilExchangeResponseReady()

        task.cancel()
        transport.releaseExchangeResponse()

        await assertControllerTaskError(.cancelled, task: task)
        XCTAssertEqual(transport.lastRevokedCredentialKind, .refresh)
    }

    func testRefreshTransportCancellationRemainsCancelledWithoutTaskCancellation() async {
        // Break caught: the shared refresh boundary collapses a transport cancellation into offline.
        let harness = ControllerHarness.failure(at: .refreshCancellation)

        await assertControllerError(.cancelled) {
            _ = try await harness.controller.begin(progress: { _ in })
        }

        XCTAssertEqual(harness.transport.lastRevokedCredentialKind, .refresh)
    }

    func testMalformedAndNonSuccessProviderResponsesAreFiniteAndSanitized() async {
        // Break caught: response bodies, URLs, or dynamic failures escape the finite controller boundary.
        for responseFailure in ResponseFailure.allCases {
            let harness = ControllerHarness.responseFailure(responseFailure)
            do {
                _ = try await harness.controller.begin(progress: { _ in })
                XCTFail("Expected response rejection at \(responseFailure)")
            } catch {
                XCTAssertEqual(error as? GoogleConnectionControllerError, .providerUnavailable)
                assertSecretCanariesAbsent(from: String(reflecting: error))
            }
            XCTAssertEqual(try? harness.credentials.presence(), Optional(GoogleCredentialPresence.clientOnly))
        }
    }

    func testConfirmStoreFailureRollsBackAndMapsCredentialStoreErrors() async throws {
        // Break caught: a failed refresh-token persistence leaves the pending grant or client record behind.
        for storeError in [GoogleOAuthCredentialStoreError.unavailable, .malformed] {
            let harness = ControllerHarness.success()
            _ = try await harness.controller.begin(progress: { _ in })
            harness.credentials.failNextRefreshStore(with: storeError)

            await assertControllerError(.credentialUnavailable) {
                _ = try await harness.controller.confirmPendingIdentity()
            }

            XCTAssertEqual(try harness.credentials.presence(), .clientOnly)
            XCTAssertTrue(harness.transport.revocationAttemptedWhenCredentialExisted)
            await assertControllerError(.notConfigured) {
                _ = try await harness.controller.confirmPendingIdentity()
            }
        }
    }

    func testCancellingBlockedConfirmationCompensatesAfterTheLateStoreCompletes() async throws {
        // Break caught: cancellation deletes first, then a blocked confirmation store recreates the refresh token.
        let credentials = RecordingCredentialStore(
            presence: .clientOnly,
            pauseRefreshStore: true
        )
        let harness = ControllerHarness(credentials: credentials)
        _ = try await harness.controller.begin(progress: { _ in })
        let confirmation = Task<GoogleConnectionReceipt, Error> {
            try await harness.controller.confirmPendingIdentity()
        }
        await credentials.waitUntilRefreshStoreStarted()

        let cancellation = Task {
            await harness.controller.cancelPendingConnection()
        }
        await waitUntil { credentials.deleteGrantCount == 1 }

        credentials.releaseRefreshStore()

        await assertControllerTaskError(.cancelled, task: confirmation)
        await cancellation.value
        XCTAssertEqual(harness.transport.revokeAttemptCount, 1)
        XCTAssertEqual(credentials.deleteGrantCount, 2)
        XCTAssertEqual(credentials.deleteAllCount, 0)
        XCTAssertEqual(try harness.controller.credentialPresence(), .clientOnly)

        try harness.controller.saveClientConfiguration(Synthetic.replacementClientConfiguration)
        XCTAssertEqual(try harness.controller.credentialPresence(), .clientOnly)
    }

    func testCleanupFailureOverridesOperationFailureButStillMakesEveryAttempt() async {
        // Break caught: cleanup stops after revoke or delete fails, or hides an incomplete rollback.
        for point in [ControllerFailurePoint.revokeCleanup, .deleteCleanup] {
            let harness = ControllerHarness.failure(at: point)

            await assertControllerError(.cleanupRequired) {
                _ = try await harness.controller.begin(progress: { _ in })
            }

            XCTAssertEqual(harness.transport.revokeAttemptCount, 1)
            XCTAssertEqual(harness.credentials.deleteGrantCount, 1)
            XCTAssertEqual(try? harness.credentials.presence(), Optional(GoogleCredentialPresence.clientOnly))
        }
    }

    func testCleanupExcludesBeginSaveConfirmAndDisconnectUntilItFinishes() async {
        // Break caught: cleanup publishes idle, allowing a new operation whose credentials the old delete removes.
        let authorization = RecordingAuthorization(mode: .succeedOnceThenCancel)
        let transport = RecordingControllerTransport(
            failurePoint: .gmailRead,
            pauseRevocation: true
        )
        let harness = ControllerHarness(
            authorization: authorization,
            transport: transport
        )
        let failingBegin = Task<GooglePendingIdentity, Error> {
            try await harness.controller.begin(progress: { _ in })
        }
        await transport.waitUntilRevocationStarted()

        XCTAssertThrowsError(
            try harness.controller.saveClientConfiguration(Synthetic.replacementClientConfiguration)
        ) { error in
            XCTAssertEqual(error as? GoogleConnectionControllerError, .cleanupRequired)
            assertSecretCanariesAbsent(from: String(reflecting: error))
        }
        await assertControllerError(.cleanupRequired) {
            _ = try await harness.controller.begin(progress: { _ in })
        }
        await assertControllerError(.cleanupRequired) {
            _ = try await harness.controller.confirmPendingIdentity()
        }
        let disconnect = Task<Void, Error> {
            try await harness.controller.disconnect()
        }

        transport.releaseRevocation()
        await assertVoidControllerTaskError(.cleanupRequired, task: disconnect)
        await assertControllerTaskError(.providerUnavailable, task: failingBegin)
        XCTAssertEqual(authorization.authorizeCount, 1)
    }

    func testPendingCancellationCleanupFailureRemainsObservableUntilDisconnectRetrySucceeds() async throws {
        // Break caught: cancel discards failed cleanup and loses the credential needed by a later retry.
        let harness = ControllerHarness.success()
        _ = try await harness.controller.begin(progress: { _ in })
        harness.transport.failRevocation = true
        harness.credentials.failEveryDelete = true

        await harness.controller.cancelPendingConnection()

        XCTAssertThrowsError(try harness.controller.credentialPresence()) { error in
            XCTAssertEqual(error as? GoogleConnectionControllerError, .cleanupRequired)
            assertSecretCanariesAbsent(from: String(reflecting: error))
        }
        await assertControllerError(.cleanupRequired) {
            _ = try await harness.controller.confirmPendingIdentity()
        }

        harness.transport.failRevocation = false
        harness.credentials.failEveryDelete = false
        try await harness.controller.disconnect()

        XCTAssertEqual(harness.transport.revokeAttemptCount, 2)
        XCTAssertEqual(harness.credentials.deleteGrantCount, 1)
        XCTAssertEqual(harness.credentials.deleteAllCount, 1)
        XCTAssertEqual(try harness.controller.credentialPresence(), .none)
    }

    func testCredentialPresenceAndSaveMapStoreErrorsToFiniteCredentialUnavailable() throws {
        // Break caught: store implementation errors or dynamic details cross the controller boundary.
        for storeError in [GoogleOAuthCredentialStoreError.unavailable, .malformed] {
            let credentials = RecordingCredentialStore()
            let harness = ControllerHarness(credentials: credentials)
            credentials.failNextPresence(with: storeError)
            XCTAssertThrowsError(try harness.controller.credentialPresence()) { error in
                XCTAssertEqual(error as? GoogleConnectionControllerError, .credentialUnavailable)
                assertSecretCanariesAbsent(from: String(reflecting: error))
            }

            credentials.failNextClientStore(with: storeError)
            XCTAssertThrowsError(try harness.controller.saveClientConfiguration(Synthetic.clientConfiguration)) { error in
                XCTAssertEqual(error as? GoogleConnectionControllerError, .credentialUnavailable)
            }
        }
        try assertSaveClientConfigurationRepairsMalformedClientOnlyState()
    }

    func testSaveClientIdentifierAllowsOnlyNoneAndClientOnlyPresence() throws {
        // Break caught: replacement overwrites a connected or inconsistent credential state.
        let empty = RecordingCredentialStore()
        let emptyHarness = ControllerHarness(credentials: empty)
        try emptyHarness.controller.saveClientConfiguration(Synthetic.clientConfiguration)
        XCTAssertEqual(try emptyHarness.controller.credentialPresence(), .clientOnly)
        try emptyHarness.controller.saveClientConfiguration(Synthetic.replacementClientConfiguration)
        XCTAssertEqual(try emptyHarness.controller.credentialPresence(), .clientOnly)

        for presence in [GoogleCredentialPresence.complete, .inconsistent] {
            let credentials = RecordingCredentialStore(presence: presence)
            let harness = ControllerHarness(credentials: credentials)
            XCTAssertThrowsError(try harness.controller.saveClientConfiguration(Synthetic.replacementClientConfiguration)) {
                XCTAssertEqual($0 as? GoogleConnectionControllerError, .invalidConfiguration)
            }
            XCTAssertEqual(try credentials.presence(), presence)
        }
    }

    /// Regression: this destroyed Braxton's credentials in a live session.
    ///
    /// `disconnectForReconsent` read the client configuration with `try?`, so a failed Keychain
    /// read became nil, the disconnect deleted both items, and nothing was restored — leaving
    /// him disconnected AND having to fetch his client id and secret from the Google Cloud
    /// console again, after clicking a button labelled "Enable sending & scheduling".
    ///
    /// A read we cannot complete must abort the operation, never proceed into a delete.
    func testReconsentRefusesToDisconnectWhenTheClientConfigurationCannotBeRead() async throws {
        let credentials = RecordingCredentialStore(presence: .complete)
        credentials.failNextClientLoad(with: .malformed)
        let harness = ControllerHarness(credentials: credentials)

        do {
            try await harness.controller.disconnectForReconsent()
            XCTFail("must not disconnect when the client configuration cannot be read")
        } catch {
            XCTAssertEqual(error as? GoogleConnectionControllerError, .credentialUnavailable)
        }

        // The whole point: nothing was destroyed.
        XCTAssertEqual(try credentials.presence(), .complete)
        XCTAssertNotNil(try credentials.loadClientConfiguration())
    }

    /// The successful path must leave the connection ready to consent again — client
    /// configuration intact, grant gone.
    func testAbandonedConsentClearsTheGrantButNeverTheClientConfiguration() async throws {
        // Break caught: an abandoned, cancelled or timed-out consent deletes the user's OAuth
        // client id and secret along with the grant.
        //
        // This is not hypothetical. `begin` times out after `authorizationTimeout`, and Google's
        // unverified-app interstitial is easy to sit on for longer than that. Cleanup then ran
        // `deleteAll()`, so waiting too long at a consent screen wiped the client configuration
        // the user had typed in by hand, and the only way back was the Google Cloud console.
        // Cleanup owns the grant. It does not own the client configuration.
        let harness = ControllerHarness.failure(at: .authorizationCancel)

        do {
            _ = try await harness.controller.begin(progress: { _ in })
            XCTFail("Expected the abandoned consent to fail")
        } catch {
            XCTAssertNotNil(error as? GoogleConnectionControllerError)
        }

        XCTAssertNotNil(try harness.credentials.loadClientConfiguration())
        XCTAssertNil(try harness.credentials.loadRefreshToken())
        XCTAssertEqual(try harness.credentials.presence(), .clientOnly)
        XCTAssertEqual(harness.credentials.deleteGrantCount, 1)
        XCTAssertEqual(harness.credentials.deleteAllCount, 0)

        // The whole point: the user can consent again without re-entering anything. A second
        // attempt gets all the way to authorization — `.cancelled`, from this harness's always
        // -cancelling authorization — rather than being turned away as `.notConfigured`.
        await assertControllerError(.cancelled) {
            _ = try await harness.controller.begin(progress: { _ in })
        }
    }

    func testReconsentKeepsTheClientConfigurationAndClearsOnlyTheGrant() async throws {
        let credentials = RecordingCredentialStore(presence: .complete)
        let harness = ControllerHarness(credentials: credentials)

        try await harness.controller.disconnectForReconsent()

        XCTAssertEqual(
            try credentials.presence(), .clientOnly,
            "re-consent must leave exactly the state `begin` requires"
        )
        XCTAssertNotNil(try credentials.loadClientConfiguration())
    }

    private func assertSaveClientConfigurationRepairsMalformedClientOnlyState() throws {
        let credentials = RecordingCredentialStore()
        credentials.failNextPresence(with: .malformed)
        let harness = ControllerHarness(credentials: credentials)

        XCTAssertThrowsError(try harness.controller.credentialPresence()) { error in
            XCTAssertEqual(error as? GoogleConnectionControllerError, .credentialUnavailable)
        }
        try harness.controller.saveClientConfiguration(Synthetic.replacementClientConfiguration)

        XCTAssertEqual(try harness.controller.credentialPresence(), .clientOnly)
    }

    func testSavingClientIdentifierExcludesBeginUntilTheStoreMutationFinishes() async throws {
        // Break caught: begin reserves the controller while a client-ID replacement is still in flight.
        let credentials = RecordingCredentialStore(pauseClientStore: true)
        let harness = ControllerHarness(credentials: credentials)
        let save = Task<Void, Error> {
            try harness.controller.saveClientConfiguration(Synthetic.clientConfiguration)
        }
        await credentials.waitUntilClientStoreStarted()

        await assertControllerError(.invalidConfiguration) {
            _ = try await harness.controller.begin(progress: { _ in })
        }

        credentials.releaseClientStore()
        try await save.value
        XCTAssertEqual(try harness.controller.credentialPresence(), .clientOnly)
    }

    func testBeginRequiresExactlyClientOnlyCredentialPresence() async {
        // Break caught: begin starts authorization without a sole saved client identifier.
        for (presence, expected) in [
            (GoogleCredentialPresence.none, GoogleConnectionControllerError.notConfigured),
            (.complete, .invalidConfiguration),
            (.inconsistent, .invalidConfiguration),
        ] {
            let credentials = RecordingCredentialStore(presence: presence)
            let harness = ControllerHarness(credentials: credentials)

            await assertControllerError(expected) {
                _ = try await harness.controller.begin(progress: { _ in })
            }

            XCTAssertEqual(harness.authorization.authorizeCount, 0)
            XCTAssertEqual(try? credentials.presence(), presence)
        }
    }

    func testOverlappingBeginIsRejectedAndCancellationClearsTheFirstOperation() async {
        // Break caught: two begins share or overwrite in-flight secret state.
        let authorization = RecordingAuthorization(mode: .suspendUntilCancelled)
        let harness = ControllerHarness(authorization: authorization)
        let first = Task<GooglePendingIdentity, Error> {
            try await harness.controller.begin(progress: { _ in })
        }
        await authorization.waitUntilAuthorizeStarted()

        await assertControllerError(.invalidConfiguration) {
            _ = try await harness.controller.begin(progress: { _ in })
        }
        await harness.controller.cancelPendingConnection()
        await assertControllerTaskError(.cancelled, task: first)

        XCTAssertEqual(authorization.cancelCount, 1)
        XCTAssertEqual(try? harness.credentials.presence(), Optional(GoogleCredentialPresence.clientOnly))
        await assertControllerError(.notConfigured) {
            _ = try await harness.controller.confirmPendingIdentity()
        }
    }

    func testConfirmationRequiresOnePendingGrantExactlyOnce() async throws {
        // Break caught: confirmation succeeds without begin or reuses destroyed pending credentials.
        let harness = ControllerHarness.success()
        await assertControllerError(.notConfigured) {
            _ = try await harness.controller.confirmPendingIdentity()
        }

        _ = try await harness.controller.begin(progress: { _ in })
        _ = try await harness.controller.confirmPendingIdentity()

        await assertControllerError(.notConfigured) {
            _ = try await harness.controller.confirmPendingIdentity()
        }
    }

    func testCancelAndDisconnectWhilePendingRevokeDeleteAndDestroyConfirmation() async throws {
        // Break caught: either lifecycle path leaves a pending refresh credential confirmable.
        let cancelHarness = ControllerHarness.success()
        _ = try await cancelHarness.controller.begin(progress: { _ in })
        await cancelHarness.controller.cancelPendingConnection()
        XCTAssertEqual(try cancelHarness.credentials.presence(), .clientOnly)
        XCTAssertTrue(cancelHarness.transport.revocationAttemptedWhenCredentialExisted)
        await assertControllerError(.notConfigured) {
            _ = try await cancelHarness.controller.confirmPendingIdentity()
        }

        let disconnectHarness = ControllerHarness.success()
        _ = try await disconnectHarness.controller.begin(progress: { _ in })
        try await disconnectHarness.controller.disconnect()
        XCTAssertEqual(try disconnectHarness.credentials.presence(), .none)
        XCTAssertTrue(disconnectHarness.transport.revocationAttemptedWhenCredentialExisted)
        await assertControllerError(.notConfigured) {
            _ = try await disconnectHarness.controller.confirmPendingIdentity()
        }
    }

    func testDisconnectRevokesPersistedRefreshDeletesAllAndReportsPartialCleanup() async throws {
        // Break caught: disconnect ignores the persisted refresh or stops after one failed component.
        let connected = ControllerHarness.success()
        _ = try await connected.controller.begin(progress: { _ in })
        _ = try await connected.controller.confirmPendingIdentity()

        try await connected.controller.disconnect()

        XCTAssertEqual(connected.transport.revokeAttemptCount, 1)
        XCTAssertEqual(connected.credentials.deleteAllCount, 1)
        XCTAssertEqual(try connected.credentials.presence(), .none)

        let partial = ControllerHarness.success()
        _ = try await partial.controller.begin(progress: { _ in })
        _ = try await partial.controller.confirmPendingIdentity()
        partial.transport.failRevocation = true
        partial.credentials.failEveryDelete = true

        await assertControllerError(.cleanupRequired) {
            try await partial.controller.disconnect()
        }

        XCTAssertEqual(partial.transport.revokeAttemptCount, 1)
        XCTAssertEqual(partial.credentials.deleteAllCount, 1)
        XCTAssertEqual(try? partial.credentials.presence(), Optional(GoogleCredentialPresence.none))
    }
}

private enum ControllerFailurePoint: String, CaseIterable {
    case authorizationCancel
    case exchange
    case wrongGrantedScope
    case malformedIssuedToken
    case missingRefresh
    case refresh
    case refreshCancellation
    case gmailRead
    case calendarRead
    case tasksRead
    case malformedIdentity
    case credentialPresence
    case clientLoad
    case revokeCleanup
    case deleteCleanup

    var expectsRevocation: Bool {
        switch self {
        case .authorizationCancel, .exchange, .credentialPresence, .clientLoad:
            false
        default:
            true
        }
    }

    var hasIncompleteCleanup: Bool {
        self == .revokeCleanup || self == .deleteCleanup
    }
}

private enum ResponseFailure: String, CaseIterable {
    case exchangeNonSuccess
    case exchangeMalformed
    case refreshNonSuccess
    case refreshMalformed
    case gmailNonSuccess
    case gmailMalformed
    case calendarWrongKind
    case calendarMalformed
    case tasksWrongKind
    case tasksMalformed
}

private final class ControllerHarness: @unchecked Sendable {
    let authorization: RecordingAuthorization
    let credentials: RecordingCredentialStore
    let transport: RecordingControllerTransport
    let controller: GoogleReadOnlyConnectionController

    static func success(
        email: String = "owner@example.test",
        grantedScopes: [String] = ApprovedGoogleScopes.readOnly
    ) -> ControllerHarness {
        ControllerHarness(email: email, grantedScopes: grantedScopes)
    }

    static func failure(at point: ControllerFailurePoint) -> ControllerHarness {
        let authorization = RecordingAuthorization(
            mode: point == .authorizationCancel ? .fail(.cancelled) : .succeed
        )
        let credentials = RecordingCredentialStore(presence: .clientOnly)
        if point == .credentialPresence {
            credentials.failNextPresence(with: .unavailable)
        } else if point == .clientLoad {
            credentials.failNextClientLoad(with: .malformed)
        } else if point == .deleteCleanup {
            credentials.failEveryDelete = true
        }
        let transport = RecordingControllerTransport(failurePoint: point)
        return ControllerHarness(
            authorization: authorization,
            credentials: credentials,
            transport: transport
        )
    }

    static func responseFailure(_ failure: ResponseFailure) -> ControllerHarness {
        ControllerHarness(transport: RecordingControllerTransport(responseFailure: failure))
    }

    init(
        email: String = "owner@example.test",
        grantedScopes: [String] = ApprovedGoogleScopes.readOnly,
        authorization: RecordingAuthorization = RecordingAuthorization(),
        credentials: RecordingCredentialStore = RecordingCredentialStore(presence: .clientOnly),
        transport: RecordingControllerTransport? = nil
    ) {
        let transport = transport ?? RecordingControllerTransport(
            email: email,
            grantedScopes: grantedScopes
        )
        self.authorization = authorization
        self.credentials = credentials
        self.transport = transport
        controller = GoogleReadOnlyConnectionController(
            authorization: authorization,
            credentials: credentials,
            transport: transport,
            authorizationTimeout: Duration.seconds(1)
        )
    }
}

private enum Synthetic {
    static let clientIdentifier = "planner-client.apps.example.test"
    static let replacementClientIdentifier = "replacement-client.apps.example.test"
    static let clientSecret = "desktop-client-secret-canary"
    static let replacementClientSecret = "replacement-secret-canary"
    static let authorizationCode = "authorization-code-canary"
    static let verifier = String(repeating: "v", count: 48)
    static let initialAccessToken = "initial-access-token-canary"
    static let refreshToken = "refresh-token-canary"
    static let refreshedAccessToken = "refreshed-access-token-canary"
    static let redirectURL = "http://127.0.0.1:43117/oauth/callback"
    static let dynamicResponseCanary = "dynamic-response-body-canary"
    static let fullURLCanary = "https://secrets.example.test/private?token=url-canary"
    static let clientConfiguration = try! GoogleOAuthClientConfiguration(
        clientIdentifier: clientIdentifier,
        clientSecret: clientSecret
    )
    static let replacementClientConfiguration = try! GoogleOAuthClientConfiguration(
        clientIdentifier: replacementClientIdentifier,
        clientSecret: replacementClientSecret
    )

    static let secretCanaries = [
        clientIdentifier,
        replacementClientIdentifier,
        clientSecret,
        replacementClientSecret,
        authorizationCode,
        verifier,
        initialAccessToken,
        refreshToken,
        refreshedAccessToken,
        redirectURL,
        dynamicResponseCanary,
        fullURLCanary,
    ]
}

private final class RecordingAuthorization: GoogleAuthorizationAuthorizing, @unchecked Sendable {
    enum Mode: Sendable {
        case succeed
        case succeedOnceThenCancel
        case fail(GoogleAuthorizationSessionError)
        case suspendUntilCancelled
    }

    private struct State {
        var authorizeCount = 0
        /// Which scope set each consent screen asked for.
        var requestedCapabilities: [GoogleGrantedCapability] = []
        var cancelCount = 0
        var awaitingConsentCallbackCount = 0
        var receivedExpectedClientIdentifier = true
        var authorizationURLWasSecretFree = true
        var continuation: CheckedContinuation<GoogleAuthorizationGrant, Error>?
    }

    private let lock = NSLock()
    private var state = State()
    private let mode: Mode

    init(mode: Mode = .succeed) {
        self.mode = mode
    }

    var authorizeCount: Int { locked { $0.authorizeCount } }
    var cancelCount: Int { locked { $0.cancelCount } }
    var awaitingConsentCallbackCount: Int { locked { $0.awaitingConsentCallbackCount } }
    var receivedExpectedClientIdentifier: Bool { locked { $0.receivedExpectedClientIdentifier } }
    var authorizationURLWasSecretFree: Bool { locked { $0.authorizationURLWasSecretFree } }

    func authorize(
        clientIdentifier: String,
        timeout: Duration,
        capability: GoogleGrantedCapability,
        onAwaitingConsent: @escaping @Sendable () async -> Void
    ) async throws -> GoogleAuthorizationGrant {
        locked { $0.requestedCapabilities.append(capability) }
        let attempt = locked { state -> Int in
            state.authorizeCount += 1
            state.receivedExpectedClientIdentifier =
                state.receivedExpectedClientIdentifier && clientIdentifier == Synthetic.clientIdentifier
            return state.authorizeCount
        }

        switch mode {
        case .succeed:
            await onAwaitingConsent()
            locked { $0.awaitingConsentCallbackCount += 1 }
            return try makeGrant()
        case .succeedOnceThenCancel:
            guard attempt == 1 else {
                throw GoogleAuthorizationSessionError.cancelled
            }
            await onAwaitingConsent()
            locked { $0.awaitingConsentCallbackCount += 1 }
            return try makeGrant()
        case .fail(let error):
            throw error
        case .suspendUntilCancelled:
            return try await withCheckedThrowingContinuation { continuation in
                locked { $0.continuation = continuation }
            }
        }
    }

    func cancel() {
        let continuation = locked { state -> CheckedContinuation<GoogleAuthorizationGrant, Error>? in
            state.cancelCount += 1
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(throwing: GoogleAuthorizationSessionError.cancelled)
    }

    func waitUntilAuthorizeStarted() async {
        await waitUntil { self.authorizeCount == 1 }
    }

    private func makeGrant() throws -> GoogleAuthorizationGrant {
        let request = try GoogleOAuthRequest(
            clientIdentifier: Synthetic.clientIdentifier,
            redirectPort: 43_117,
            pkce: PKCEPair(
                verifier: Synthetic.verifier,
                challenge: PKCEPair.challenge(for: Synthetic.verifier)
            ),
            state: String(repeating: "s", count: 43)
        )
        locked {
            $0.authorizationURLWasSecretFree = $0.authorizationURLWasSecretFree
                && !request.authorizationURL.absoluteString.contains(Synthetic.clientSecret)
        }
        return GoogleAuthorizationGrant(
            authorizationCode: Synthetic.authorizationCode,
            request: request
        )
    }

    @discardableResult
    private func locked<T>(_ body: (inout State) -> T) -> T {
        lock.withLock { body(&state) }
    }
}

private final class RecordingCredentialStore: GoogleOAuthCredentialStoring, @unchecked Sendable {
    private struct State {
        var clientConfiguration: GoogleOAuthClientConfiguration?
        var refreshToken: String?
        var presenceError: GoogleOAuthCredentialStoreError?
        var clientLoadError: GoogleOAuthCredentialStoreError?
        var clientStoreError: GoogleOAuthCredentialStoreError?
        var refreshStoreError: GoogleOAuthCredentialStoreError?
        var refreshStoreCount = 0
        var failEveryDelete = false
        var deleteAllCount = 0
        var deleteGrantCount = 0
    }

    private let lock = NSLock()
    private var state: State
    private let clientStoreGate: BlockingGate?
    private let refreshStoreGate: BlockingGate?

    init(
        presence: GoogleCredentialPresence = .none,
        pauseClientStore: Bool = false,
        pauseRefreshStore: Bool = false
    ) {
        state = switch presence {
        case .none:
            State()
        case .clientOnly:
            State(clientConfiguration: Synthetic.clientConfiguration)
        case .complete:
            State(
                clientConfiguration: Synthetic.clientConfiguration,
                refreshToken: Synthetic.refreshToken
            )
        case .inconsistent:
            State(refreshToken: Synthetic.refreshToken)
        }
        clientStoreGate = pauseClientStore ? BlockingGate() : nil
        refreshStoreGate = pauseRefreshStore ? BlockingGate() : nil
    }

    var deleteAllCount: Int { locked { $0.deleteAllCount } }
    var deleteGrantCount: Int { locked { $0.deleteGrantCount } }
    var refreshStoreCount: Int { locked { $0.refreshStoreCount } }
    var failEveryDelete: Bool {
        get { locked { $0.failEveryDelete } }
        set { locked { $0.failEveryDelete = newValue } }
    }

    func failNextPresence(with error: GoogleOAuthCredentialStoreError) {
        locked { $0.presenceError = error }
    }

    func failNextClientLoad(with error: GoogleOAuthCredentialStoreError) {
        locked { $0.clientLoadError = error }
    }

    func failNextClientStore(with error: GoogleOAuthCredentialStoreError) {
        locked { $0.clientStoreError = error }
    }

    func failNextRefreshStore(with error: GoogleOAuthCredentialStoreError) {
        locked { $0.refreshStoreError = error }
    }

    func storeClientConfiguration(_ value: GoogleOAuthClientConfiguration) throws {
        clientStoreGate?.pause()
        try locked { state in
            if let error = state.clientStoreError {
                state.clientStoreError = nil
                throw error
            }
            state.clientConfiguration = value
        }
    }

    func loadClientConfiguration() throws -> GoogleOAuthClientConfiguration? {
        try locked { state in
            if let error = state.clientLoadError {
                state.clientLoadError = nil
                throw error
            }
            return state.clientConfiguration
        }
    }

    func storeRefreshToken(_ value: String) throws {
        refreshStoreGate?.pause()
        try locked { state in
            state.refreshStoreCount += 1
            if let error = state.refreshStoreError {
                state.refreshStoreError = nil
                throw error
            }
            state.refreshToken = value
        }
    }

    func loadRefreshToken() throws -> String? {
        locked { $0.refreshToken }
    }

    func deleteAll() throws {
        try locked { state in
            state.deleteAllCount += 1
            state.clientConfiguration = nil
            state.refreshToken = nil
            if state.failEveryDelete {
                throw GoogleOAuthCredentialStoreError.unavailable
            }
        }
    }

    func deleteGrant() throws {
        try locked { state in
            state.deleteGrantCount += 1
            state.refreshToken = nil
            if state.failEveryDelete {
                throw GoogleOAuthCredentialStoreError.unavailable
            }
        }
    }

    func presence() throws -> GoogleCredentialPresence {
        try locked { state in
            if let error = state.presenceError {
                state.presenceError = nil
                throw error
            }
            return switch (state.clientConfiguration != nil, state.refreshToken != nil) {
            case (false, false): .none
            case (true, false): .clientOnly
            case (true, true): .complete
            case (false, true): .inconsistent
            }
        }
    }

    func waitUntilClientStoreStarted() async {
        await clientStoreGate?.waitUntilEntered()
    }

    func releaseClientStore() {
        clientStoreGate?.release()
    }

    func waitUntilRefreshStoreStarted() async {
        await refreshStoreGate?.waitUntilEntered()
    }

    func releaseRefreshStore() {
        refreshStoreGate?.release()
    }

    @discardableResult
    private func locked<T>(_ body: (inout State) throws -> T) rethrows -> T {
        try lock.withLock { try body(&state) }
    }
}

private final class BlockingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    func pause() {
        condition.lock()
        entered = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilEntered() async {
        await waitUntil {
            self.condition.lock()
            defer { self.condition.unlock() }
            return self.entered
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class RecordingControllerTransport: GoogleHTTPTransport, @unchecked Sendable {
    private struct State {
        var recordedMethodsAndPaths: [String] = []
        var exchangeFormWasExact = true
        var refreshFormWasExact = true
        var providerAuthorizationWasBearerOnly = true
        var clientSecretWasAbsentFromNonTokenRequests = true
        var revokeAttemptCount = 0
        var failRevocation = false
        var lastRevokedCredentialKind: RevokedCredentialKind?
    }

    private let lock = NSLock()
    private var state = State()
    private let email: String
    private let grantedScopes: [String]
    private let failurePoint: ControllerFailurePoint?
    private let responseFailure: ResponseFailure?
    private let exchangeResponseGate: SuspensionGate?
    private let revocationGate: SuspensionGate?

    init(
        email: String = "owner@example.test",
        grantedScopes: [String] = ApprovedGoogleScopes.readOnly,
        failurePoint: ControllerFailurePoint? = nil,
        responseFailure: ResponseFailure? = nil,
        pauseExchangeResponse: Bool = false,
        pauseRevocation: Bool = false
    ) {
        self.email = email
        self.grantedScopes = grantedScopes
        self.failurePoint = failurePoint
        self.responseFailure = responseFailure
        exchangeResponseGate = pauseExchangeResponse ? SuspensionGate() : nil
        revocationGate = pauseRevocation ? SuspensionGate() : nil
    }

    var recordedMethodsAndPaths: [String] { locked { $0.recordedMethodsAndPaths } }
    var exchangeFormWasExact: Bool { locked { $0.exchangeFormWasExact } }
    var refreshFormWasExact: Bool { locked { $0.refreshFormWasExact } }
    var providerAuthorizationWasBearerOnly: Bool { locked { $0.providerAuthorizationWasBearerOnly } }
    var clientSecretWasAbsentFromNonTokenRequests: Bool {
        locked { $0.clientSecretWasAbsentFromNonTokenRequests }
    }
    var revokeAttemptCount: Int { locked { $0.revokeAttemptCount } }
    var lastRevokedCredentialKind: RevokedCredentialKind? {
        locked { $0.lastRevokedCredentialKind }
    }
    var failRevocation: Bool {
        get { locked { $0.failRevocation } }
        set { locked { $0.failRevocation = newValue } }
    }
    var revocationAttemptedWhenCredentialExisted: Bool {
        guard failurePoint?.expectsRevocation != false else { return true }
        return revokeAttemptCount > 0
    }

    func send(_ request: URLRequest) async throws -> GoogleHTTPResponse {
        try GoogleNetworkPolicy.validate(request)
        let method = request.httpMethod ?? ""
        let path = request.url?.path ?? ""
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let nonTokenRequestText = [
            request.url?.absoluteString ?? "",
            request.allHTTPHeaderFields?.values.joined(separator: " ") ?? "",
            body,
        ].joined(separator: " ")
        locked {
            $0.recordedMethodsAndPaths.append("\(method) \(path)")
            if path != "/token" {
                $0.clientSecretWasAbsentFromNonTokenRequests =
                    $0.clientSecretWasAbsentFromNonTokenRequests
                    && !nonTokenRequestText.contains(Synthetic.clientSecret)
            }
        }

        switch (method, path) {
        case ("POST", "/token"):
            let tokenCallCount = recordedMethodsAndPaths.filter { $0 == "POST /token" }.count
            let response = try tokenCallCount == 1 ? exchange(request) : refresh(request)
            if tokenCallCount == 1, let exchangeResponseGate {
                await exchangeResponseGate.suspend()
            }
            return response
        case ("POST", "/revoke"):
            let response = revoke(request)
            if let revocationGate {
                await revocationGate.suspend()
            }
            return response
        case ("GET", "/gmail/v1/users/me/profile"):
            validateProviderAuthorization(request)
            return gmail()
        case ("GET", "/calendar/v3/users/me/calendarList"):
            validateProviderAuthorization(request)
            return calendar()
        case ("GET", "/tasks/v1/users/@me/lists"):
            validateProviderAuthorization(request)
            return tasks()
        default:
            throw GoogleHTTPTransportError.requestFailed
        }
    }

    private func exchange(_ request: URLRequest) throws -> GoogleHTTPResponse {
        let exact = formFields(request) == [
            "client_id": Synthetic.clientIdentifier,
            "client_secret": Synthetic.clientSecret,
            "code": Synthetic.authorizationCode,
            "code_verifier": Synthetic.verifier,
            "grant_type": "authorization_code",
            "redirect_uri": Synthetic.redirectURL,
        ] && hasOnlyFormContentType(request)
        locked { $0.exchangeFormWasExact = $0.exchangeFormWasExact && exact }

        if failurePoint == .exchange { throw GoogleHTTPTransportError.requestFailed }
        if responseFailure == .exchangeNonSuccess { return dynamicFailureResponse() }
        if responseFailure == .exchangeMalformed { return .init(statusCode: 200, data: Data("{".utf8)) }

        var object: [String: Any] = [
            "access_token": Synthetic.initialAccessToken,
            "expires_in": 3_599,
            "scope": grantedScopes.joined(separator: " "),
            "token_type": "Bearer",
        ]
        if failurePoint != .missingRefresh {
            object["refresh_token"] = Synthetic.refreshToken
        }
        if failurePoint == .wrongGrantedScope {
            object["scope"] = ApprovedGoogleScopes.readOnly.dropLast().joined(separator: " ")
        }
        if failurePoint == .malformedIssuedToken {
            object["token_type"] = "Unsupported"
        }
        return jsonResponse(object)
    }

    private func refresh(_ request: URLRequest) throws -> GoogleHTTPResponse {
        let exact = formFields(request) == [
            "client_id": Synthetic.clientIdentifier,
            "client_secret": Synthetic.clientSecret,
            "grant_type": "refresh_token",
            "refresh_token": Synthetic.refreshToken,
        ] && hasOnlyFormContentType(request)
        locked { $0.refreshFormWasExact = $0.refreshFormWasExact && exact }

        if failurePoint == .refresh { throw GoogleHTTPTransportError.requestFailed }
        if failurePoint == .refreshCancellation { throw GoogleHTTPTransportError.cancelled }
        if responseFailure == .refreshNonSuccess { return dynamicFailureResponse() }
        if responseFailure == .refreshMalformed { return .init(statusCode: 200, data: Data("[]".utf8)) }
        return jsonResponse([
            "access_token": Synthetic.refreshedAccessToken,
            "expires_in": 3_599,
            "scope": ApprovedGoogleScopes.readOnly.joined(separator: " "),
            "token_type": "Bearer",
        ])
    }

    private func gmail() -> GoogleHTTPResponse {
        if failurePoint == .gmailRead || failurePoint == .revokeCleanup || failurePoint == .deleteCleanup {
            return dynamicFailureResponse()
        }
        if responseFailure == .gmailNonSuccess { return dynamicFailureResponse() }
        if responseFailure == .gmailMalformed { return .init(statusCode: 200, data: Data("null".utf8)) }
        let profileEmail = failurePoint == .malformedIdentity ? "not-an-email" : email
        return jsonResponse([
            "emailAddress": profileEmail,
            "messagesTotal": 17,
            "threadsTotal": 9,
            "historyId": "123456789",
        ])
    }

    private func calendar() -> GoogleHTTPResponse {
        if failurePoint == .calendarRead { return dynamicFailureResponse() }
        if responseFailure == .calendarMalformed { return .init(statusCode: 200, data: Data("{".utf8)) }
        let kind = responseFailure == .calendarWrongKind ? "calendar#event" : "calendar#calendarList"
        return jsonResponse([
            "kind": kind,
            "etag": "synthetic-calendar-etag",
            "nextPageToken": "synthetic-next-page",
            "items": [[
                "kind": "calendar#calendarListEntry",
                "etag": "synthetic-entry-etag",
                "id": "calendar-id.example.test",
                "summary": "Synthetic Calendar",
                "description": "Synthetic description",
                "location": "Synthetic location",
                "timeZone": "America/Vancouver",
                "colorId": "1",
                "backgroundColor": "#000000",
                "foregroundColor": "#ffffff",
                "selected": true,
                "accessRole": "reader",
                "primary": true,
                "deleted": false,
                "conferenceProperties": ["allowedConferenceSolutionTypes": [String]()],
            ]],
        ])
    }

    private func tasks() -> GoogleHTTPResponse {
        if failurePoint == .tasksRead { return dynamicFailureResponse() }
        if responseFailure == .tasksMalformed { return .init(statusCode: 200, data: Data("[]".utf8)) }
        let kind = responseFailure == .tasksWrongKind ? "tasks#task" : "tasks#taskLists"
        return jsonResponse([
            "kind": kind,
            "etag": "synthetic-tasks-etag",
            "nextPageToken": "synthetic-next-page",
            "items": [[
                "kind": "tasks#taskList",
                "id": "task-list-id.example.test",
                "etag": "synthetic-list-etag",
                "title": "Synthetic Tasks",
                "updated": "2026-08-30T12:00:00.000Z",
                "selfLink": "https://tasks.googleapis.com/tasks/v1/users/@me/lists/synthetic",
            ]],
        ])
    }

    private func revoke(_ request: URLRequest) -> GoogleHTTPResponse {
        let fields = formFields(request) ?? [:]
        let credentialKind = RevokedCredentialKind(token: fields["token"])
        let tokenIsKnown = fields.count == 1 && credentialKind != nil
        let exact = tokenIsKnown && hasOnlyFormContentType(request)
        locked {
            $0.revokeAttemptCount += 1
            $0.lastRevokedCredentialKind = credentialKind
            $0.exchangeFormWasExact = $0.exchangeFormWasExact && exact
        }
        if failurePoint == .revokeCleanup || failRevocation {
            return dynamicFailureResponse()
        }
        return .init(statusCode: 200, data: Data())
    }

    private func validateProviderAuthorization(_ request: URLRequest) {
        let headers = request.allHTTPHeaderFields ?? [:]
        let exact = headers.count == 1
            && headers["Authorization"] == "Bearer \(Synthetic.refreshedAccessToken)"
            && request.url?.query?.contains("access_token") != true
        locked { $0.providerAuthorizationWasBearerOnly = $0.providerAuthorizationWasBearerOnly && exact }
    }

    private func formFields(_ request: URLRequest) -> [String: String]? {
        guard let data = request.httpBody,
              let body = String(data: data, encoding: .utf8),
              let items = URLComponents(string: "?\(body)")?.queryItems else { return nil }
        var result: [String: String] = [:]
        for item in items {
            guard let value = item.value, result[item.name] == nil else { return nil }
            result[item.name] = value
        }
        return result
    }

    private func hasOnlyFormContentType(_ request: URLRequest) -> Bool {
        let headers = request.allHTTPHeaderFields ?? [:]
        return headers.count == 1 && headers["Content-Type"] == "application/x-www-form-urlencoded"
    }

    private func dynamicFailureResponse() -> GoogleHTTPResponse {
        jsonResponse(
            [
                "error": Synthetic.dynamicResponseCanary,
                "url": Synthetic.fullURLCanary,
            ],
            statusCode: 503
        )
    }

    private func jsonResponse(_ object: Any, statusCode: Int = 200) -> GoogleHTTPResponse {
        .init(statusCode: statusCode, data: try! JSONSerialization.data(withJSONObject: object))
    }

    @discardableResult
    private func locked<T>(_ body: (inout State) -> T) -> T {
        lock.withLock { body(&state) }
    }

    func waitUntilExchangeResponseReady() async {
        await exchangeResponseGate?.waitUntilEntered()
    }

    func releaseExchangeResponse() {
        exchangeResponseGate?.release()
    }

    func waitUntilRevocationStarted() async {
        await revocationGate?.waitUntilEntered()
    }

    func releaseRevocation() {
        revocationGate?.release()
    }
}

private enum RevokedCredentialKind: Equatable, Sendable {
    case initialAccess
    case refresh
    case refreshedAccess

    init?(token: String?) {
        switch token {
        case Synthetic.initialAccessToken: self = .initialAccess
        case Synthetic.refreshToken: self = .refresh
        case Synthetic.refreshedAccessToken: self = .refreshedAccess
        default: return nil
        }
    }
}

private final class SuspensionGate: @unchecked Sendable {
    private struct State {
        var entered = false
        var released = false
        var continuations: [CheckedContinuation<Void, Never>] = []
    }

    private let lock = NSLock()
    private var state = State()

    func suspend() async {
        await withCheckedContinuation { continuation in
            let releaseNow = lock.withLock { () -> Bool in
                state.entered = true
                guard !state.released else { return true }
                state.continuations.append(continuation)
                return false
            }
            if releaseNow { continuation.resume() }
        }
    }

    func waitUntilEntered() async {
        await waitUntil { self.lock.withLock { self.state.entered } }
    }

    func release() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            state.released = true
            defer { state.continuations.removeAll() }
            return state.continuations
        }
        continuations.forEach { $0.resume() }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [GoogleConnectionProgress] = []

    var values: [GoogleConnectionProgress] { lock.withLock { recorded } }

    func append(_ value: GoogleConnectionProgress) {
        lock.withLock { recorded.append(value) }
    }
}

private func assertControllerError(
    _ expected: GoogleConnectionControllerError,
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected finite controller error", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? GoogleConnectionControllerError, expected, file: file, line: line)
        assertSecretCanariesAbsent(from: String(reflecting: error), file: file, line: line)
    }
}

private func assertControllerTaskError<Success>(
    _ expected: GoogleConnectionControllerError,
    task: Task<Success, Error>,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await task.value
        XCTFail("Expected finite controller error", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? GoogleConnectionControllerError, expected, file: file, line: line)
        assertSecretCanariesAbsent(from: String(reflecting: error), file: file, line: line)
    }
}

private func assertVoidControllerTaskError(
    _ expected: GoogleConnectionControllerError,
    task: Task<Void, Error>,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await task.value
        XCTFail("Expected finite controller error", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? GoogleConnectionControllerError, expected, file: file, line: line)
        assertSecretCanariesAbsent(from: String(reflecting: error), file: file, line: line)
    }
}

private func assertSecretCanariesAbsent(
    from value: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    for canary in Synthetic.secretCanaries {
        XCTAssertFalse(value.contains(canary), file: file, line: line)
    }
}

private func waitUntil(
    _ predicate: @escaping @Sendable () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while !predicate(), clock.now < deadline {
        await Task.yield()
    }
    XCTAssertTrue(predicate(), "Condition was not met before deadline", file: file, line: line)
}
