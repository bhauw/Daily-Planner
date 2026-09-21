import Foundation
import Testing
@testable import GoogleOAuthCore

@Suite("Sanitized probe output")
struct RedactionTests {
    @Test("Live configuration reads only the designated environment key")
    func liveConfigurationUsesOnlyDesignatedEnvironmentKey() throws {
        let value = try GoogleOAuthEnvironment.clientID(from: [
            "IGNORED_GOOGLE_VALUE": "wrong-value",
            "DAILY_PLANNER_GOOGLE_CLIENT_ID": "unit-test-client",
        ])

        #expect(value == "unit-test-client")
        #expect(throws: GoogleOAuthEnvironmentError.missingConfiguration) {
            try GoogleOAuthEnvironment.clientID(from: ["IGNORED_GOOGLE_VALUE": "wrong-value"])
        }
    }

    @Test("Live failure output contains only fixed error and cleanup states")
    func liveFailureOutputIsSanitized() throws {
        let output = GoogleOAuthSafeFailureOutput(
            status: .failedSafe,
            primary: GoogleReadOnlyClientError.refreshFailed.rawValue,
            cleanup: GoogleOAuthCleanupStatus(
                remoteRevocation: .failed,
                keychainDeletion: .failed,
                cacheCleared: true
            )
        )
        let data = try JSONEncoder().encode(output)
        let encoded = try #require(String(data: data, encoding: .utf8))

        #expect(encoded.contains("refreshFailed"))
        #expect(encoded.contains("remoteRevocation"))
        #expect(!encoded.contains("unit-test-client"))
        #expect(!encoded.contains("callback-value"))
        #expect(!encoded.contains("credential"))
        #expect(!encoded.contains("http"))
    }

    @Test("Dry-run report states the safety boundary without secret-bearing fields")
    func dryRunReportIsSafe() {
        let report = GoogleOAuthDryRunReport.render()

        for scope in ApprovedScopes.readOnly {
            #expect(report.contains("scope: \(scope)"))
        }
        #expect(report.contains("loopback: 127.0.0.1 ephemeral-port"))
        #expect(report.contains("pkce: S256"))
        #expect(report.contains("state: 256-bit"))
        #expect(report.contains("incremental-authorization: disabled"))
        #expect(report.contains("live-readonly: BLOCKED_BY_USER_AUTH"))
        #expect(!report.lowercased().contains("client_id"))
        #expect(!report.lowercased().contains("authorization code"))
        #expect(!report.lowercased().contains("token"))
        #expect(!report.contains("https://accounts.google.com"))
    }

    @Test("Redaction removes OAuth URLs, codes, client IDs, and tokens")
    func removesOAuthSecrets() {
        let authorizationURL = [
            "https:/",
            "/example.invalid/oauth?",
            "client_id=client-secret&code=auth-secret",
        ].joined()
        let unsafe = """
        open \(authorizationURL)
        Authorization: Bearer access-secret
        {"refresh_token":"refresh-secret","access_token":"access-secret","code":"auth-secret"}
        """

        let safe = SensitiveValueRedactor.redact(
            unsafe,
            knownSecrets: ["client-secret", "auth-secret", "access-secret", "refresh-secret"]
        )

        #expect(!safe.contains("example.invalid"))
        #expect(!safe.contains("client-secret"))
        #expect(!safe.contains("auth-secret"))
        #expect(!safe.contains("access-secret"))
        #expect(!safe.contains("refresh-secret"))
        #expect(safe.contains("[REDACTED]"))
    }

    @Test("Probe result serializes booleans and approved scopes only")
    func resultContainsNoContentBearingFields() throws {
        let result = GoogleReadOnlyProbeResult(
            scopes: ApprovedScopes.readOnly,
            refreshSucceeded: true,
            gmailProfileRead: true,
            calendarListRead: true,
            taskListsRead: true,
            cleanupSucceeded: true
        )

        let data = try JSONEncoder().encode(result)
        let encoded = try #require(String(data: data, encoding: .utf8))

        #expect(!encoded.contains("access_token"))
        #expect(!encoded.contains("refresh_token"))
        #expect(!encoded.contains("client_id"))
        #expect(!encoded.contains("authorizationCode"))
        #expect(!encoded.contains("title"))
        #expect(!encoded.contains("address"))
        #expect(!encoded.contains("count"))
        #expect(!encoded.contains("name"))
    }
}
