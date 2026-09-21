import DailyPlannerDomain
import Foundation
import XCTest
@testable import DailyPlannerGoogle

final class GoogleOAuthRequestTests: XCTestCase {
    func testReadOnlyScopesHaveTheApprovedFiveValuesInOrder() {
        // Break caught: a scope is added, removed, reordered, or changed.
        XCTAssertEqual(
            ApprovedGoogleScopes.readOnly,
            [
                "openid",
                "email",
                "https://www.googleapis.com/auth/gmail.readonly",
                "https://www.googleapis.com/auth/calendar.readonly",
                "https://www.googleapis.com/auth/tasks.readonly",
            ]
        )
    }

    func testRequestUsesExactEndpointLoopbackRedirectAndQueryBoundary() throws {
        // Break caught: the request targets a different endpoint, callback, or query boundary.
        let request = try GoogleOAuthRequest(
            clientIdentifier: "synthetic-client.apps.example.test",
            redirectPort: 43117,
            pkce: PKCEPair(verifier: String(repeating: "a", count: 43), challenge: "literal-challenge"),
            state: String(repeating: "b", count: 43)
        )

        XCTAssertEqual(request.redirectURL.absoluteString, "http://127.0.0.1:43117/oauth/callback")

        let endpoint = try XCTUnwrap(URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(endpoint.scheme, "https")
        XCTAssertEqual(endpoint.host, "accounts.google.com")
        XCTAssertEqual(endpoint.path, "/o/oauth2/v2/auth")

        let items = try XCTUnwrap(endpoint.queryItems)
        let expectedValues = [
            "response_type": "code",
            "client_id": "synthetic-client.apps.example.test",
            "redirect_uri": "http://127.0.0.1:43117/oauth/callback",
            "scope": "openid email https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/tasks.readonly",
            "access_type": "offline",
            "prompt": "consent",
            "include_granted_scopes": "false",
            "code_challenge": "literal-challenge",
            "code_challenge_method": "S256",
            "state": String(repeating: "b", count: 43),
        ]
        XCTAssertEqual(Set(items.map(\.name)), Set(expectedValues.keys))
        for (name, expectedValue) in expectedValues {
            XCTAssertEqual(items.filter { $0.name == name }.count, 1, "Expected one \(name) query item")
            XCTAssertEqual(items.first(where: { $0.name == name })?.value, expectedValue)
        }
    }

    func testRejectsAnyScopeOrderMembershipOrDuplicationChange() {
        // Break caught: a caller can broaden, narrow, reorder, or duplicate approved permissions.
        let changedSets = [
            [
                "https://www.googleapis.com/auth/tasks.readonly",
                "https://www.googleapis.com/auth/calendar.readonly",
                "https://www.googleapis.com/auth/gmail.readonly",
                "email",
                "openid",
            ],
            [
                "openid",
                "email",
                "https://www.googleapis.com/auth/gmail.readonly",
                "https://www.googleapis.com/auth/calendar.readonly",
            ],
            [
                "openid",
                "email",
                "https://www.googleapis.com/auth/gmail.readonly",
                "https://www.googleapis.com/auth/calendar.readonly",
                "https://www.googleapis.com/auth/tasks.readonly",
                "https://www.googleapis.com/auth/gmail.modify",
            ],
            [
                "openid",
                "email",
                "https://www.googleapis.com/auth/gmail.readonly",
                "https://www.googleapis.com/auth/calendar.readonly",
                "https://www.googleapis.com/auth/tasks.readonly",
                "https://www.googleapis.com/auth/tasks.readonly",
            ],
            ["arbitrary"],
        ]

        for scopes in changedSets {
            XCTAssertThrowsError(try GoogleOAuthRequest(
                clientIdentifier: "synthetic-client.apps.example.test",
                redirectPort: 43117,
                scopes: scopes
            ))
        }
    }

    func testRejectsEmptyOrControlContainingClientIdentifiersAndInvalidPorts() {
        // Break caught: invalid caller-controlled values are silently accepted or rewritten.
        for clientIdentifier in ["", "synthetic\nclient", "synthetic\u{7F}client"] {
            XCTAssertThrowsError(try GoogleOAuthRequest(
                clientIdentifier: clientIdentifier,
                redirectPort: 43117,
                pkce: PKCEPair(verifier: String(repeating: "a", count: 43), challenge: "literal-challenge"),
                state: String(repeating: "b", count: 43)
            ))
        }

        for redirectPort in [0, 65_536] {
            XCTAssertThrowsError(try GoogleOAuthRequest(
                clientIdentifier: "synthetic-client.apps.example.test",
                redirectPort: redirectPort,
                pkce: PKCEPair(verifier: String(repeating: "a", count: 43), challenge: "literal-challenge"),
                state: String(repeating: "b", count: 43)
            ))
        }
    }
}
