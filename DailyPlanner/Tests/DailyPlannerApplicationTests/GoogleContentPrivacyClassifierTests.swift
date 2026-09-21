import XCTest
import DailyPlannerApplication
import DailyPlannerDomain

final class GoogleContentPrivacyClassifierTests: XCTestCase {
    private let classifier = DeterministicGoogleContentPrivacyClassifier()

    func testClassifierMarksSensitiveAndUncertainContentPrivate() {
        for text in ["routing number 000111", "password reset code", "diagnosis", "legal privilege"] {
            XCTAssertEqual(
                classifier.classify(
                    .email(
                        subject: text,
                        sender: "sender@example.test",
                        body: nil,
                        bodyKind: .plainText
                    )
                ),
                .private,
                text
            )
        }

        XCTAssertEqual(
            classifier.classify(
                .email(
                    subject: "Hello",
                    sender: "sender@example.test",
                    body: nil,
                    bodyKind: .unsupported
                )
            ),
            .private
        )
        XCTAssertEqual(classifier.classify(.task(title: "Buy groceries", notes: nil)), .ordinary)
    }

    func testClassifierCoversSensitiveIndicatorCategoriesAcrossRecordKinds() {
        let inputs: [(String, GoogleContentClassificationInput)] = [
            ("financial", .task(title: "Confirm bank account", notes: nil)),
            ("card", .email(subject: "Credit card statement", sender: "sender@example.test", body: nil, bodyKind: .plainText)),
            ("credential", .email(subject: "Update", sender: "sender@example.test", body: "API key rotated", bodyKind: .html)),
            ("secret", .task(title: "Rotate client secret", notes: nil)),
            ("health", .event(title: "Appointment", description: "Prescription review", location: nil)),
            ("legal", .event(title: "Meeting", description: nil, location: "Attorney office")),
        ]

        for (name, input) in inputs {
            XCTAssertEqual(classifier.classify(input), .private, name)
        }
    }

    func testClassifierNormalizesCaseWidthAndCanonicalUnicode() {
        XCTAssertEqual(
            classifier.classify(.task(title: "PASSWORD RESET", notes: nil)),
            .private
        )
        XCTAssertEqual(
            classifier.classify(.task(title: "ＰＡＳＳＷＯＲＤ reset", notes: nil)),
            .private
        )
        XCTAssertEqual(
            classifier.classify(.task(title: "p\u{0061}\u{0301}ssword reset", notes: nil)),
            .private
        )
    }

    func testClassifierUsesTokenAndPhraseBoundaries() {
        for text in ["passwordless login", "diagnostic tooling", "legalese review", "the secretary called"] {
            XCTAssertEqual(
                classifier.classify(.task(title: text, notes: nil)),
                .ordinary,
                text
            )
        }
    }

    func testClassifierFailsClosedForUnknownInvalidAndUnsupportedContent() {
        XCTAssertEqual(classifier.classify(.unknown), .private)
        XCTAssertEqual(
            classifier.classify(.email(subject: "Hello", sender: "sender@example.test", body: nil, bodyKind: .unsupported)),
            .private
        )
        XCTAssertEqual(
            classifier.classify(.email(subject: "Hello", sender: "sender@example.test", body: "bad \u{FFFD} decoding", bodyKind: .plainText)),
            .private
        )
        XCTAssertEqual(classifier.classify(.event(title: "", description: nil, location: nil)), .private)
    }

    func testClassifierFailsClosedForTokenlessAndDefaultIgnorableContent() {
        for text in ["---", "\u{200B}", "\u{2060}"] {
            XCTAssertEqual(classifier.classify(.task(title: text, notes: nil)), .private, text)
        }
    }

    func testClassifierDefeatsMarkupEntityAndDefaultIgnorableObfuscation() {
        for text in [
            "pass\u{200B}word reset",
            "pass<span></span>word reset",
            "pass&#x77;ord reset",
            "verification&#32;code",
        ] {
            XCTAssertEqual(classifier.classify(.task(title: text, notes: nil)), .private, text)
        }
    }

    func testClassifierCoversReviewedFinancialCredentialHealthAndLegalPhrases() {
        for text in [
            "verification code",
            "bank balance",
            "medical appointment",
            "lawyer consultation",
        ] {
            XCTAssertEqual(classifier.classify(.task(title: text, notes: nil)), .private, text)
        }
    }

    func testExpandedIndicatorsStillRequireExactTokenAndPhraseBoundaries() {
        for text in [
            "verification codec",
            "riverbank balanced stones",
            "paramedical appointments",
            "lawyering consultations",
            "compasswording exercise",
        ] {
            XCTAssertEqual(classifier.classify(.task(title: text, notes: nil)), .ordinary, text)
        }
    }
}
