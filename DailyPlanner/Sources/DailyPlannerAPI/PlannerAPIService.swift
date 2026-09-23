import Foundation
import DailyPlannerApplication
import DailyPlannerDomain
import DailyPlannerPlatform

/// Produces the JSON body for each read-only route by reusing the existing planning workflows
/// over the synthetic calendar source. It re-implements no planning logic: `/api/preview` and
/// `/api/calendars` come straight from `PlanningPreviewWorkflow` / `CalendarRoleWorkflow`.
public struct PlannerAPIService: Sendable {
    private let planning: PlanningPreviewWorkflow
    private let roles: CalendarRoleWorkflow
    private let settingsReader: any PrivateSettingsReading
    /// Live task lists when an account is connected; nil falls back to synthetic content.
    private let taskReader: (any PlannerTaskListReading)?
    /// Live inbox triage when an account is connected; nil falls back to synthetic content.
    private let mailReader: (any PlannerMailReading)?
    /// Sends mail, when the connected grant permits it. Nil is not a disabled feature flag — it
    /// is the absence of any way to send at all, which is why `/api/mail/send` cannot be made to
    /// write by fiddling with a boolean somewhere.
    private let mailSender: (any PlannerMailSending)?
    /// Creates calendar events, on the same terms.
    private let eventScheduler: (any PlannerEventScheduling)?
    /// Moves events that already exist, on the same terms. Separate from `eventScheduler`
    /// because creating and editing are separate permissions to reason about.
    private let eventRescheduler: (any PlannerEventRescheduling)?
    /// Proposes replies. Nil when no assistant is wired, which is what makes "this app cannot
    /// generate" structural rather than a setting. Independent of the Google grant.
    private let replyWriter: (any PlannerReplyDrafting)?
    /// Fetches one message's body for display. Local only — see `MailBodyPorts.swift`.
    private let mailBodyReader: (any PlannerMailBodyReading)?
    /// Summarises a body, which sends it off the machine. Nil with no assistant.
    private let summarizer: (any PlannerMailSummarizing)?
    /// Decides whether a body reads as sensitive enough never to be sent to a model.
    private let contentClassifier: any GoogleContentClassifying
    /// The user's own first name, for signing drafted replies. Nil signs off without one.
    private let signOffName: String?
    /// What the connected grant permits. Nil when no account is connected.
    private let capability: GoogleGrantedCapability?
    private let schedulePolicy: LocalSchedulePolicy
    /// Which data this service is serving, decided by which initialiser built it. Reported on
    /// `/api/settings` so the UI can say so out loud instead of presenting fixtures as the
    /// user's real day.
    private let source: SourceDTO
    /// The clock the day boundary is read from on every request.
    ///
    /// Stored instead of a `DateInterval` frozen at construction: this is a daily driver that
    /// stays open, and a launch-time interval meant an app left running overnight kept serving
    /// yesterday — the Today header still read "Tuesday, Sep 15" on the 16th — until it was
    /// quit and relaunched. The synthetic path passes a `FixedClock`, so it stays deterministic.
    private let clock: any PlannerClock

    /// The local day being planned, recomputed per request so midnight rolls over on its own.
    private var interval: DateInterval { schedulePolicy.localDayInterval(containing: clock.now) }
    private var referenceDay: Date { clock.now }

    /// Builds the service against the synthetic source for the given instant. The planning role
    /// is seeded onto the source's planning calendar so the preview is non-empty. This is the
    /// fallback used until a Google account is connected.
    public init(referenceDate: Date) {
        let source = M1SyntheticCalendarSource(referenceDate: referenceDate)
        let seeded = SyntheticPlanningSettings(
            planningCalendarIDs: [CalendarID(rawValue: "synthetic-school-demo")]
        )
        self.planning = PlanningPreviewWorkflow(
            catalogReader: source,
            planningReader: source,
            settingsReader: seeded,
            clock: FixedClock(referenceDate)
        )
        self.roles = CalendarRoleWorkflow(settingsStore: seeded, catalogReader: source)
        self.settingsReader = seeded
        self.taskReader = nil
        self.mailReader = nil
        // Sample data never writes anywhere. There is nothing to write to.
        self.mailSender = nil
        self.eventScheduler = nil
        self.eventRescheduler = nil
        // Sample data is not anybody's mail, so there is nothing to draft against.
        self.replyWriter = nil
        self.mailBodyReader = nil
        self.summarizer = nil
        self.contentClassifier = DeterministicGoogleContentPrivacyClassifier()
        self.signOffName = nil
        self.capability = nil
        self.schedulePolicy = LocalSchedulePolicy.v1
        self.clock = FixedClock(referenceDate)
        self.source = .sample
    }

