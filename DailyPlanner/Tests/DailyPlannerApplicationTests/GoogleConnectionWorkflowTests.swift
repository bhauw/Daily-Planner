import XCTest
import DailyPlannerDomain
@testable import DailyPlannerApplication

final class GoogleConnectionWorkflowTests: XCTestCase {
    func testNoCredentialsLoadsNotConfiguredAndDoesNotStartConnection() async {
        let harness = ConnectionWorkflowHarness(presence: .none)

        let state = await harness.workflow.loadState()

        XCTAssertEqual(state, .notConfigured)
        XCTAssertEqual(harness.controller.beginCount, 0)
        XCTAssertEqual(harness.controller.confirmCount, 0)
        XCTAssertEqual(harness.controller.cancelCount, 0)
        XCTAssertEqual(harness.controller.disconnectCount, 0)
        XCTAssertEqual(harness.recorder.recordedCalls, [
            "controller.credentialPresence",
            "settings.load",
        ])
    }

    func testLoadStateMapsCompleteConsistentCredentialsToConnectedReadOnly() async {
        let harness = ConnectionWorkflowHarness(
            presence: .complete,
            binding: "Owner@Example.Test"
        )

        let state = await harness.workflow.loadState()

        XCTAssertEqual(state, .connected(displayEmail: "owner@example.test", capability: .readOnly))
        XCTAssertEqual(harness.controller.beginCount, 0)
    }

    func testLoadStateMapsClientOnlyCredentialsToReadyToConnect() async {
        let harness = ConnectionWorkflowHarness(presence: .clientOnly)

        let state = await harness.workflow.loadState()

        XCTAssertEqual(state, .readyToConnect)
    }

    func testLoadStateFailsClosedForEveryIncompletePersistentCombination() async {
        let cases: [(GoogleCredentialPresence, String?)] = [
            (.none, "owner@example.test"),
            (.clientOnly, "owner@example.test"),
            (.complete, nil),
            (.inconsistent, nil),
            (.inconsistent, "owner@example.test"),
        ]

        for (presence, binding) in cases {
            let harness = ConnectionWorkflowHarness(presence: presence, binding: binding)
            let state = await harness.workflow.loadState()
            XCTAssertEqual(state, .cleanupRequired)
        }
    }

    func testLoadStateMapsSettingsReadFailureToCredentialUnavailable() async {
        let harness = ConnectionWorkflowHarness(presence: .clientOnly, settingsMode: .failLoad)

        let state = await harness.workflow.loadState()

        XCTAssertEqual(state, .credentialUnavailable)
        XCTAssertEqual(harness.controller.beginCount, 0)
    }

    func testControllerErrorsMapOneToOneToFiniteWorkflowStates() async {
        let cases: [(GoogleConnectionControllerError, GoogleConnectionWorkflowState)] = [
            (.notConfigured, .notConfigured),
            (.invalidConfiguration, .cleanupRequired),
            (.cancelled, .cancelled),
            (.offline, .offline),
            (.scopeMismatch, .scopeMismatch),
            (.identityMismatch, .identityMismatch),
            (.credentialUnavailable, .credentialUnavailable),
            (.providerUnavailable, .providerUnavailable),
            (.cleanupRequired, .cleanupRequired),
        ]

        for (error, expectedState) in cases {
            let loadHarness = ConnectionWorkflowHarness(
                presence: .clientOnly,
                controllerFailures: [.credentialPresence: error]
            )
            let loadState = await loadHarness.workflow.loadState()
            XCTAssertEqual(loadState, expectedState)

            let saveHarness = ConnectionWorkflowHarness(
                presence: .none,
                controllerFailures: [.saveClientConfiguration: error]
            )
            let saveState = await saveHarness.workflow.saveClientConfiguration(
                clientIdentifier: "synthetic-client-id",
                clientSecret: "synthetic-client-secret"
            )
            XCTAssertEqual(saveState, expectedState)

            let beginHarness = ConnectionWorkflowHarness(
                presence: .clientOnly,
                controllerFailures: [.begin: error]
            )
            let beginState = await beginHarness.workflow.begin(progress: { _ in })
            XCTAssertEqual(beginState, expectedState)

            let confirmHarness = ConnectionWorkflowHarness(
                presence: .clientOnly,
                controllerFailures: [.confirm: error]
            )
            _ = await confirmHarness.workflow.begin(progress: { _ in })
            let confirmState = await confirmHarness.workflow.confirm()
            XCTAssertEqual(confirmState, expectedState)
            XCTAssertEqual(confirmHarness.store.replaceCount, 0)
        }
    }

