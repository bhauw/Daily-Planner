import XCTest
@testable import DailyPlannerGoogle

final class PKCETests: XCTestCase {
    func testGeneratedPKCEValuesUseSecureBase64URLContractsAndS256Derivation() throws {
        // Break caught: generated verifier/challenge values use the wrong alphabet, padding, or derivation.
        for _ in 0..<5 {
            let pair = try PKCEPair.generate()
            XCTAssertGreaterThanOrEqual(pair.verifier.count, 43)
            XCTAssertGreaterThanOrEqual(pair.challenge.count, 43)
            XCTAssertEqual(pair.method, "S256")
            XCTAssertFalse(pair.verifier.contains("="))
            XCTAssertFalse(pair.challenge.contains("="))
            XCTAssertTrue(pair.verifier.allSatisfy(isBase64URLCharacter))
            XCTAssertTrue(pair.challenge.allSatisfy(isBase64URLCharacter))
            XCTAssertEqual(pair.challenge, PKCEPair.challenge(for: pair.verifier))
        }
    }

    func testGeneratedStatesUseSecureBase64URLContracts() throws {
        // Break caught: state values are shorter than 32 random bytes or use a non-URL-safe encoding.
        for _ in 0..<5 {
            let state = try OAuthState.generate()
            XCTAssertGreaterThanOrEqual(state.count, 43)
            XCTAssertFalse(state.contains("="))
            XCTAssertTrue(state.allSatisfy(isBase64URLCharacter))
        }
    }

    func testStateMatchingRequiresExactUTF8ByteEquality() {
        // Break caught: state comparison accepts a different value or a matching prefix.
        XCTAssertTrue(OAuthState.matches(expected: "expected-state", received: "expected-state"))
        XCTAssertFalse(OAuthState.matches(expected: "expected-state", received: "different-state"))
        XCTAssertFalse(OAuthState.matches(expected: "expected-state", received: "expected"))
        XCTAssertFalse(OAuthState.matches(expected: "expected", received: "expected-state"))
    }

    private func isBase64URLCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
    }
}
