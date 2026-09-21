import Foundation
import XCTest
@testable import DailyPlannerAPI

final class HTTPSecurityTests: XCTestCase {
    func testConstantTimeEqualsMatchesIdenticalStrings() {
        XCTAssertTrue(HTTPSecurity.constantTimeEquals("abc123", "abc123"))
    }

    func testConstantTimeEqualsRejectsDifferentStrings() {
        XCTAssertFalse(HTTPSecurity.constantTimeEquals("abc123", "abc124"))
    }

    func testConstantTimeEqualsRejectsDifferentLengths() {
        XCTAssertFalse(HTTPSecurity.constantTimeEquals("abc", "abcd"))
        XCTAssertFalse(HTTPSecurity.constantTimeEquals("abcd", "abc"))
    }

    func testConstantTimeEqualsRejectsEmptyVsNonEmpty() {
        XCTAssertFalse(HTTPSecurity.constantTimeEquals("", "x"))
        XCTAssertTrue(HTTPSecurity.constantTimeEquals("", ""))
    }

    func testGeneratedTokenIsBase64URL256Bit() {
        let token = HTTPSecurity.generateBearerToken()
        // 32 bytes → 43 base64url chars, no padding.
        XCTAssertEqual(token.count, 43)
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue(token.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    func testGeneratedTokensAreUnique() {
        let tokens = Set((0..<200).map { _ in HTTPSecurity.generateBearerToken() })
        XCTAssertEqual(tokens.count, 200)
    }
}
