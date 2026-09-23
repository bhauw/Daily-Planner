import XCTest
import DailyPlannerDomain
@testable import DailyPlannerGoogle

/// Covers the Gmail triage adapter. The rules that matter here are privacy rules: a message the
/// classifier marked private must not have its snippet rendered, and a label must not be guessed
/// into someone's planning categories.
final class GoogleMailSourceTests: XCTestCase {
    private struct FakeTokens: GoogleAccessTokenProviding {
        func accessToken() async throws -> GoogleAccessToken {
            try GoogleAccessToken(validating: "test-token")
        }
    }

    private struct FakeGmail: GmailReading {
        var page: GmailMessagePage
        var records: [String: GmailMessageRecord] = [:]
        final class Calls: @unchecked Sendable {
            var formats: [GmailMessageFormat] = []
            var messageCalls = 0
        }
        var calls = Calls()

        func messages(
            receivedAfter: Date, pageToken: GmailPageToken?, accessToken: GoogleAccessToken
        ) async throws -> GmailMessagePage { page }

        func message(
            id: GmailMessageID, format: GmailMessageFormat, accessToken: GoogleAccessToken
        ) async throws -> GmailMessageRecord {
            calls.formats.append(format)
            calls.messageCalls += 1
            let key = id.withUnsafeRawValue { $0 }
            guard let record = records[key] else {
                throw GoogleAccessTokenError.invalidValue
            }
            return record
        }

        func changes(
            after historyID: GmailHistoryID, pageToken: GmailPageToken?,
            accessToken: GoogleAccessToken
        ) async throws -> GmailHistoryPage {
            throw GoogleAccessTokenError.invalidValue
        }
    }

    private func summary(
        id: String,
        subject: String = "Subject",
        snippet: String = "A snippet",
        sender: String = "Someone",
        labels: [String] = [],
        privacy: SourcePrivacyClass = .ordinary,
        received: TimeInterval = 1_757_800_000
    ) throws -> GmailMessageSummary {
        GmailMessageSummary(
            id: try GmailMessageID(validating: id),
            threadID: try GmailThreadID(validating: "thread-\(id)"),
            sender: sender,
            subject: subject,
            receivedAt: Date(timeIntervalSince1970: received),
            labels: labels,
            snippet: snippet,
            historyID: try GmailHistoryID(validating: "1"),
            privacyClass: privacy
        )
    }

    private func record(_ s: GmailMessageSummary) -> GmailMessageRecord {
        GmailMessageRecord(summary: s, bodyKind: .plainText, decodedBody: nil, attachments: [])
    }

    private func source(_ fake: FakeGmail) -> GoogleMailSource {
        GoogleMailSource(client: fake, tokens: FakeTokens())
    }

    // MARK: - Tests

    func testAPrivateMessageNeverRendersItsSnippet() throws {
        let s = try summary(
            id: "m1", subject: "Therapy appointment", snippet: "See you Tuesday at 4",
            privacy: .private
        )
        let item = GoogleMailSource.item(from: s)

        XCTAssertTrue(item.isPrivate)
        XCTAssertFalse(
            item.summary.contains("Tuesday"),
            "a private message's snippet must be withheld, not displayed"
        )
        XCTAssertEqual(item.title, "Therapy appointment", "the subject still identifies the row")
    }

    func testAnOrdinaryMessageKeepsItsSnippet() throws {
        let item = GoogleMailSource.item(from: try summary(id: "m1", snippet: "Room change"))
        XCTAssertFalse(item.isPrivate)
        XCTAssertEqual(item.summary, "Room change")
    }

    func testLabelsMapToCategoriesAndUnknownYieldsNoAnswer() {
        XCTAssertEqual(GoogleMailSource.category(forLabels: ["Career"]), .career)
        XCTAssertEqual(GoogleMailSource.category(forLabels: ["INBOX", "school"]), .school)
        XCTAssertEqual(GoogleMailSource.category(forLabels: ["Work"]), .work)
        XCTAssertNil(
            GoogleMailSource.category(forLabels: ["INBOX", "IMPORTANT"]),
            "an unrecognised label must not be read as a category"
        )
        XCTAssertNil(GoogleMailSource.category(forLabels: []))
    }

    // MARK: - Working out what a message is about