    /// Builds the service against a live source — in practice `GoogleCalendarSource` over the
    /// connected account — and the real encrypted settings store. Calendar roles come from the
    /// user's persisted assignments, so an Excluded reference calendar contributes nothing to
    /// planning exactly as it does in the synthetic path.
    ///
    /// Reads are unconditional; writes exist only if `mailSender` / `eventScheduler` were built,
    /// which the composition root does only for a grant that actually carries the scopes.
    ///
    /// The day being planned comes from `clock` on every request rather than from a date fixed
    /// here, so a long-running app rolls over at midnight on its own.
    public init(
        source: any CalendarCatalogReading & PlanningCalendarReading,
        settingsStore: any PrivateSettingsStore,
        clock: any PlannerClock,
        taskReader: (any PlannerTaskListReading)? = nil,
        mailReader: (any PlannerMailReading)? = nil,
        mailSender: (any PlannerMailSending)? = nil,
        eventScheduler: (any PlannerEventScheduling)? = nil,
        eventRescheduler: (any PlannerEventRescheduling)? = nil,
        replyWriter: (any PlannerReplyDrafting)? = nil,
        mailBodyReader: (any PlannerMailBodyReading)? = nil,
        summarizer: (any PlannerMailSummarizing)? = nil,
        contentClassifier: any GoogleContentClassifying = DeterministicGoogleContentPrivacyClassifier(),
        signOffName: String? = nil,
        capability: GoogleGrantedCapability? = nil
    ) {
        self.planning = PlanningPreviewWorkflow(
            catalogReader: source,
            planningReader: source,
            settingsReader: settingsStore,
            clock: clock
        )
        self.roles = CalendarRoleWorkflow(settingsStore: settingsStore, catalogReader: source)
        self.settingsReader = settingsStore
        self.taskReader = taskReader
        self.mailReader = mailReader
        self.mailSender = mailSender
        self.eventScheduler = eventScheduler
        self.eventRescheduler = eventRescheduler
        self.replyWriter = replyWriter
        self.mailBodyReader = mailBodyReader
        self.summarizer = summarizer
        self.contentClassifier = contentClassifier
        self.signOffName = signOffName
        self.capability = capability
        self.schedulePolicy = LocalSchedulePolicy.v1
        self.clock = clock
        self.source = .connected
    }

    /// What this engine may do to the outside world right now, from the grant and nothing else.
    private var safety: SafetyDTO { .forCapability(capability) }

    func health() -> Data {
        APIJSON.encode(HealthResponse(safety))
    }

    func preview() async throws -> Data {
        let preview = try await planning.refresh(interval: interval)
        let response = PreviewResponse(
            queue: preview.queue.map(PlannerEventDTO.init),
            schedule: preview.schedule.map(PlannerEventDTO.init),
            day: APIDateFormat.day(interval.start)
        )
        return APIJSON.encode(response)
    }

    /// How far ahead the week view looks, today included.
    static let weekDayCount = 7

    func week() async throws -> Data {
        let start = interval.start
        guard let end = Calendar.current.date(byAdding: .day, value: Self.weekDayCount, to: start) else {
            // A calendar that cannot add seven days is not a condition we can serve through.
            throw PlanningWorkflowError.planningReadUnavailable
        }
        let preview = try await planning.refresh(interval: DateInterval(start: start, end: end))
        let response = WeekResponse(
            start: APIDateFormat.day(start),
            days: Self.weekDayCount,
            // `schedule` is the eligible set in start order, which is exactly the week's shape.
            events: preview.schedule.map(PlannerEventDTO.init)
        )
        return APIJSON.encode(response)
    }

    func calendars() async throws -> Data {
        let rows = try await roles.rows()
        let response = CalendarsResponse(
            calendars: rows.map { row in
                CalendarDTO(
                    id: row.calendarID.rawValue,
                    title: row.displayName,
                    role: APICalendarRole(row.role)
                )
            }
        )
        return APIJSON.encode(response)
    }

