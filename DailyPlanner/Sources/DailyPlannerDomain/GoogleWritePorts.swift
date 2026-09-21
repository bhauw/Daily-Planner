import Foundation

/// The two things this app will ever write to someone's Google account: a message it sends, and
/// an event it puts on a calendar. Both are values validated *here*, in the domain, before any
/// client sees them — a write is the one operation you cannot take back, so the checks belong
/// where they can be read and tested on their own, not scattered through a request builder.
///
/// Nothing in this file talks to a network.

/// How a failed write should be reported to the person who pressed Send.
///
/// The API layer must tell "Google said no" from "it did not get through", because the first is
/// something the user can act on and the second is something to try again — but it does not
/// import the Google module and must not learn its error types to do it. Every error a write
/// port can throw carries this instead.
public enum PlannerWriteOutcome: Equatable, Sendable {
    /// The provider refused: a revoked grant, a rejected recipient, a quota. Not a retry.
    case refused
    /// It did not arrive. Later may work.
    case unavailable
    case cancelled
}

public protocol PlannerWriteFailure: Error {
    var writeOutcome: PlannerWriteOutcome { get }
}

public enum PlannerWriteError: Error, Equatable, CaseIterable, Sendable {
    /// No recipient, or one that is not an address.
    case invalidRecipient
    /// A subject or address carrying a line break. See `PlannerMailAddress` for why this is its
    /// own case rather than a generic validation failure.
    case headerInjection
    case emptySubject
    case emptyBody
    case tooLarge
    case invalidTitle
    /// End is not strictly after start, or the span is longer than this app will ever schedule.
    case invalidInterval
    case invalidIdentifier
}

/// One validated email address.
///
/// The rule that earns its keep is the CR/LF refusal. An address (or a subject) is written
/// verbatim into a header line of an RFC 2822 message; a newline inside one ends that header and
/// begins another, so `a@b.com\r\nBcc: everyone@example.com` is not a weird address, it is a
/// second header the user never wrote. Refusing the character is the whole defence, and it has
/// to happen before the message is assembled.
///
/// The syntax check is deliberately conservative rather than RFC-complete: it accepts the
/// addresses people actually type and refuses anything it cannot be sure of. A false refusal is
/// a visible error the user can correct; a false accept is mail sent somewhere unintended.
public struct PlannerMailAddress: Hashable, Sendable {
    public let value: String

    public init(validating raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !Self.containsLineBreak(trimmed) else { throw PlannerWriteError.headerInjection }
        guard (3...254).contains(trimmed.utf8.count) else { throw PlannerWriteError.invalidRecipient }
        guard !trimmed.unicodeScalars.contains(where: Self.isForbidden) else {
            throw PlannerWriteError.invalidRecipient
        }

        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw PlannerWriteError.invalidRecipient }
        let local = parts[0]
        let domain = parts[1]
        guard !local.isEmpty, local.utf8.count <= 64 else { throw PlannerWriteError.invalidRecipient }
        guard !domain.isEmpty, domain.contains("."),
              !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains("..") else {
            throw PlannerWriteError.invalidRecipient
        }

        value = trimmed
    }

    static func containsLineBreak(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0 == "\r" || $0 == "\n" }
    }

    /// Characters that either structure a header list or have no business in a bare address.
    private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.controlCharacters.contains(scalar)
            || " <>,;\"\\()[]".unicodeScalars.contains(scalar)
    }
}

/// A message the user wrote and asked to send. Validated on construction; by the time one of
/// these exists, it is safe to render into a header block.
public struct PlannerOutgoingMail: Hashable, Sendable {
    public let to: [PlannerMailAddress]
    public let cc: [PlannerMailAddress]
    public let bcc: [PlannerMailAddress]
    public let subject: String
    public let body: String
    /// The provider thread this belongs to, when replying. Opaque.
    public let threadID: String?
    /// The RFC 2822 `Message-ID` being answered, so the reply threads instead of landing beside
    /// the conversation it belongs to.
    public let inReplyTo: String?

    /// The most recipients one message may carry. A daily planner sends replies, not campaigns;
    /// a bound here is what keeps a slip in the composer from becoming a mass mail.
    public static let maxRecipients = 25
    /// RFC 2822 caps an unfolded header line at 998 octets. The subject is encoded before it is
    /// written, so this is a bound on intent rather than on bytes, but it is the right shape.
    public static let maxSubjectBytes = 512
    public static let maxBodyBytes = 64 * 1024