    func testSaveClientConfigurationReturnsReadyWithoutReadingSettings() async {
        let harness = ConnectionWorkflowHarness(presence: .none)

        let state = await harness.workflow.saveClientConfiguration(
            clientIdentifier: "synthetic-client-id",
            clientSecret: "synthetic-client-secret"
        )

        XCTAssertEqual(state, .readyToConnect)
        XCTAssertEqual(harness.controller.saveCount, 1)
        XCTAssertEqual(harness.store.loadCount, 0)
        XCTAssertEqual(harness.recorder.recordedCalls, ["controller.saveClientConfiguration"])
        await assertSaveClientConfigurationRejectsMissingOrInvalidSecret()
    }

    private func assertSaveClientConfigurationRejectsMissingOrInvalidSecret() async {
        for secret in ["", "contains\ncontrol", String(repeating: "s", count: 4_097)] {
            let harness = ConnectionWorkflowHarness(presence: .none)

            let state = await harness.workflow.saveClientConfiguration(
                clientIdentifier: "synthetic-client-id",
                clientSecret: secret
            )

            XCTAssertEqual(state, .cleanupRequired)
            XCTAssertEqual(harness.controller.saveCount, 0)
        }
    }

    func testBeginRequiresSavedClientIdentifierAndReturnsConfirmIdentity() async {
        let harness = ConnectionWorkflowHarness(
            presence: .clientOnly,
            pending: "owner@example.test"
        )
        let progress = WorkflowProgressRecorder()

        let state = await harness.workflow.begin { await progress.append($0) }
        let recordedProgress = await progress.recordedStates

        XCTAssertEqual(state, .confirmIdentity(displayEmail: "owner@example.test"))
        XCTAssertEqual(recordedProgress, [.connecting, .awaitingConsent])
        XCTAssertNil(harness.store.lastReplacement?.googleAccountBinding)
        XCTAssertEqual(harness.recorder.recordedCalls, [
            "settings.load",
            "controller.credentialPresence",
            "controller.begin",
        ])
    }

    func testBeginSettingsReadFailurePreventsControllerAccess() async {
        let harness = ConnectionWorkflowHarness(presence: .clientOnly, settingsMode: .failLoad)

        let state = await harness.workflow.begin(progress: { _ in })

        XCTAssertEqual(state, .credentialUnavailable)
        XCTAssertEqual(harness.controller.credentialPresenceCount, 0)
        XCTAssertEqual(harness.controller.beginCount, 0)
        XCTAssertEqual(harness.recorder.recordedCalls, ["settings.load"])
    }

    func testBeginRefusesCredentialPresenceThatCannotStartConnection() async {
        let cases: [(GoogleCredentialPresence, String?, GoogleConnectionWorkflowState)] = [
            (.none, nil, .notConfigured),
            (.none, "owner@example.test", .cleanupRequired),
            (.complete, nil, .cleanupRequired),
            (.complete, "owner@example.test", .connected(displayEmail: "owner@example.test", capability: .readOnly)),
            (.inconsistent, nil, .cleanupRequired),
        ]

        for (presence, binding, expectedState) in cases {
            let harness = ConnectionWorkflowHarness(presence: presence, binding: binding)
            let state = await harness.workflow.begin(progress: { _ in })
            XCTAssertEqual(state, expectedState)
            XCTAssertEqual(harness.controller.beginCount, 0)
        }
    }

