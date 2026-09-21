import XCTest
@testable import DailyPlannerDomain

final class GoogleConnectionTests: XCTestCase {
    private func assertClientConfigurationValidationAndRedaction() throws {
        let configuration = try GoogleOAuthClientConfiguration(
            clientIdentifier: "synthetic-client.apps.example.test",
            clientSecret: "synthetic-secret-canary"
        )

        XCTAssertTrue(configuration.clientIdentifier == "synthetic-client.apps.example.test")
        XCTAssertTrue(configuration.clientSecret == "synthetic-secret-canary")
        XCTAssertFalse(String(describing: configuration).contains("synthetic"))
        XCTAssertFalse(String(reflecting: configuration).contains("synthetic"))
        XCTAssertTrue(Array(configuration.customMirror.children).isEmpty)

        for (identifier, secret) in [
            ("", "valid-secret"),
            ("valid-client", ""),
            ("client\nvalue", "valid-secret"),
            ("valid-client", "secret\u{7F}value"),
            (String(repeating: "c", count: 4_097), "valid-secret"),
            ("valid-client", String(repeating: "s", count: 4_097)),
        ] {
            XCTAssertThrowsError(
                try GoogleOAuthClientConfiguration(
                    clientIdentifier: identifier,
                    clientSecret: secret
                )
            ) { error in
                XCTAssertEqual(error as? GoogleOAuthCredentialStoreError, .invalidValue)
                XCTAssertFalse(String(reflecting: error).contains(identifier))
                XCTAssertFalse(String(reflecting: error).contains(secret))
            }
        }
    }

    func testIdentityBindingNormalizesCaseAndOuterWhitespace() throws {
        let binding = try GoogleIdentityBinding(normalizing: "  Student@Example.Test  ")

        XCTAssertEqual(binding.normalizedEmail, "student@example.test")
    }

    func testIdentityBindingRejectsControlCharactersAndMalformedAddresses() {
        for value in ["", "missing-at.example.test", "two@@example.test", "line@example.test\nInjected"] {
            XCTAssertThrowsError(try GoogleIdentityBinding(normalizing: value)) { error in
                XCTAssertEqual(error as? GoogleIdentityBindingError, .invalidEmail)
            }
        }
        XCTAssertNoThrow(try assertClientConfigurationValidationAndRedaction())
    }

    func testEmptySettingsHaveNoGoogleIdentityAndUseSchemaTwo() {
        XCTAssertEqual(PrivateSettings.empty.schemaVersion, 2)
        XCTAssertNil(PrivateSettings.empty.googleAccountBinding)
    }
}
