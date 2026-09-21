import Foundation
import DailyPlannerDomain

// The wire contract for the loopback API. These DTOs are the ONLY types that cross the
// socket. Domain types (`PlannerEvent`, `PlanningPreview`, …) are deliberately not `Codable`,
// so every response is an explicit, reviewed shape. Nothing here carries a file path, a token,
// a vault identity, or an excluded-calendar identity — only the data the UI renders.

/// ISO8601 with a real offset (e.g. `2026-09-14T09:00:00-07:00`), formatted in the planner's
/// local zone so the dayline's time gutter reads in wall-clock terms. Kept separate from the
/// persistence JSON coders on purpose — this must never touch the on-disk envelope format.
enum APIDateFormat {
    static let timeZone = TimeZone(identifier: "America/Vancouver") ?? TimeZone(secondsFromGMT: 0)!

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Parses an ISO8601 instant with an offset — the same shape this contract emits. Returns
    /// nil rather than throwing so a bad timestamp becomes one finite `invalid_request`.
    static func parse(_ value: String) -> Date? {
        guard value.utf8.count <= 64 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: value) { return parsed }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

enum APICategory: String, Encodable, CaseIterable {
    case school, career, finance, personal, other, commute, work

    init(_ category: PlannerCategory) {
        switch category {
        case .school: self = .school
        case .career: self = .career
        case .finance: self = .finance
        case .personal: self = .personal
        case .other: self = .other
        // `commute` and `work` carry real scheduling meaning and must survive the wire:
        // a commute block means scheduling must NOT add its own travel buffer on top
        // (that double-counts), and work is a hard conflict like a class. Folding either
        // into `other` would silently discard that.
        case .commute: self = .commute
        case .work: self = .work
        }
    }
}

/// The contract's finite kind set. Domain `.task` items are scheduled blocks on the dayline,
/// so they surface here as `event`; tasks-as-list-items travel over `/api/tasks` instead.
enum APIKind: String, Encodable, CaseIterable {
    case event, deadline, extracurricular, advertisement

    init(_ kind: PlannerItemKind) {
        switch kind {
        case .event, .task: self = .event
        case .deadline: self = .deadline
        case .extracurricular: self = .extracurricular
        case .advertisement: self = .advertisement
        }
    }
}

struct PlannerEventDTO: Encodable {
    let id: String
    let title: String
    let category: APICategory
    let kind: APIKind
    let start: String
    let end: String?
    let due: String?
    let location: String?

    init(_ event: PlannerEvent) {
        id = event.id
        title = event.title
        category = APICategory(event.category)
        kind = APIKind(event.kind)
        start = APIDateFormat.iso8601(event.start)
        end = APIDateFormat.iso8601(event.end)
        due = event.due.map(APIDateFormat.iso8601)
        // The synthetic domain model has no location field this round.
        location = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, title, category, kind, start, end, due, location
    }

    // The contract declares `end`, `due`, and `location` as `string | null`: the keys must be
    // present on every event even when the value is nil. Swift's synthesized encoding uses
    // `encodeIfPresent` for optionals and would silently drop them, so encode explicitly —
    // `encode` on an Optional writes `null` — to keep the wire shape the React clients expect.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(category, forKey: .category)
        try container.encode(kind, forKey: .kind)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(due, forKey: .due)
        try container.encode(location, forKey: .location)
    }
}

struct PreviewResponse: Encodable {
    let queue: [PlannerEventDTO]
    let schedule: [PlannerEventDTO]
    let day: String
}

/// The days after today, so a digest can say what the week holds.
///
/// `/api/preview` is deliberately one local day — the planner's whole model is "today" — but a
/// day read in isolation is not a plan. This is the same eligible-event read over a wider
/// interval: still a GET, still read-only, still only calendars marked Planning.
struct WeekResponse: Encodable {
    /// First day covered, "YYYY-MM-DD" — today.
    let start: String
    /// How many days the window covers, today included.
    let days: Int
    /// Every eligible event in the window, in start order. Today's included, so a client can
    /// render the week without stitching two responses together.
    let events: [PlannerEventDTO]
}

/// The contract collapses the domain's `excludedReference` role to `excluded` on the wire.
enum APICalendarRole: String, Encodable, CaseIterable {
    case planning, excluded