    func testBeginCancelsPendingGrantWhenExistingBindingDiffers() async {
        let harness = ConnectionWorkflowHarness(
            presence: .clientOnly,
            pending: "new-owner@example.test",
            binding: "original-owner@example.test"
        )

        let state = await harness.workflow.begin(progress: { _ in })
        let laterConfirmation = await harness.workflow.confirm()

        XCTAssertEqual(state, .identityMismatch)
        XCTAssertEqual(laterConfirmation, .cleanupRequired)
        XCTAssertEqual(harness.controller.cancelCount, 1)
        XCTAssertEqual(harness.controller.confirmCount, 0)
        XCTAssertEqual(harness.store.replaceCount, 0)
        XCTAssertEqual(harness.recorder.recordedCalls, [
            "settings.load",
            "controller.credentialPresence",
            "controller.begin",
            "controller.cancel",
        ])
    }

    func testConfirmPersistsBindingOnlyAfterControllerConfirmation() async {
        let harness = ConnectionWorkflowHarness(
            presence: .clientOnly,
            pending: "Owner@Example.Test"
        )
        _ = await harness.workflow.begin(progress: { _ in })

        let state = await harness.workflow.confirm()

        XCTAssertEqual(state, .connected(displayEmail: "Owner@Example.Test", capability: .readOnly))
        XCTAssertEqual(
            harness.store.lastReplacement?.googleAccountBinding?.normalizedEmail,
            "owner@example.test"
        )
        XCTAssertEqual(harness.recorder.recordedCalls, [
            "settings.load",
            "controller.credentialPresence",
            "controller.begin",
            "controller.confirm",
            "settings.load",
            "settings.replace",
        ])
        assertNonGoogleSettingsPreserved(harness)
    }

    func testConfirmRequiresExactlyOneWorkflowOwnedPendingIdentity() async {
        let harness = ConnectionWorkflowHarness(presence: .clientOnly)

        let first = await harness.workflow.confirm()
        _ = await harness.workflow.begin(progress: { _ in })
        let connected = await harness.workflow.confirm()
        let second = await harness.workflow.confirm()

        XCTAssertEqual(first, .cleanupRequired)
        XCTAssertEqual(connected, .connected(displayEmail: "owner@example.test", capability: .readOnly))
        XCTAssertEqual(second, .cleanupRequired)
        XCTAssertEqual(harness.controller.confirmCount, 1)
    }

    func testConfirmReceiptMismatchRollsBackWithoutPersisting() async {
        let harness = ConnectionWorkflowHarness(
            presence: .clientOnly,
            pending: "owner@example.test",
            receiptBinding: "different@example.test"
        )
        _ = await harness.workflow.begin(progress: { _ in })

        let state = await harness.workflow.confirm()

        XCTAssertEqual(state, .cleanupRequired)
        XCTAssertEqual(harness.controller.disconnectCount, 1)
        XCTAssertEqual(harness.store.replaceCount, 0)
        XCTAssertNil(harness.store.storedSettings.googleAccountBinding)
    }

    func testSettingsFailureAfterCredentialConfirmationRollsBackController() async {
        let harness = ConnectionWorkflowHarness(
            presence: .clientOnly,
            pending: "owner@example.test",
            settingsMode: .failReplace
        )
        _ = await harness.workflow.begin(progress: { _ in })

        let state = await harness.workflow.confirm()

        XCTAssertEqual(state, .cleanupRequired)
        XCTAssertEqual(harness.controller.disconnectCount, 1)
        XCTAssertEqual(harness.store.replaceAttemptCount, 1)
        XCTAssertEqual(harness.store.replaceCount, 0)
    }

    func testSettingsReadFailureAfterCredentialConfirmationRollsBackController() async {
        let harness = ConnectionWorkflowHarness(
            presence: .clientOnly,
            failingLoadNumbers: [2]
        )
        _ = await harness.workflow.begin(progress: { _ in })

        let state = await harness.workflow.confirm()

        XCTAssertEqual(state, .cleanupRequired)
        XCTAssertEqual(harness.controller.disconnectCount, 1)
        XCTAssertEqual(harness.store.replaceAttemptCount, 0)
    }

