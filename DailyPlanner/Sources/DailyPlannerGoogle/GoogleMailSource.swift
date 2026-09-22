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
    fileprivate let client: any GmailReading
    fileprivate let tokens: any GoogleAccessTokenProviding
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
            category: category(for: summary),
            isPrivate: isPrivate,
            isUnread: summary.labels.contains { $0.uppercased() == "UNREAD" },
            isBulk: isBulk(labels: summary.labels),
            // Opaque by design, unwrapped here on the same sanctioned path as `id`. It goes no
            // further than the loopback UI and back to Gmail on a reply.
            threadID: summary.threadID.withUnsafeRawValue { $0 }
        )
    }

    /// Gmail's own bucketing. These are system labels, not user ones, so matching them exactly
    /// is safe in a way that matching a user's label text is not.
    ///
    /// `CATEGORY_UPDATES` is deliberately NOT here. Gmail files a great deal of real mail under
    /// it — receipts, course announcements, application status changes — and hiding that would
    /// lose exactly the messages this surface exists to find.
    static func isBulk(labels: [String]) -> Bool {
        let bulk: Set<String> = ["SPAM", "CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "TRASH"]
        return labels.contains { bulk.contains($0.uppercased()) }
    }

    /// What a message is about.
    ///
    /// A user label wins when there is one — an explicit choice always outranks a guess. Almost
    /// no inbox is fully labelled, though, and the previous behaviour was to call everything
    /// `.other`, which collapsed the whole priority order into one undifferentiated pile. So
    /// when there is no label, the sender and the subject are read for a small number of high
    /// confidence signals.
    ///
    /// The signals are deliberately few. Each one is something that is almost never a
    /// coincidence; a longer list would classify more mail and be wrong about more of it, and
    /// being wrong here means burying a midterm notice under a newsletter.
    static func category(for summary: GmailMessageSummary) -> PlannerCategory {
        if let labelled = category(forLabels: summary.labels) { return labelled }
        if let inferred = inferredCategory(sender: summary.sender, subject: summary.subject) {
            return inferred
        }
        return .other
    }

    /// An explicit user label, or nil when none of them says anything.
    static func category(forLabels labels: [String]) -> PlannerCategory? {
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
        return nil
    }

    static func inferredCategory(sender: String, subject: String) -> PlannerCategory? {
        let from = sender.lowercased()
        let text = MailTriagePolicy.normalized(subject)

        // A course code in the subject — "ECONOMICS 250", "ECONOMICS 295", "INDG 101". This is the
        // strongest signal on a student's inbox and it needs no list of institutions.
        if containsCourseCode(subject) { return .school }

        // Institutional senders. `.edu` plus the Canadian universities' own domains, since a
        // `.ca` university does not use `.edu`.
        let schoolHosts = ["sfu.ca", "university.example", "bcit.ca", "ufv.ca", "douglascollege.ca",
                           "langara.ca", "kpu.ca", "instructure.com", "canvaslms.com"]
        if from.contains(".edu") || schoolHosts.contains(where: from.contains) { return .school }

        let careerHosts = ["greenhouse.io", "lever.co", "myworkday.com", "workday.com",
                           "smartrecruiters.com", "icims.com", "taleo.net", "linkedin.com",
                           "indeed.com", "handshake.com", "joinhandshake.com"]
        if careerHosts.contains(where: from.contains) { return .career }

        let financeHosts = ["rbc.com", "td.com", "scotiabank.com", "cibc.com", "bmo.com",
                            "tangerine.ca", "wealthsimple.com", "questrade.com", "paypal.com",
                            "cra-arc.gc.ca", "interac.ca"]
        if financeHosts.contains(where: from.contains) { return .finance }

        // Subject-side fallbacks, whole-word matched through the triage normaliser.
        for phrase in ["application", "internship", "co op", "coop", "recruiting", "offer letter"]
        where MailTriagePolicy.contains(text, phrase) {
            return .career
        }
        for phrase in ["tuition", "invoice", "statement", "receipt", "payment"]
        where MailTriagePolicy.contains(text, phrase) {
            return .finance
        }
        return nil
    }

    /// Two to four letters, a space or not, then exactly three digits: "ECONOMICS 250", "COMM295".
    /// Requires the letters to be upper-case, which is how course codes are written and which
    /// keeps it from firing on ordinary prose.
    static func containsCourseCode(_ subject: String) -> Bool {
        let scalars = Array(subject.unicodeScalars)
        var index = 0
        while index < scalars.count {
            guard CharacterSet.uppercaseLetters.contains(scalars[index]),
                  index == 0 || !CharacterSet.alphanumerics.contains(scalars[index - 1]) else {
                index += 1
                continue
            }
            var cursor = index
            var letters = 0
            while cursor < scalars.count, CharacterSet.uppercaseLetters.contains(scalars[cursor]) {
                letters += 1
                cursor += 1
            }
            guard (2...4).contains(letters) else { index = cursor + 1; continue }
            if cursor < scalars.count, scalars[cursor] == " " { cursor += 1 }
            var digits = 0
            while cursor < scalars.count, CharacterSet.decimalDigits.contains(scalars[cursor]) {
                digits += 1
                cursor += 1
            }
            let ends = cursor >= scalars.count || !CharacterSet.alphanumerics.contains(scalars[cursor])
            if digits == 3, ends { return true }
            index = max(cursor, index + 1)
        }
        return false
    }
}

// MARK: - The body, for display

/// Reading one message in full, when he opens it.
///
/// The triage list above stays on `.metadata` — a list of twenty-five rows has no business
/// downloading twenty-five bodies. This is one message, fetched when it is looked at, on the
/// `gmail.readonly` grant the list already uses.
///
/// The MIME walk and the base64url decode are `GmailReadClient`'s, which already bounds both and
/// fails closed on a shape it does not understand. This only picks what to show from its result.
extension GoogleMailSource: PlannerMailBodyReading {
    public func body(for id: String) async throws -> PlannerMailBody {
        let messageID = try GmailMessageID(validating: id)
        let token = try await tokens.accessToken()
        let record = try await client.message(id: messageID, format: .full, accessToken: token)
        return Self.body(from: record, id: id)
    }

    static func body(from record: GmailMessageRecord, id: String) -> PlannerMailBody {
        let text: String?
        switch (record.bodyKind, record.decodedBody) {
        case let (.plainText, body?): text = PlannerMailText.fromPlain(body)
        case let (.html, body?): text = PlannerMailText.fromHTML(body)
        default: text = nil
        }
        return PlannerMailBody(
            id: id,
            subject: record.summary.subject,
            sender: record.summary.sender,
            text: text,
            attachmentNames: record.attachments.map(\.filename),
            isPrivate: record.summary.privacyClass == .private
        )
    }
}