    func settingsPayload() -> Data {
        let scanTimes = (try? schedulePolicy.scanSlots(on: interval.start)) ?? []
        let response = SettingsResponse(
            vaultSelected: (try? settingsReader.load())?.vaultBookmark != nil,
            scanTimes: scanTimes.map(APIDateFormat.iso8601),
            safety: safety,
            source: source,
            // Reported from what was actually built, not from the stored capability alone: if a
            // sender could not be constructed for any reason, the UI must not offer to send.
            capability: CapabilityDTO(
                canSend: mailSender != nil,
                canSchedule: eventScheduler != nil,
                canReschedule: eventRescheduler != nil,
                canDraft: replyWriter != nil,
                canReadBody: mailBodyReader != nil,
                canSummarize: mailBodyReader != nil && summarizer != nil
            ),
            // Read off the provider itself rather than assumed. A local-model adapter answers
            // `contentLeavesMachine = false` and the rail changes on its own.
            assist: replyWriter.map {
                AssistDTO.forProvider($0.providerLabel, contentLeavesMachine: $0.contentLeavesMachine)
            } ?? .off
        )
        return APIJSON.encode(response)
    }

    /// Real inbox triage when an account is connected, synthetic content otherwise. This round
    /// surfaces threads that may need a reply — it never generates a draft body and nothing
    /// sends. A failure reading the inbox falls back to synthetic rather than erroring the whole
    /// surface, so the rest of the day stays usable.
    func drafts() async -> Data {
        guard let mailReader,
              let items = try? await mailReader.mailItems(limit: Self.triageLimit) else {
            return APIJSON.encode(
                DraftsResponse(drafts: SyntheticContent.drafts(referenceDay: referenceDay))
            )
        }
        // Ranked here, once, by the rule in the domain — see `MailTriagePolicy` for the order
        // and for why recency is the last key rather than the first.
        let triaged = MailTriagePolicy.triage(items)
        let payload = triaged.entries.map { entry in
            DraftDTO(
                id: entry.item.id,
                title: entry.item.title,
                summary: entry.item.summary,
                kind: "reply",
                sender: entry.item.sender,
                category: APICategory(entry.item.category),
                receivedAt: APIDateFormat.iso8601(entry.item.receivedAt),
                threadId: entry.item.threadID,
                band: entry.band.wireName,
                reason: entry.reason.rawValue,
                why: entry.why,
                unread: entry.item.isUnread
            )
        }
        return APIJSON.encode(
            DraftsResponse(drafts: payload, hiddenCount: triaged.hiddenCount)
        )
    }

    /// How many inbox rows the triage list shows. Small on purpose: this is a review queue, not
    /// a mail client.
    private static let triageLimit = 25

    /// Real Google Tasks when an account is connected, synthetic content otherwise. A failure
    /// reading the live lists falls back to synthetic rather than erroring the whole surface —
    /// the day is still usable if only tasks are unavailable.
    func tasks() async -> Data {
        guard let taskReader, let lists = try? await taskReader.taskLists() else {
            return APIJSON.encode(
                TasksResponse(lists: SyntheticContent.taskLists(referenceDay: referenceDay))
            )
        }
        let payload = lists.map { list in
            TaskListDTO(
                name: list.name,
                items: list.items.map { item in
                    TaskDTO(
                        id: item.id,
                        title: item.title,
                        category: APICategory(item.category),
                        due: item.due.map(APIDateFormat.iso8601),
                        done: item.isCompleted,
                        // Google Tasks has no duration field; the planner never invents one.
                        estimateMinutes: nil
                    )
                }
            )
        }
        return APIJSON.encode(TasksResponse(lists: payload))
    }

    // MARK: - Writes

    /// Sends one message the user composed and confirmed.
    ///
    /// Three gates, in order, and each refuses for a different reason the user can act on:
    /// there is no sender at all (the grant does not allow it), the body is not a message we
    /// will send (validated in the domain), or Google refused it. Nothing here retries — a send
    /// that may or may not have happened must not be attempted twice on the user's behalf.
    func sendMail(_ body: Data) async throws -> Data {
        guard let mailSender else { throw APIWriteFailure.notPermitted }
        guard let request = APIJSON.decode(SendMailRequest.self, from: body) else {
            throw APIWriteFailure.invalid("That message could not be read.")
        }
        let mail: PlannerOutgoingMail
        do {
            mail = try PlannerOutgoingMail(
                to: request.to,
                cc: request.cc ?? [],
                bcc: request.bcc ?? [],
                subject: request.subject,
                body: request.body,
                threadID: request.threadID,
                inReplyTo: request.inReplyTo
            )
        } catch let error as PlannerWriteError {
            throw APIWriteFailure.invalid(APIWriteFailure.message(for: error))
        }

        do {
            let sent = try await mailSender.send(mail)
            return APIJSON.encode(
                SendMailResponse(ok: true, id: sent.id, threadId: sent.threadID)
            )
        } catch {
            throw APIWriteFailure.provider(error)
        }
    }

