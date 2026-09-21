import DailyPlannerDomain
import XCTest
@testable import DailyPlannerGoogle

/// The scope check is what stands between "the UI offers a Send button" and "the token can
/// actually honour it". It is also what decides whether an already-connected account keeps
/// working, so both directions matter: a read-only grant must stay valid, and a write grant must
/// be recognised rather than rejected as unexpected.
final class GoogleGrantedCapabilityTests: XCTestCase {
    private func scope(_ scopes: [String]) -> String { scopes.joined(separator: " ") }

    /// The regression that would have hurt most: every account connected so far holds the
    /// read-only grant, and adding write support must not invalidate it. If this fails, the app
    /// silently drops to synthetic fixtures and the calendar goes blank again.
    func testAnExistingReadOnlyGrantRemainsValidAndReportsNoWriteAbility() throws {
        let capability = try GoogleOAuthTokenService.validateApprovedScopes(
            scope(ApprovedGoogleScopes.readOnly)
        )
        XCTAssertEqual(capability, .readOnly)
        XCTAssertFalse(capability.canSendMail)
        XCTAssertFalse(capability.canCreateEvents)
    }

    func testAReadWriteGrantIsRecognisedAndReportsBothWriteAbilities() throws {
        let capability = try GoogleOAuthTokenService.validateApprovedScopes(
            scope(ApprovedGoogleScopes.readWrite)
        )
        XCTAssertEqual(capability, .readWrite)
        XCTAssertTrue(capability.canSendMail)
        XCTAssertTrue(capability.canCreateEvents)
    }

    /// Write scopes are additive, so the read-only set must remain a strict subset — otherwise
    /// reconnecting for writes would quietly drop a read capability the app depends on.
    func testWriteGrantIsAStrictSupersetOfTheReadOnlyGrant() {
        XCTAssertTrue(Set(ApprovedGoogleScopes.readOnly).isSubset(of: Set(ApprovedGoogleScopes.readWrite)))
        XCTAssertEqual(ApprovedGoogleScopes.readWrite.count, ApprovedGoogleScopes.readOnly.count + 2)
    }

    /// `gmail.send` cannot read, modify or delete mail, and it is the only send scope we take.
    /// A broader one (`gmail.modify`, `mail.google.com`) must never be accepted.
    func testOnlyTheNarrowSendScopeIsApproved() {
        XCTAssertTrue(ApprovedGoogleScopes.readWrite.contains("https://www.googleapis.com/auth/gmail.send"))
        for overbroad in [
            "https://www.googleapis.com/auth/gmail.modify",
            "https://mail.google.com/",
            "https://www.googleapis.com/auth/calendar",
        ] {
            XCTAssertFalse(
                ApprovedGoogleScopes.readWrite.contains(overbroad),
                "\(overbroad) grants more than sending or creating and must not be requested"
            )
        }
    }

    /// A token carrying more than we asked for is still a mismatch — "extra" is not "fine".
    func testAGrantWithAnUnexpectedExtraScopeIsRejected() {
        let extra = ApprovedGoogleScopes.readWrite + ["https://www.googleapis.com/auth/drive"]
        XCTAssertThrowsError(try GoogleOAuthTokenService.validateApprovedScopes(scope(extra)))
    }

    /// A partial write grant — the user unticking one box on the consent screen — must not read
    /// as full write ability, or the UI would offer a button the token cannot honour.
    func testAPartialWriteGrantIsRejectedRatherThanTreatedAsWritable() {
        let partial = ApprovedGoogleScopes.readOnly + ["https://www.googleapis.com/auth/gmail.send"]
        XCTAssertThrowsError(try GoogleOAuthTokenService.validateApprovedScopes(scope(partial))) { error in
            XCTAssertEqual(error as? GoogleAccessTokenProviderError, .scopeMismatch)
        }
    }

    func testDuplicateScopesAreRejected() {
        let duplicated = ApprovedGoogleScopes.readOnly + ["email"]
        XCTAssertThrowsError(try GoogleOAuthTokenService.validateApprovedScopes(scope(duplicated)))
    }

    /// Both approved sets must be requestable at the consent screen; nothing else may be.
    func testOnlyApprovedSetsCanBeRequestedAtConsent() throws {
        for scopes in ApprovedGoogleScopes.approvedSets {
            XCTAssertNoThrow(
                try GoogleOAuthRequest(
                    clientIdentifier: "client", redirectPort: 8080,
                    pkce: PKCEPair(verifier: "v", challenge: "c"), state: "s", scopes: scopes
                )
            )
        }
        XCTAssertThrowsError(
            try GoogleOAuthRequest(
                clientIdentifier: "client", redirectPort: 8080,
                pkce: PKCEPair(verifier: "v", challenge: "c"), state: "s",
                scopes: ApprovedGoogleScopes.readOnly + ["https://www.googleapis.com/auth/drive"]
            )
        )
    }
}