    init(_ role: CalendarRole) {
        switch role {
        case .planning: self = .planning
        case .excludedReference: self = .excluded
        }
    }
}

struct CalendarDTO: Encodable {
    let id: String
    let title: String
    let role: APICalendarRole
}

struct CalendarsResponse: Encodable {
    let calendars: [CalendarDTO]
}

/// What this engine is currently allowed to do to the outside world.
///
/// Until the first write route shipped there was one value here and it said "Read-only · no
/// external writes". That was true, and the rail said it on every screen. It is no longer true
/// on a connection that granted send and schedule, so the rail must stop saying it — a safety
/// label that is merely reassuring, rather than accurate, is worse than none: it is the line the
/// user relies on to know what this app can do with their account.
///
/// Derived from the granted scopes, never from a local preference. A read-only grant still gets
/// the read-only label, and so does a disconnected app serving sample data.
struct SafetyDTO: Encodable {
    /// "read-only" | "send-and-schedule" — a finite set, mirrored by the client's union.
    let mode: String
    let externalWrites: Bool
    let label: String

    static let readOnly = SafetyDTO(
        mode: "read-only",
        externalWrites: false,
        label: "Read-only · no external writes"
    )

    /// Says both halves out loud: writes are possible, and none happens without the user.
    static let sendAndSchedule = SafetyDTO(
        mode: "send-and-schedule",
        externalWrites: true,
        label: "Send & schedule · nothing leaves without your confirmation"
    )

    static func forCapability(_ capability: GoogleGrantedCapability?) -> SafetyDTO {
        guard let capability, capability == .readWrite else { return .readOnly }
        return .sendAndSchedule
    }
}

/// What the UI is allowed to offer, straight from the grant.
///
/// The web client had to guess at this — `NO_WRITES` was hardcoded — so a row could offer
/// "Reply" against a token that cannot send, or hide it against one that can. Both are the same
/// bug: the button and the grant disagreeing. This is the single answer both sides read.
struct CapabilityDTO: Encodable {
    let canSend: Bool
    let canSchedule: Bool

    static let none = CapabilityDTO(canSend: false, canSchedule: false)

    init(canSend: Bool, canSchedule: Bool) {
        self.canSend = canSend
        self.canSchedule = canSchedule
    }

    init(_ capability: GoogleGrantedCapability?) {
        canSend = capability?.canSendMail ?? false
        canSchedule = capability?.canCreateEvents ?? false
    }
}

/// Which data the engine is actually serving.
///
/// The app always opens: when the Keychain read fails or no account is connected,
/// `EngineHost.makeLiveService` returns nil and the engine serves synthetic fixtures. That
/// fallback is correct — an app that refuses to open is worse — but until now it was *silent*,
/// so "Synthetic school task" rendered in the same chrome as real mail and the user had no way
/// to tell which day they were looking at. This is the signal that tells them.
struct SourceDTO: Encodable {
    /// "connected" | "sample" — a finite set, mirrored by the client's union.
    let kind: String
    /// True only when this is the user's real account. The client keys its warning off this
    /// rather than off `kind`, so a future third source is treated as not-live by default.
    let live: Bool
    let label: String

    static let connected = SourceDTO(
        kind: "connected",
        live: true,
        label: "Your Google account"
    )
    static let sample = SourceDTO(
        kind: "sample",
        live: false,
        label: "Sample data · not your account"
    )
}

struct SettingsResponse: Encodable {
    let vaultSelected: Bool
    let scanTimes: [String]
    let safety: SafetyDTO
    let source: SourceDTO
    /// What the connected grant permits. The client gates its write affordances on this.
    let capability: CapabilityDTO
}

struct HealthResponse: Encodable {
    let ok: Bool
    let mode: String

    static let readOnly = HealthResponse(ok: true, mode: SafetyDTO.readOnly.mode)

    init(ok: Bool, mode: String) {
        self.ok = ok
        self.mode = mode
    }

    /// Health reports the same mode string the safety rail shows, so the two can never drift.
    init(_ safety: SafetyDTO) {
        self.init(ok: true, mode: safety.mode)
    }
}

// MARK: - Synthetic-only surfaces (this round)