    public init(
        to: [String],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String,
        body: String,
        threadID: String? = nil,
        inReplyTo: String? = nil
    ) throws {
        let toAddresses = try to.map(PlannerMailAddress.init(validating:))
        let ccAddresses = try cc.map(PlannerMailAddress.init(validating:))
        let bccAddresses = try bcc.map(PlannerMailAddress.init(validating:))
        guard !toAddresses.isEmpty else { throw PlannerWriteError.invalidRecipient }
        guard toAddresses.count + ccAddresses.count + bccAddresses.count <= Self.maxRecipients else {
            throw PlannerWriteError.tooLarge
        }

        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !PlannerMailAddress.containsLineBreak(subject) else { throw PlannerWriteError.headerInjection }
        guard !trimmedSubject.isEmpty else { throw PlannerWriteError.emptySubject }
        guard trimmedSubject.utf8.count <= Self.maxSubjectBytes else { throw PlannerWriteError.tooLarge }

        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlannerWriteError.emptyBody
        }
        guard body.utf8.count <= Self.maxBodyBytes else { throw PlannerWriteError.tooLarge }

        self.to = toAddresses
        self.cc = ccAddresses
        self.bcc = bccAddresses
        self.subject = trimmedSubject
        self.body = body
        self.threadID = try threadID.map(Self.validatedIdentifier)
        // A Message-ID is angle-bracketed by convention, so it cannot go through the address
        // validator — but it lands in a header line just the same, so the line-break rule holds.
        self.inReplyTo = try inReplyTo.map(Self.validatedHeaderValue)
    }

    static func validatedIdentifier(_ raw: String) throws -> String {
        guard !raw.isEmpty, raw.utf8.count <= 1_024,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == "/" || $0 == "\\" || $0 == "%" }) else {
            throw PlannerWriteError.invalidIdentifier
        }
        return raw
    }

    static func validatedHeaderValue(_ raw: String) throws -> String {
        guard !PlannerMailAddress.containsLineBreak(raw) else { throw PlannerWriteError.headerInjection }
        guard !raw.isEmpty, raw.utf8.count <= 998,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PlannerWriteError.invalidIdentifier
        }
        return raw
    }
}

/// What came back after a message was accepted by the provider.
public struct PlannerSentMail: Hashable, Sendable {
    public let id: String
    public let threadID: String?

    public init(id: String, threadID: String?) {
        self.id = id
        self.threadID = threadID
    }
}

/// Sends one message. Implemented over Gmail in production; absent entirely when the connected
/// grant is read-only, which is what makes "cannot send" a structural fact rather than a flag.
public protocol PlannerMailSending: Sendable {
    func send(_ mail: PlannerOutgoingMail) async throws -> PlannerSentMail
}

// MARK: - Scheduling

/// An event the user asked to put on a calendar.
public struct PlannerEventDraft: Hashable, Sendable {
    public let calendarID: CalendarID?
    public let title: String
    public let start: Date
    public let end: Date
    public let location: String?
    public let notes: String?

    public static let maxTitleBytes = 512
    public static let maxNotesBytes = 8 * 1024
    /// The longest span this app will create. A planner schedules hours, not seasons; a wrong
    /// year in a date field would otherwise write a multi-decade block onto a real calendar.
    public static let maxDuration: TimeInterval = 30 * 24 * 60 * 60

    public init(
        calendarID: CalendarID? = nil,
        title: String,
        start: Date,
        end: Date,
        location: String? = nil,
        notes: String? = nil
    ) throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, trimmedTitle.utf8.count <= Self.maxTitleBytes else {
            throw PlannerWriteError.invalidTitle
        }
        guard end > start, end.timeIntervalSince(start) <= Self.maxDuration else {
            throw PlannerWriteError.invalidInterval
        }
        if let location, location.utf8.count > Self.maxTitleBytes { throw PlannerWriteError.tooLarge }
        if let notes, notes.utf8.count > Self.maxNotesBytes { throw PlannerWriteError.tooLarge }

        self.calendarID = calendarID
        self.title = trimmedTitle
        self.start = start
        self.end = end
        self.location = location?.isEmpty == true ? nil : location
        self.notes = notes?.isEmpty == true ? nil : notes
    }
}

public struct PlannerScheduledEvent: Hashable, Sendable {
    public let id: String
    public let start: Date
    public let end: Date
    /// Google's own link to the event, when it returns one.
    public let link: String?

    public init(id: String, start: Date, end: Date, link: String?) {
        self.id = id
        self.start = start
        self.end = end
        self.link = link
    }
}

/// Creates one calendar event. Absent when the grant cannot create events.
public protocol PlannerEventScheduling: Sendable {
    func create(_ draft: PlannerEventDraft) async throws -> PlannerScheduledEvent
}

extension PlannerWriteError: PlannerWriteFailure {
    /// Every case here is the message itself being wrong, which no amount of retrying fixes.
    public var writeOutcome: PlannerWriteOutcome { .refused }
}
