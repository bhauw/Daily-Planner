import Foundation
import DailyPlannerDomain

/// Adapts the live Gmail read client to the planner's mail-triage port, so the Mail workbench
/// lists the user's real threads instead of synthetic drafts.
///
/// This round is **triage only**. No draft body is generated and nothing is sent: the source
/// holds read clients exclusively, and it never fetches a message body — `.metadata` format is
/// enough for sender, subject, snippet and labels, and asking for less is the cheaper and more
/// private choice.
public struct GoogleMailSource: PlannerMailReading, Sendable {
    private let client: any GmailReading
    private let tokens: any GoogleAccessTokenProviding
    /// How far back the triage list looks. Bounded so a long-dormant inbox cannot page forever.
    private let lookbackDays: Int

    public init(
        client: any GmailReading,
        tokens: any GoogleAccessTokenProviding,
        lookbackDays: Int = 7
    ) {
        self.client = client
        self.tokens = tokens
        self.lookbackDays = lookbackDays
    }

    public func mailItems(limit: Int) async throws -> [PlannerMailItem] {
        let token = try await tokens.accessToken()
        let since = Date().addingTimeInterval(-Double(lookbackDays) * 24 * 60 * 60)
        let capped = max(0, min(limit, GoogleSyncLimits.gmailMessages))
        guard capped > 0 else { return [] }

        let references = try await recentReferences(
            since: since, limit: capped, accessToken: token
        )

        var out: [PlannerMailItem] = []
        for reference in references {
            try Task.checkCancellation()
            // `.metadata` deliberately: triage needs headers and a snippet, never the body.
            guard let record = try? await client.message(
                id: reference.id, format: .metadata, accessToken: token
            ) else {
                // One unreadable message must not blank the whole inbox.
                continue
            }
            out.append(Self.item(from: record.summary))
        }
        return out.sorted { $0.receivedAt > $1.receivedAt }
    }

    // MARK: - Internals

    private func recentReferences(
        since: Date,
        limit: Int,
        accessToken: GoogleAccessToken
    ) async throws -> [GmailMessageReference] {
        var out: [GmailMessageReference] = []
        var pageToken: GmailPageToken?
        for _ in 0..<GoogleSyncLimits.gmailPages {
            try Task.checkCancellation()
            let page = try await client.messages(
                receivedAfter: since, pageToken: pageToken, accessToken: accessToken
            )
            out.append(contentsOf: page.messages)
            guard out.count < limit, let next = page.nextPageToken else { break }
            pageToken = next
        }
        return Array(out.prefix(limit))
    }

    /// Maps a message summary to a triage item, honouring the privacy classification M2A applies
    /// at decode time: a message classified `private` shows that it exists and who it is from,
    /// but its snippet is withheld rather than rendered.
    static func item(from summary: GmailMessageSummary) -> PlannerMailItem {
        let isPrivate = summary.privacyClass == .private
        return PlannerMailItem(
            // Opaque by design so it cannot be logged by accident; unwrapping here is the
            // sanctioned path. It becomes the row's identity for the loopback UI only.
            id: summary.id.withUnsafeRawValue { $0 },
            title: summary.subject,
            summary: isPrivate ? "Hidden — this message is marked private." : summary.snippet,
            sender: summary.sender,
            receivedAt: summary.receivedAt,
            category: category(forLabels: summary.labels),
            isPrivate: isPrivate,
            // Opaque by design, unwrapped here on the same sanctioned path as `id`. It goes no
            // further than the loopback UI and back to Gmail on a reply.
            threadID: summary.threadID.withUnsafeRawValue { $0 }
        )
    }

    /// Gmail labels are user-defined, so only an explicit match assigns a category. Anything
    /// unrecognised stays `.other` rather than being guessed into someone's planning.
    static func category(forLabels labels: [String]) -> PlannerCategory {
        for label in labels {
            switch label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "school", "classes", "academics": return .school
            case "career", "recruiting", "co-op", "coop", "jobs": return .career
            case "finance", "financials", "banking": return .finance
            case "personal": return .personal
            case "work": return .work
            default: continue
            }
        }
        return .other
    }
}
