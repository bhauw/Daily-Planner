import XCTest
@testable import DailyPlannerDomain

/// The case that produced this: 68 characters of credentials JSON in the secret field, accepted
/// silently, surfacing much later as an HTTP 401 the user had no way to interpret.
final class GoogleClientFieldAdviceTests: XCTestCase {
    private let realisticSecret = "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"
    private let realisticIdentifier =
        "468699278098-06i9bv82f9vrphu6jbbv6l50ipano214.apps.googleusercontent.com"

    func testAcceptsCredentialsShapedTheWayGoogleIssuesThem() {
        XCTAssertNil(GoogleClientFieldAdvice.clientIdentifierAdvice(realisticIdentifier))
        XCTAssertNil(GoogleClientFieldAdvice.clientSecretAdvice(realisticSecret))
    }

    func testSaysNothingAboutAnEmptyFieldTheUserHasNotFilledIn() {
        XCTAssertNil(GoogleClientFieldAdvice.clientSecretAdvice(""))
        XCTAssertNil(GoogleClientFieldAdvice.clientSecretAdvice("   "))
        XCTAssertNil(GoogleClientFieldAdvice.clientIdentifierAdvice(""))
    }

    func testCatchesAPastedFragmentOfTheCredentialsFile() {
        // The actual failure: label, colon and quotes pasted along with the value.
        let pasted = "\"client_secret\": \"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\""
        XCTAssertEqual(
            GoogleClientFieldAdvice.clientSecretAdvice(pasted),
            "Paste only the secret itself — this still has JSON punctuation in it."
        )
    }

    func testCatchesTheTwoFieldsSwapped() {
        XCTAssertEqual(
            GoogleClientFieldAdvice.clientSecretAdvice(realisticIdentifier),
            "That is the client ID, not the secret."
        )
        XCTAssertEqual(
            GoogleClientFieldAdvice.clientIdentifierAdvice(realisticSecret),
            "A client ID ends in .apps.googleusercontent.com."
        )
    }

    func testCatchesASecretThatIsNotOne() {
        XCTAssertEqual(
            GoogleClientFieldAdvice.clientSecretAdvice("hunter2"),
            "A client secret starts with GOCSPX- and is about 35 characters."
        )
        XCTAssertEqual(
            GoogleClientFieldAdvice.clientSecretAdvice("GOCSPX-has spaces in it here"),
            "A client secret contains only letters, digits, - and _."
        )
    }

    func testIgnoresSurroundingWhitespaceRatherThanScoldingAboutIt() {
        // Trailing newlines come free with most copy buttons; that is not worth a warning.
        XCTAssertNil(GoogleClientFieldAdvice.clientSecretAdvice("  \(realisticSecret)\n"))
        XCTAssertNil(GoogleClientFieldAdvice.clientIdentifierAdvice("\(realisticIdentifier)  "))
    }
}