    /// Puts one event on the calendar.
    func createEvent(_ body: Data) async throws -> Data {
        guard let eventScheduler else { throw APIWriteFailure.notPermitted }
        guard let request = APIJSON.decode(CreateEventRequest.self, from: body) else {
            throw APIWriteFailure.invalid("That event could not be read.")
        }
        guard let start = APIDateFormat.parse(request.start),
              let end = APIDateFormat.parse(request.end) else {
            throw APIWriteFailure.invalid("Check the start and end times.")
        }
        let draft: PlannerEventDraft
        do {
            draft = try PlannerEventDraft(
                calendarID: request.calendarID.map(CalendarID.init(rawValue:)),
                title: request.title,
                start: start,
                end: end,
                location: request.location,
                notes: request.description
            )
        } catch let error as PlannerWriteError {
            throw APIWriteFailure.invalid(APIWriteFailure.message(for: error))
        }

        do {
            let created = try await eventScheduler.create(draft)
            return APIJSON.encode(
                CreateEventResponse(
                    ok: true,
                    id: created.id,
                    start: APIDateFormat.iso8601(created.start),
                    end: APIDateFormat.iso8601(created.end),
                    htmlLink: created.link
                )
            )
        } catch {
            throw APIWriteFailure.provider(error)
        }
    }

    /// Proposes a reply to one message in the inbox.
    ///
    /// Sends nothing and changes nothing. It is on a write route because it transmits the
    /// user's own content off this machine, which is the thing worth gating even though no
    /// mailbox is touched.
    ///
    /// The message is re-read from the inbox rather than taken from the request. That is the
    /// whole reason the request carries only an id: the rule that a private message is never
    /// transmitted then holds against the provider's own classification, and a client could not
    /// smuggle private content to a model even deliberately, because there is no field for it.
    func draftReply(_ body: Data) async throws -> Data {
        guard let replyWriter else { throw APIWriteFailure.notPermitted }
        guard let request = APIJSON.decode(DraftReplyRequest.self, from: body) else {
            throw APIWriteFailure.invalid("That request could not be read.")
        }
        guard let intent = PlannerReplyIntent(rawValue: request.intent) else {
            throw APIWriteFailure.invalid("That is not something it knows how to draft.")
        }
        guard let mailReader else { throw APIWriteFailure.notPermitted }
        guard let items = try? await mailReader.mailItems(limit: Self.triageLimit),
              let item = items.first(where: { $0.id == request.messageID }) else {
            // Could not be found OR the inbox could not be read. Both are the same answer
            // here, and neither says which — a probe for message ids is not a thing this
            // route should answer.
            throw APIWriteFailure.invalid("That message is no longer in the list.")
        }

        let drafting: PlannerReplyRequest
        do {
            drafting = try PlannerReplyRequest(
                subject: item.title,
                sender: item.sender,
                snippet: item.summary,
                intent: intent,
                customInstruction: request.instruction,
                signOffName: signOffName,
                isPrivate: item.isPrivate
            )
        } catch PlannerDraftingError.messageIsPrivate {
            throw APIWriteFailure.invalid(
                "That message is marked private, so its content is never sent to an assistant."
            )
        } catch let error as PlannerDraftingError {
            throw APIWriteFailure.invalid(APIWriteFailure.message(for: error))
        }

        do {
            let proposal = try await replyWriter.draft(drafting)
            return APIJSON.encode(
                DraftReplyResponse(ok: true, body: proposal.body, provider: proposal.provider)
            )
        } catch PlannerDraftingError.notSignedIn {
            // Its own response: "could not be reached" sends someone to check their wifi when
            // what they actually need is to sign in to the CLI.
            throw APIWriteFailure.assistantSignedOut
        } catch {
            throw APIWriteFailure.provider(error)
        }
    }

