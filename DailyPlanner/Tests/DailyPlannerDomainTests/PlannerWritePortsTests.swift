import Foundation
import XCTest
@testable import DailyPlannerDomain

/// Validation for the two things this app can write to someone's account.
///
/// These rules are not input hygiene — they are the last point at which a mistake is still
/// recoverable. Past this file a message is assembled into a header block and handed to Gmail.
final class PlannerWritePortsTests: XCTestCase {
    // MARK: - Addresses

    func testAddressesWithLineBreaksAreRefusedAsInjection() {
        // Break caught: CR/LF survives into an address. An address is written verbatim into a
        // header line; a newline inside one ends that header and starts another, so
        // "a@b.com\r\nBcc: everyone@example.com" is not a strange address — it is a second
        // header the user never wrote. This is THE rule in this file.
        for raw in [
            "a@b.com\r\nBcc: everyone@example.com",
            "a@b.com\nBcc: everyone@example.com",
            "a@b.com\r",
        ] {
            XCTAssertThrowsError(try PlannerMailAddress(validating: raw)) { error in
                XCTAssertEqual(error as? PlannerWriteError, .headerInjection, "for \(raw.debugDescription)")
            }
        }
    }

    func testOrdinaryAddressesAreAccepted() throws {
        for raw in [
            "calendar@example.test",
            "first.last+tag@sub.example.co.uk",
            "  padded@example.com  ",
        ] {
            XCTAssertEqual(try PlannerMailAddress(validating: raw).value, raw.trimmingCharacters(in: .whitespaces))
        }
    }

    func testMalformedAddressesAreRefused() {
        // Conservative on purpose: a false refusal is an error the user can see and correct; a
        // false accept is mail sent somewhere they did not intend.
        for raw in [
            "", "no-at-sign", "two@at@signs.com", "@example.com", "local@",
            "local@nodot", "local@.example.com", "local@example..com", "local@example.com.",
            "spaced address@example.com", "<bracketed@example.com>", "a,b@example.com",
            "a@example.com;c@example.com",
        ] {
            XCTAssertThrowsError(try PlannerMailAddress(validating: raw), "must refuse \(raw.debugDescription)")
        }
    }

    // MARK: - Outgoing mail

    func testValidMessageSurvivesConstruction() throws {
        let mail = try PlannerOutgoingMail(
            to: ["a@example.com"], cc: ["b@example.com"], bcc: ["c@example.com"],
            subject: "  Lunch  ", body: "Thursday?", threadID: "t-1", inReplyTo: "<abc@mail.gmail.com>"
        )
        XCTAssertEqual(mail.subject, "Lunch", "the subject is trimmed, not the body")
        XCTAssertEqual(mail.body, "Thursday?")
        XCTAssertEqual(mail.inReplyTo, "<abc@mail.gmail.com>")
    }

    func testAMessageMustHaveSomewhereToGoAndSomethingToSay() {
        XCTAssertThrowsError(try PlannerOutgoingMail(to: [], subject: "Hi", body: "x")) {
            XCTAssertEqual($0 as? PlannerWriteError, .invalidRecipient)
        }
        XCTAssertThrowsError(try PlannerOutgoingMail(to: ["a@b.com"], subject: "   ", body: "x")) {
            XCTAssertEqual($0 as? PlannerWriteError, .emptySubject)
        }
        XCTAssertThrowsError(try PlannerOutgoingMail(to: ["a@b.com"], subject: "Hi", body: " \n ")) {
            XCTAssertEqual($0 as? PlannerWriteError, .emptyBody)
        }
    }

    func testRecipientCountIsBounded() {
        // Break caught: a slip in the composer becomes a mass mail. This app sends replies.
        let many = (0..<(PlannerOutgoingMail.maxRecipients + 1)).map { "user\($0)@example.com" }
        XCTAssertThrowsError(try PlannerOutgoingMail(to: many, subject: "Hi", body: "x")) {
            XCTAssertEqual($0 as? PlannerWriteError, .tooLarge)
        }
        let atTheLimit = (0..<PlannerOutgoingMail.maxRecipients).map { "user\($0)@example.com" }
        XCTAssertNoThrow(try PlannerOutgoingMail(to: atTheLimit, subject: "Hi", body: "x"))
    }

    func testSubjectAndBodyAreBounded() {
        XCTAssertThrowsError(
            try PlannerOutgoingMail(
                to: ["a@b.com"],
                subject: String(repeating: "s", count: PlannerOutgoingMail.maxSubjectBytes + 1),
                body: "x"
            )
        )
        XCTAssertThrowsError(
            try PlannerOutgoingMail(
                to: ["a@b.com"], subject: "Hi",
                body: String(repeating: "b", count: PlannerOutgoingMail.maxBodyBytes + 1)
            )
        )
    }

    func testReplyHeadersAreHeldToTheSameLineBreakRule() {
        // A Message-ID is angle-bracketed so it cannot go through the address validator — but it
        // lands in a header line just the same.
        XCTAssertThrowsError(
            try PlannerOutgoingMail(to: ["a@b.com"], subject: "Hi", body: "x", inReplyTo: "<a>\r\nBcc: e@x.com")
        ) {
            XCTAssertEqual($0 as? PlannerWriteError, .headerInjection)
        }
        XCTAssertThrowsError(
            try PlannerOutgoingMail(to: ["a@b.com"], subject: "Hi", body: "x", threadID: "a/../b")
        ) {
            XCTAssertEqual($0 as? PlannerWriteError, .invalidIdentifier)
        }
    }

    // MARK: - Event drafts

    func testEventNeedsATitleAndAForwardInterval() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertThrowsError(
            try PlannerEventDraft(title: "  ", start: start, end: start.addingTimeInterval(3_600))
        ) {
            XCTAssertEqual($0 as? PlannerWriteError, .invalidTitle)
        }
        XCTAssertThrowsError(
            try PlannerEventDraft(title: "Study", start: start, end: start)
        ) {
            XCTAssertEqual($0 as? PlannerWriteError, .invalidInterval)
        }
        XCTAssertThrowsError(
            try PlannerEventDraft(title: "Study", start: start, end: start.addingTimeInterval(-60))
        ) {
            XCTAssertEqual($0 as? PlannerWriteError, .invalidInterval)
        }
    }

    func testAbsurdlyLongEventsAreRefused() {
        // Break caught: a mistyped year writes a multi-decade block onto a real calendar. "2062"
        // is one keystroke away from "2026", and nothing downstream would question it.
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertThrowsError(
            try PlannerEventDraft(
                title: "Study", start: start,
                end: start.addingTimeInterval(PlannerEventDraft.maxDuration + 1)
            )
        ) {
            XCTAssertEqual($0 as? PlannerWriteError, .invalidInterval)
        }
        XCTAssertNoThrow(
            try PlannerEventDraft(
                title: "Study", start: start,
                end: start.addingTimeInterval(PlannerEventDraft.maxDuration)
            )
        )
    }

    func testValidationFailuresAllReadAsRefusals() {
        // Break caught: a validation failure is reported as "try again later". No amount of
        // retrying fixes a malformed address.
        for error in PlannerWriteError.allCases {
            XCTAssertEqual(error.writeOutcome, .refused)
        }
    }
}
