import DailyPlannerDomain
import Foundation

/// Adapts the Gmail send client to the planner's sending port: resolve an access token, then
/// send. The same shape as `GoogleMailSource` on the read side.
///
/// One of these exists only when the connected grant actually permits sending. That is the
/// design: "this account cannot send" is represented by the absence of a sender, not by a
/// boolean someone could forget to check.
public struct GoogleMailSender: PlannerMailSending, Sendable {
    private let client: GmailSendClient
    private let tokens: any GoogleAccessTokenProviding

    public init(client: GmailSendClient, tokens: any GoogleAccessTokenProviding) {
        self.client = client
        self.tokens = tokens
    }

    public func send(_ mail: PlannerOutgoingMail) async throws -> PlannerSentMail {
        let token = try await tokens.accessToken()
        return try await client.send(mail, accessToken: token)
    }
}

/// Adapts the calendar write client to the planner's scheduling port.
public struct GoogleCalendarScheduler: PlannerEventScheduling, Sendable {
    private let client: GoogleCalendarWriteClient
    private let tokens: any GoogleAccessTokenProviding
    /// Where an event goes when the caller names no calendar. Nil means the account's primary.
    private let defaultCalendarID: CalendarID?

    public init(
        client: GoogleCalendarWriteClient,
        tokens: any GoogleAccessTokenProviding,
        defaultCalendarID: CalendarID? = nil
    ) {
        self.client = client
        self.tokens = tokens
        self.defaultCalendarID = defaultCalendarID
    }

    public func create(_ draft: PlannerEventDraft) async throws -> PlannerScheduledEvent {
        let token = try await tokens.accessToken()
        guard draft.calendarID == nil, let defaultCalendarID else {
            return try await client.create(draft, accessToken: token)
        }
        let resolved = try PlannerEventDraft(
            calendarID: defaultCalendarID,
            title: draft.title,
            start: draft.start,
            end: draft.end,
            location: draft.location,
            notes: draft.notes
        )
        return try await client.create(resolved, accessToken: token)
    }
}


/// Adapts the calendar write client to the planner's rescheduling port.
///
/// No default calendar here, deliberately. `GoogleCalendarScheduler` may fall back to a
/// configured calendar because a new event has to go somewhere; a move has nowhere to fall back
/// to, since the event is already on exactly one calendar and the caller read it from there.
public struct GoogleCalendarRescheduler: PlannerEventRescheduling, Sendable {
    private let client: GoogleCalendarWriteClient
    private let tokens: any GoogleAccessTokenProviding

    public init(client: GoogleCalendarWriteClient, tokens: any GoogleAccessTokenProviding) {
        self.client = client
        self.tokens = tokens
    }

    public func move(_ move: PlannerEventMove) async throws -> PlannerScheduledEvent {
        let token = try await tokens.accessToken()
        return try await client.move(move, accessToken: token)
    }
}
