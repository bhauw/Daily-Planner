import DailyPlannerDomain
import Foundation
import XCTest
@testable import DailyPlannerGoogle

final class GoogleRequestBuilderTests: XCTestCase {
    func testGetCreatesOneValidatedBearerAuthorizationHeader() throws {
        // Break caught: request construction omits, corrupts, duplicates, or leaks a bearer credential.
        let token = try GoogleAccessToken(validating: "synthetic-access-token")
        let request = try GoogleRequestBuilder.get(
            url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages?q=after%3A1788112800&maxResults=100")!,
            accessToken: token
        )

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.allHTTPHeaderFields?.count, 1)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-access-token")
        XCTAssertNoThrow(try GoogleNetworkPolicy.validate(request))
    }

    func testGetRejectsAnUnsafeProviderURLBeforeReturningRequest() throws {
        // Break caught: construction creates a request for an attachment-byte endpoint.
        let token = try GoogleAccessToken(validating: "synthetic-access-token")

        XCTAssertThrowsError(try GoogleRequestBuilder.get(
            url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/x/attachments/y")!,
            accessToken: token
        ))
    }
}
