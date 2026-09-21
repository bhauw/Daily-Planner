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

    func testLabelsMapToCategoriesAndUnknownStaysOther() {
        XCTAssertEqual(GoogleMailSource.category(forLabels: ["Career"]), .career)
        XCTAssertEqual(GoogleMailSource.category(forLabels: ["INBOX", "school"]), .school)
        XCTAssertEqual(GoogleMailSource.category(forLabels: ["Work"]), .work)
        XCTAssertEqual(
            GoogleMailSource.category(forLabels: ["INBOX", "IMPORTANT"]), .other,
            "an unrecognised label must not be guessed into a planning category"
        )
        XCTAssertEqual(GoogleMailSource.category(forLabels: []), .other)
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
}