    func testCancelClearsPendingIdentityAndInvokesControllerCancellation() async {
        let harness = ConnectionWorkflowHarness(presence: .clientOnly)
        _ = await harness.workflow.begin(progress: { _ in })

        let state = await harness.workflow.cancel()
        let laterConfirmation = await harness.workflow.confirm()

        XCTAssertEqual(state, .cancelled)
        XCTAssertEqual(laterConfirmation, .cleanupRequired)
        XCTAssertEqual(harness.controller.cancelCount, 1)
        XCTAssertEqual(harness.controller.confirmCount, 0)
        XCTAssertEqual(harness.store.replaceCount, 0)
    }

    func testDisconnectClearsCredentialsAndOnlyGoogleBinding() async {
        let harness = ConnectionWorkflowHarness(
            presence: .complete,
            binding: "owner@example.test"
        )

        let state = await harness.workflow.disconnect()

        XCTAssertEqual(state, .notConfigured)
        XCTAssertEqual(harness.controller.disconnectCount, 1)
        XCTAssertNil(harness.store.lastReplacement?.googleAccountBinding)
        XCTAssertEqual(harness.recorder.recordedCalls, [
            "controller.disconnect",
            "settings.load",
            "settings.replace",
        ])
        assertNonGoogleSettingsPreserved(harness)
    }

    func testDisconnectStillClearsBindingWhenControllerCleanupFails() async {
        let harness = ConnectionWorkflowHarness(
            presence: .complete,
            binding: "owner@example.test",
            controllerFailures: [.disconnect: .providerUnavailable]
        )

        let state = await harness.workflow.disconnect()

        XCTAssertEqual(state, .cleanupRequired)
        XCTAssertEqual(harness.controller.disconnectCount, 1)
        XCTAssertNil(harness.store.lastReplacement?.googleAccountBinding)
        assertNonGoogleSettingsPreserved(harness)
    }

    func testDisconnectStillAttemptsControllerWhenSettingsCleanupFails() async {
        let harness = ConnectionWorkflowHarness(
            presence: .complete,
            binding: "owner@example.test",
            settingsMode: .failLoad
        )

        let state = await harness.workflow.disconnect()

        XCTAssertEqual(state, .cleanupRequired)
        XCTAssertEqual(harness.controller.disconnectCount, 1)
        XCTAssertEqual(harness.store.loadCount, 1)
        XCTAssertEqual(harness.store.replaceCount, 0)
    }

    func testOverlappingCancelPreventsStaleBeginFromPublishingConfirmation() async {
        let gate = TestAsyncGate()
        let harness = ConnectionWorkflowHarness(presence: .clientOnly, beginGate: gate)
        let beginTask = Task {
            await harness.workflow.begin(progress: { _ in })
        }
        await gate.waitUntilEntered()

        let cancelState = await harness.workflow.cancel()
        await gate.open()
        let beginState = await beginTask.value

        XCTAssertEqual(cancelState, .cancelled)
        XCTAssertEqual(beginState, .cancelled)
        XCTAssertEqual(harness.controller.confirmCount, 0)
        XCTAssertEqual(harness.store.replaceCount, 0)
    }

    func testOverlappingDisconnectPreventsStaleConfirmFromPublishingConnectedState() async {
        let gate = TestAsyncGate()
        let harness = ConnectionWorkflowHarness(
            presence: .clientOnly,
            confirmGate: gate
        )
        _ = await harness.workflow.begin(progress: { _ in })
        let confirmTask = Task { await harness.workflow.confirm() }
        await gate.waitUntilEntered()

        let disconnectState = await harness.workflow.disconnect()
        await gate.open()
        let confirmState = await confirmTask.value

        XCTAssertEqual(disconnectState, .notConfigured)
        XCTAssertEqual(confirmState, .cleanupRequired)
        XCTAssertNil(harness.store.storedSettings.googleAccountBinding)
        XCTAssertNotEqual(confirmState, .connected(displayEmail: "owner@example.test", capability: .readOnly))
    }

