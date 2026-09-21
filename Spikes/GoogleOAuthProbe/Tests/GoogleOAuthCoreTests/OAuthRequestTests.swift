import Foundation
import Testing
@testable import GoogleOAuthCore

@Suite("Google authorization request")
struct OAuthRequestTests {
    private let fixedPKCE = try! PKCEPair(
        verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    )

    @Test("Authorization request uses only the five approved read scopes")
    func authorizationRequestUsesOnlyApprovedReadScopes() throws {
        let request = try OAuthRequest(
            clientID: "unit-test-client",
            redirectPort: 54_321,
            pkce: fixedPKCE,
            state: "unit-test-state"
        )

        #expect(request.scopes == [
            "openid",
            "email",
            "https://www.googleapis.com/auth/gmail.readonly",
            "https://www.googleapis.com/auth/calendar.readonly",
            "https://www.googleapis.com/auth/tasks.readonly",
        ])
        #expect(request.redirectURL.scheme == "http")
        #expect(request.redirectURL.host == "127.0.0.1")
        #expect(request.redirectURL.port == 54_321)
        #expect(request.redirectURL.path == "/oauth/callback")

        let query = try #require(URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        #expect(values["scope"] == request.scopes.joined(separator: " "))
        #expect(values["code_challenge_method"] == "S256")
        #expect(values["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(values["state"] == "unit-test-state")
        #expect(values["include_granted_scopes"] == "false")
        #expect(values["access_type"] == "offline")
        #expect(values["response_type"] == "code")
        #expect(request.authorizationURL.query?.contains("gmail.modify") == false)
        #expect(request.authorizationURL.query?.contains("calendar.events") == false)
        #expect(request.scopes.contains("https://www.googleapis.com/auth/tasks") == false)
    }

    @Test("An unapproved scope is rejected before a request can be built")
    func rejectsAccidentalWriteScope() {
        #expect(throws: OAuthRequestError.unapprovedScopes) {
            try ApprovedScopes.validate(
                ApprovedScopes.readOnly + ["https://www.googleapis.com/auth/calendar.events"]
            )
        }
    }
}