    func testAnExplicitLabelAlwaysBeatsAGuess() throws {
        // Break caught: inference overrules the user. A label is a choice they made; every
        // signal below it is the app guessing.
        let summary = try summary(
            id: "m1", subject: "ECONOMICS 250 midterm", sender: "recruiting@example.test",
            labels: ["Finance"]
        )
        XCTAssertEqual(GoogleMailSource.category(for: summary), .finance)
    }

    func testACourseCodeInTheSubjectMeansSchool() {
        // The strongest signal on a student's inbox, and it needs no list of institutions.
        for subject in ["DEMO 250 midterm moved", "Re: DEMO295 group", "INDG 101 — Assignment 3",
                "[DEMO 250] room change", "Fwd: CMPT 300 lab"] {
            XCTAssertTrue(
                GoogleMailSource.containsCourseCode(subject),
                "must read as a course code: \(subject)"
            )
        }
    }

    func testThingsThatLookLikeCourseCodesButAreNot() {
        // Break caught: the parser fires on ordinary mail. Each of these has letters near
        // digits and none of them is a course.
        for subject in [
            "Order 12345 confirmed",          // digits, no letter run
            "Save 20% on BUS fares",          // letters, digits not adjacent
            "RE: 251",                        // no letters immediately before
            "ABCDE 251 is not a course",      // five letters, too many
            "A 251 single letter",            // one letter, too few
            "ECONOMICS 250 is four digits",        // four digits
            "ECONOMICS 250 is two digits",           // two digits
            "lowercase bus 251",              // course codes are written upper-case
            "BUS251X trailing letter",        // does not end at the digits
        ] {
            XCTAssertFalse(
                GoogleMailSource.containsCourseCode(subject),
                "must NOT read as a course code: \(subject)"
            )
        }
    }

    func testSenderDomainsCarryTheCategoriesTheyObviouslyCarry() {
        let cases: [(String, PlannerCategory)] = [
            ("registrar@sfu.ca", .school),
            ("noreply@instructure.com", .school),
            ("advisor@someschool.edu", .school),
            ("no-reply@greenhouse.io", .career),
            ("jobs@myworkday.com", .career),
            ("alerts@rbc.com", .finance),
            ("service@paypal.com", .finance),
        ]
        for (sender, expected) in cases {
            XCTAssertEqual(
                GoogleMailSource.inferredCategory(sender: sender, subject: "Hello"), expected,
                "\(sender) should read as \(expected)"
            )
        }
    }

    func testAnUnknownSenderStaysUnclassifiedRatherThanGuessed() {
        // Break caught: the inference becomes confident about mail it knows nothing about.
        // `nil` here becomes `.other`, which is the honest answer.
        XCTAssertNil(GoogleMailSource.inferredCategory(sender: "contact@example.test", subject: "Hi"))
        XCTAssertEqual(
            GoogleMailSource.category(for: try! summary(id: "m1", subject: "Hi", sender: "contact@example.test")),
            .other
        )
    }

    // MARK: - Gmail's own bucketing

    func testPromotionsSocialAndSpamAreBulkButUpdatesAreNot() {
        // CATEGORY_UPDATES holds receipts, course announcements and application status changes.
        // Treating it as bulk would hide exactly what this surface exists to find.
        XCTAssertTrue(GoogleMailSource.isBulk(labels: ["INBOX", "CATEGORY_PROMOTIONS"]))
        XCTAssertTrue(GoogleMailSource.isBulk(labels: ["CATEGORY_SOCIAL"]))
        XCTAssertTrue(GoogleMailSource.isBulk(labels: ["SPAM"]))
        XCTAssertFalse(GoogleMailSource.isBulk(labels: ["INBOX", "CATEGORY_UPDATES"]))
        XCTAssertFalse(GoogleMailSource.isBulk(labels: ["INBOX", "IMPORTANT"]))
    }

    func testUnreadIsReadFromTheProvidersOwnLabel() throws {
        let unread = GoogleMailSource.item(from: try summary(id: "m1", labels: ["INBOX", "UNREAD"]))
        XCTAssertTrue(unread.isUnread)
        let read = GoogleMailSource.item(from: try summary(id: "m2", labels: ["INBOX"]))
        XCTAssertFalse(read.isUnread)
    }