/// Mirrors the web client's `Draft` exactly. The previous shape shared only `id` with it —
/// it sent `subject`/`recipient`/`body`/`status`/`contextUsed`/`createdAt` while the client read
/// `title`/`summary`/`kind`, so every row in the Mail list rendered blank against the real
/// engine. The dev mock happened to send the client's shape, which is why it looked correct in
/// development and was broken in the shipped app.
struct DraftDTO: Encodable {
    let id: String
    let title: String
    let summary: String
    /// "reply" | "bundle" | "event" | "task" — the client's DraftKind.
    let kind: String
    /// Who it is from. Triage needs this; a generated draft would not have it.
    let sender: String?
    let category: APICategory?
    let receivedAt: String?
    /// The Gmail thread, so a reply composed from this row lands in the conversation it answers
    /// rather than starting a new one beside it. Opaque; the client only hands it back.
    let threadId: String?
}

struct DraftsResponse: Encodable {
    let drafts: [DraftDTO]
}

struct TaskDTO: Encodable {
    let id: String
    let title: String
    let category: APICategory
    /// A task carries a DATE, never a time-of-day — the time lives on the focus block that
    /// schedules it. Emitted as an instant at local start-of-day so the client cannot shift a
    /// day by parsing a bare "YYYY-MM-DD" as UTC midnight.
    let due: String?
    /// Required by the web contract (`TaskItem.done`). Its absence made every real task render
    /// as not-done, because the field simply arrived undefined.
    let done: Bool
    let estimateMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, category, due, done, estimateMinutes
    }

    // Same rule as `PlannerEventDTO`: the contract declares `due` as `string | null`, so the KEY
    // must be present on every task even when the value is nil. Swift's synthesized encoding
    // uses `encodeIfPresent` and dropped it, so a task with no due date arrived as `undefined`
    // rather than `null` — the client distinguishes "absent" from "null". `estimateMinutes` is
    // not part of the web contract, so it stays genuinely optional.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(category, forKey: .category)
        try container.encode(due, forKey: .due)
        try container.encode(done, forKey: .done)
        try container.encodeIfPresent(estimateMinutes, forKey: .estimateMinutes)
    }
}

struct TaskListDTO: Encodable {
    let name: String
    let items: [TaskDTO]
}

struct TasksResponse: Encodable {
    let lists: [TaskListDTO]
}

/// Every failure serializes to `{"error":{"code":<finite enum>,"message":<safe text>}}`.
/// Codes are a closed set; messages never carry provider content, paths, or identities.
enum APIErrorCode: String, Encodable, CaseIterable {
    case unauthorized
    case forbiddenOrigin = "forbidden_origin"
    case notFound = "not_found"
    case methodNotAllowed = "method_not_allowed"
    case unavailable
    /// The request did not fit in this server's budgets. Carries no size back.
    case tooLarge = "too_large"
    /// The body decoded but the content is not something we will send — a malformed address, an
    /// empty subject, an end before its start. The message names the field, never its value.
    case invalidRequest = "invalid_request"
    /// The connected grant does not permit this write, or no account is connected at all.
    case writeNotPermitted = "write_not_permitted"
    /// Google refused or could not be reached. Never carries the provider's own words.
    case providerRefused = "provider_refused"
}

struct APIErrorBody: Encodable {
    struct Payload: Encodable {
        let code: APIErrorCode
        let message: String
    }
    let error: Payload

    init(_ code: APIErrorCode, _ message: String) {
        error = Payload(code: code, message: message)
    }
}