    var canReadMailBody: Bool { mailBodyReader != nil }

    /// One message's body, for display.
    ///
    /// Read-only and local: this returns the body to the page on this Mac and sends it nowhere.
    /// The drafting route does not call it — `draftReply` still builds its prompt from the
    /// triage snippet — so being able to READ a body changes nothing about what is transmitted.
    func mailBody(id: String) async throws -> Data {
        guard let mailBodyReader else { throw APIWriteFailure.notPermitted }
        let body = try await mailBodyReader.body(for: id)
        return APIJSON.encode(
            MailBodyResponse(
                id: body.id,
                text: body.text,
                truncated: body.isTruncated,
                attachments: body.attachmentNames,
                unreadable: body.text == nil
                    ? (body.isPrivate
                        ? "This message could not be read safely, so its body is not shown."
                        : "This message has no text the app can show.")
                    : nil
            )
        )
    }

    /// Summarises one message.
    ///
    /// The one route that sends a BODY off the machine, and only when he asks. Like drafting, the
    /// request carries an id only: the body is re-read here, so a client cannot supply content,
    /// and the private and sensitive refusals hold against the engine's own copy.
    func summarizeMail(_ body: Data) async throws -> Data {
        guard let summarizer, let mailBodyReader else { throw APIWriteFailure.notPermitted }
        guard let request = APIJSON.decode(SummarizeMailRequest.self, from: body),
              !request.messageID.isEmpty, request.messageID.utf8.count <= 256 else {
            throw APIWriteFailure.invalid("That request could not be read.")
        }
        guard let message = try? await mailBodyReader.body(for: request.messageID) else {
            throw APIWriteFailure.invalid("That message could not be read.")
        }

        let summary: PlannerSummaryRequest
        do {
            let looksSensitive = contentClassifier.classify(
                .email(
                    subject: message.subject, sender: message.sender,
                    body: message.text, bodyKind: .plainText
                )
            ) == .private
            summary = try PlannerSummaryRequest(from: message, looksSensitive: looksSensitive)
        } catch PlannerDraftingError.nothingToAnswer {
            throw APIWriteFailure.invalid("There is no text in that message to summarise.")
        } catch let error as PlannerDraftingError {
            throw APIWriteFailure.invalid(APIWriteFailure.message(for: error))
        }

        do {
            let result = try await summarizer.summarize(summary)
            return APIJSON.encode(
                SummarizeMailResponse(ok: true, summary: result.text, provider: result.provider)
            )
        } catch PlannerDraftingError.notSignedIn {
            throw APIWriteFailure.assistantSignedOut
        } catch {
            throw APIWriteFailure.provider(error)
        }
    }

    /// Moves one event the user already has.
    ///
    /// Until this route existed, "Move it" opened the composer prefilled with the event's
    /// details and INSERTED a second event, leaving the original where it was. That is the one
    /// outcome a reschedule must not have, and it happened on the user's real calendar.
    ///
    /// The route changes times and nothing else: `MoveEventRequest` has no field that could
    /// rename or re-describe an event, and the PATCH body underneath names only `start` and
    /// `end`, so every part of the event this app never knew about survives it.
    func moveEvent(_ body: Data) async throws -> Data {
        guard let eventRescheduler else { throw APIWriteFailure.notPermitted }
        guard let request = APIJSON.decode(MoveEventRequest.self, from: body) else {
            throw APIWriteFailure.invalid("That change could not be read.")
        }
        guard let start = APIDateFormat.parse(request.start),
              let end = APIDateFormat.parse(request.end) else {
            throw APIWriteFailure.invalid("Check the start and end times.")
        }
        let move: PlannerEventMove
        do {
            move = try PlannerEventMove(
                eventID: request.eventID,
                calendarID: CalendarID(rawValue: request.calendarID),
                start: start,
                end: end
            )
        } catch let error as PlannerWriteError {
            throw APIWriteFailure.invalid(APIWriteFailure.message(for: error))
        }

        do {
            let moved = try await eventRescheduler.move(move)
            return APIJSON.encode(
                CreateEventResponse(
                    ok: true,
                    id: moved.id,
                    start: APIDateFormat.iso8601(moved.start),
                    end: APIDateFormat.iso8601(moved.end),
                    htmlLink: moved.link
                )
            )
        } catch {
            throw APIWriteFailure.provider(error)
        }
    }
}