    func testTriageNeverRequestsAMessageBody() async throws {
        let s = try summary(id: "m1")
        var fake = FakeGmail(
            page: GmailMessagePage(
                messages: [
                    GmailMessageReference(
                        id: try GmailMessageID(validating: "m1"),
                        threadID: try GmailThreadID(validating: "thread-m1")
                    )
                ],
                nextPageToken: nil
            )
        )
        fake.records = ["m1": record(s)]

        _ = try await source(fake).mailItems(limit: 10)

        XCTAssertEqual(
            fake.calls.formats, [.metadata],
            "triage reads headers and a snippet — never the full body"
        )
    }

    func testOneUnreadableMessageDoesNotBlankTheInbox() async throws {
        let good = try summary(id: "m2", subject: "Readable")
        var fake = FakeGmail(
            page: GmailMessagePage(
                messages: [
                    GmailMessageReference(
                        id: try GmailMessageID(validating: "missing"),
                        threadID: try GmailThreadID(validating: "thread-missing")
                    ),
                    GmailMessageReference(
                        id: try GmailMessageID(validating: "m2"),
                        threadID: try GmailThreadID(validating: "thread-m2")
                    ),
                ],
                nextPageToken: nil
            )
        )
        fake.records = ["m2": record(good)]

        let items = try await source(fake).mailItems(limit: 10)

        XCTAssertEqual(items.map(\.title), ["Readable"])
    }

    func testNewestFirst() async throws {
        let older = try summary(id: "m1", subject: "Older", received: 1_757_000_000)
        let newer = try summary(id: "m2", subject: "Newer", received: 1_757_900_000)
        var fake = FakeGmail(
            page: GmailMessagePage(
                messages: [
                    GmailMessageReference(
                        id: try GmailMessageID(validating: "m1"),
                        threadID: try GmailThreadID(validating: "t1")
                    ),
                    GmailMessageReference(
                        id: try GmailMessageID(validating: "m2"),
                        threadID: try GmailThreadID(validating: "t2")
                    ),
                ],
                nextPageToken: nil
            )
        )
        fake.records = ["m1": record(older), "m2": record(newer)]

        let items = try await source(fake).mailItems(limit: 10)

        XCTAssertEqual(items.map(\.title), ["Newer", "Older"])
    }

    func testZeroLimitReadsNothing() async throws {
        let fake = FakeGmail(page: GmailMessagePage(messages: [], nextPageToken: nil))
        let items = try await source(fake).mailItems(limit: 0)

        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(fake.calls.messageCalls, 0)
    }

    // MARK: - The body, for display

    func testOpeningAMessageAsksGmailForTheFullFormatOnce() async throws {
        // The list stays on `.metadata`; only the message being looked at is fetched in full.
        let s = try summary(id: "m1")
        let fake = FakeGmail(
            page: GmailMessagePage(messages: [], nextPageToken: nil),
            records: ["m1": GmailMessageRecord(
                summary: s, bodyKind: .plainText, decodedBody: "Hello\r\n\r\n\r\nThere", attachments: []
            )]
        )
        let body = try await source(fake).body(for: "m1")

        XCTAssertEqual(fake.calls.formats, [.full])
        XCTAssertEqual(body.text, "Hello\n\nThere")
        XCTAssertFalse(body.isPrivate)
    }

    func testAnHTMLBodyIsShownAsTextWithoutItsStyleOrMarkup() throws {
        let s = try summary(id: "m1")
        let html = "<html><head><style>p{color:red}</style></head><body><p>Hi &amp; welcome</p>"
            + "<p>Due <b>Friday</b></p><script>alert(1)</script></body></html>"
        let body = GoogleMailSource.body(
            from: GmailMessageRecord(summary: s, bodyKind: .html, decodedBody: html, attachments: []),
            id: "m1"
        )
        XCTAssertEqual(body.text, "Hi & welcome\n\nDue Friday")
    }

    func testABodyTheDecoderCouldNotUnderstandIsWithheldNotGuessed() throws {
        // `.full` classifies an ambiguous MIME tree private. It must not render.
        let s = try summary(id: "m1", privacy: .private)
        let body = GoogleMailSource.body(
            from: GmailMessageRecord(summary: s, bodyKind: .unsupported, decodedBody: nil, attachments: [
                EmailAttachmentMetadata(filename: "invite.ics", mimeType: "text/calendar", size: 10),
            ]),
            id: "m1"
        )
        XCTAssertNil(body.text)
        XCTAssertTrue(body.isPrivate)
        XCTAssertEqual(body.attachmentNames, ["invite.ics"])
    }
}