    func testStalePreemptedConfirmationCannotDestroyNewerConnectedState() async {
        let gate = TestAsyncGate()
        let harness = ConnectionWorkflowHarness(
            presence: .clientOnly,
            confirmGate: gate
        )
        _ = await harness.workflow.begin(progress: { _ in })
        let staleConfirmTask = Task { await harness.workflow.confirm() }
        await gate.waitUntilEntered()

        let cancelState = await harness.workflow.cancel()
        let newerBeginState = await harness.workflow.begin(progress: { _ in })
        let newerConfirmState = await harness.workflow.confirm()
        await gate.open()
        let staleConfirmState = await staleConfirmTask.value
        let finalState = await harness.workflow.loadState()

        XCTAssertEqual(cancelState, .cancelled)
        XCTAssertEqual(newerBeginState, .confirmIdentity(displayEmail: "owner@example.test"))
        XCTAssertEqual(newerConfirmState, .connected(displayEmail: "owner@example.test", capability: .readOnly))
        XCTAssertEqual(staleConfirmState, .cleanupRequired)
        XCTAssertEqual(finalState, .connected(displayEmail: "owner@example.test", capability: .readOnly))
        XCTAssertEqual(harness.controller.disconnectCount, 0)
        XCTAssertEqual(
            harness.store.storedSettings.googleAccountBinding?.normalizedEmail,
            "owner@example.test"
        )
    }

    func testFailedNewerOperationDoesNotSuppressStaleConfirmationCleanup() async {
        let gate = TestAsyncGate()
        let harness = ConnectionWorkflowHarness(
            presence: .clientOnly,
            controllerFailures: [.saveClientConfiguration: .providerUnavailable],
            confirmGate: gate
        )
        _ = await harness.workflow.begin(progress: { _ in })
        let staleConfirmTask = Task { await harness.workflow.confirm() }
        await gate.waitUntilEntered()

        let cancelState = await harness.workflow.cancel()
        let failedNewerState = await harness.workflow.saveClientConfiguration(
            clientIdentifier: "synthetic-client-id",
            clientSecret: "synthetic-client-secret"
        )
        await gate.open()
        let staleConfirmState = await staleConfirmTask.value
        let finalState = await harness.workflow.loadState()

        XCTAssertEqual(cancelState, .cancelled)
        XCTAssertEqual(failedNewerState, .providerUnavailable)
        XCTAssertEqual(staleConfirmState, .cleanupRequired)
        XCTAssertEqual(finalState, .notConfigured)
        XCTAssertEqual(harness.controller.disconnectCount, 1)
        XCTAssertNil(harness.store.storedSettings.googleAccountBinding)
    }

    private func assertNonGoogleSettingsPreserved(
        _ harness: ConnectionWorkflowHarness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let replacement = harness.store.lastReplacement else {
            return XCTFail("Expected a settings replacement", file: file, line: line)
        }
        XCTAssertEqual(replacement.schemaVersion, harness.initialSettings.schemaVersion, file: file, line: line)
        XCTAssertEqual(replacement.vaultBookmark, harness.initialSettings.vaultBookmark, file: file, line: line)
        XCTAssertEqual(replacement.calendarRoles, harness.initialSettings.calendarRoles, file: file, line: line)
        XCTAssertEqual(replacement.calendarRoleAudit, harness.initialSettings.calendarRoleAudit, file: file, line: line)
    }
}

private actor WorkflowProgressRecorder {
    private var states: [GoogleConnectionWorkflowState] = []

    func append(_ state: GoogleConnectionWorkflowState) {
        states.append(state)
    }

    var recordedStates: [GoogleConnectionWorkflowState] {
        states
    }
}