enum APIJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func encode<T: Encodable>(_ value: T) -> Data {
        (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    /// Decodes a request body, or nil. The caller turns nil into one finite `invalid_request` —
    /// the decoding error itself is never surfaced, because `DecodingError` descriptions quote
    /// the offending value back, and here that value is the user's own mail.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Write routes

/// Every path this engine will accept a POST on. A finite, closed set, consulted by
/// `RequestGuard` (which verbs may reach which paths) and by `APIRouter` (what to do there),
/// so the two can never disagree about what is writable.
enum APIWriteRoute: String, CaseIterable {
    case sendMail = "/api/mail/send"
    case createEvent = "/api/calendar/events"

    static func matching(_ path: String) -> APIWriteRoute? {
        APIWriteRoute(rawValue: path)
    }
}

/// A message the user composed and asked to send. Decoded, then validated in the domain —
/// nothing here is trusted enough to hand to Gmail as-is.
struct SendMailRequest: Decodable {
    let to: [String]
    let cc: [String]?
    let bcc: [String]?
    let subject: String
    let body: String
    /// The Gmail thread this reply belongs to, when the composer was opened from a mail row.
    let threadID: String?
    /// RFC 2822 `Message-ID` of the message being answered, so Gmail threads the reply properly
    /// instead of starting a new conversation beside it.
    let inReplyTo: String?

    enum CodingKeys: String, CodingKey {
        case to, cc, bcc, subject, body
        case threadID = "threadId"
        case inReplyTo
    }
}

struct SendMailResponse: Encodable {
    let ok: Bool
    /// Gmail's id for the sent message. Opaque; shown to no one, used to confirm it landed.
    let id: String
    let threadId: String?
}

/// An event the user asked to put on the calendar.
struct CreateEventRequest: Decodable {
    /// Which calendar to write to. Absent means the account's primary calendar.
    let calendarID: String?
    let title: String
    /// ISO8601 with an offset, as the rest of this contract uses.
    let start: String
    let end: String
    let location: String?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case calendarID = "calendarId"
        case title, start, end, location, description
    }
}

struct CreateEventResponse: Encodable {
    let ok: Bool
    let id: String
    let start: String
    let end: String
    /// Google's own link to the created event, when it returns one.
    let htmlLink: String?
}

/// Why a write did not happen, in the finite terms the client understands.
///
/// Every case renders a response whose message is safe to show and carries none of what the user
/// typed. A validation message names the field to fix; a provider failure says which side of the
/// wire gave up. Neither ever quotes a recipient, a subject or a provider's own error text.
enum APIWriteFailure: Error {
    /// No connected grant permits this. The route exists; the ability does not.
    case notPermitted
    /// The request decoded but is not something we will send. The string is display text.
    case invalid(String)
    /// Google said no. The user usually has to do something — reconnect, fix a recipient.
    case providerRefused
    /// It did not get through. Later may work.
    case providerUnavailable

    var response: HTTPResponse {
        switch self {
        case .notPermitted:
            return .error(
                403, "Forbidden", .writeNotPermitted,
                "This account is connected for reading only. Reconnect to enable sending and scheduling."
            )
        case .invalid(let message):
            return .error(400, "Bad Request", .invalidRequest, message)
        case .providerRefused:
            return .error(
                502, "Bad Gateway", .providerRefused,
                "Google would not accept that. Check the details, or reconnect the account."
            )
        case .providerUnavailable:
            return .error(
                503, "Service Unavailable", .unavailable,
                "Could not reach Google. Nothing was sent."
            )
        }
    }

    /// A short, finite sentence per validation failure. Says what to fix without repeating the
    /// value that failed — the value here is someone's mail.
    static func message(for error: PlannerWriteError) -> String {
        switch error {
        case .invalidRecipient:
            return "Check the recipient address."
        case .headerInjection:
            return "A line break is not allowed in an address or a subject."
        case .emptySubject:
            return "Add a subject."
        case .emptyBody:
            return "Write a message first."
        case .tooLarge:
            return "That is longer than this app will send."
        case .invalidTitle:
            return "Give the event a title."
        case .invalidInterval:
            return "The end time has to be after the start time."
        case .invalidIdentifier:
            return "That conversation could not be identified."
        }
    }

    /// Classifies a provider error without knowing which provider it came from.
    static func provider(_ error: Error) -> APIWriteFailure {
        guard let failure = error as? any PlannerWriteFailure else { return .providerUnavailable }
        switch failure.writeOutcome {
        case .refused: return .providerRefused
        case .unavailable, .cancelled: return .providerUnavailable
        }
    }

    /// A finite label for the unified log. Never the message, never the content.
    var logLabel: StaticString {
        switch self {
        case .notPermitted: return "not-permitted"
        case .invalid: return "invalid-request"
        case .providerRefused: return "provider-refused"
        case .providerUnavailable: return "provider-unavailable"
        }
    }
}
