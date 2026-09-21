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
                canSchedule: eventScheduler != nil
            )
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
        let payload = items.map { item in
            DraftDTO(
                id: item.id,
                title: item.title,
                summary: item.summary,
                kind: "reply",
                sender: item.sender,
                category: APICategory(item.category),
                receivedAt: APIDateFormat.iso8601(item.receivedAt),
                threadId: item.threadID
            )
        }
        return APIJSON.encode(DraftsResponse(drafts: payload))
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
}
