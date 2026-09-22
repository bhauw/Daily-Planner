# Daily Planner M2B Real Google Sync Design

## Status

Approved in chat on 2026-09-10. This design is the focused M2B increment that follows the accepted M2A Google read-only foundation. It refines the M2B sections of the broader `2026-08-30-daily-planner-m2-read-only-vertical-slice-design.md`; where the two differ on M2B dashboard breadth or calendar selection, this focused design is authoritative.

## Goal

Replace the synthetic dashboard source with an explicit, manual, read-only Google synchronization flow that renders:

- the next seven days from the Google account's provider-declared primary calendar;
- incomplete tasks from every Google Tasks list; and
- Gmail from the last 30 days, with sender, subject, date, labels, and snippet in the list and a full body view after explicit selection.

The app must remain incapable of writing to Gmail, Calendar, or Tasks.

## User decisions

- Ship Calendar, Tasks, and Gmail together.
- Use a recent dashboard rather than a full account mirror.
- Use only the provider-declared primary Google Calendar for the schedule.
- Combine a compact Gmail list with an explicit full-message detail view.
- Sync only after the user clicks **Sync now**.
- Do not download or process attachment bytes in M2B.

## Existing accepted foundation

M2A already provides:

- one confirmed Google identity;
- exact scopes `openid`, `email`, Gmail read-only, Calendar read-only, and Tasks read-only;
- authorization-code exchange and refresh-token rotation inputs;
- Keychain persistence for the OAuth client configuration and refresh token;
- encrypted private settings and the confirmed account binding;
- an allowlisted transport boundary;
- three connection canary reads;
- finite connection states and explicit cancellation/cleanup; and
- a signed personal macOS build whose connection survives restart.

M2B must consume that foundation without changing scopes, adding a provider mutation route, re-running authorization during ordinary sync, or exposing credential values.

## Non-goals

M2B does not include:

- Gmail send, reply, archive, label, star, trash, or read-state changes;
- Calendar create, update, delete, RSVP, attendee, reminder, or label changes;
- Tasks create, update, complete, move, or delete operations;
- background or scheduled synchronization;
- push notifications or Google watch channels;
- attachment download, preview, extraction, or indexing;
- Obsidian vault content;
- model inference, automated classification by an external model, planning proposals, or action execution;
- a complete historical account mirror; or
- automatic use of any non-primary calendar.

## Architecture

### Package boundaries

`DailyPlannerDomain` owns validated provider-neutral records, opaque identifiers, bounded sync requests, committed snapshot models, privacy classes, cursor values, and read-only ports. It contains no HTTP, Keychain, filesystem, or UI implementation.

`DailyPlannerGoogle` owns strict Google response decoders and three read clients. It is the only package allowed to construct Google provider requests. Every provider request is a GET against an exact allowlist.

`DailyPlannerApplication` owns manual sync orchestration, pagination, cursor rules, conservative classification, complete-snapshot commit, stale-state behavior, and email-detail loading. It depends on domain ports rather than HTTP details.

`DailyPlannerPersistence` owns encrypted source-record envelopes, opaque cursor metadata, atomic snapshot replacement, deletion reconciliation, retention, tamper handling, and a content-encryption key separate from the private-settings key.

`DailyPlannerUI` owns the Sync now control, last-successful-sync state, stale/error presentation, schedule/tasks/email sections, loading and empty states, and email detail presentation.

`DailyPlannerApp` constructs the real Google readers, encrypted cache, sync workflow, and UI model. The M1 synthetic source is retained only for tests and explicit preview fixtures; it is not used by standard production composition after M2B acceptance.

### Capability ports

The domain exposes capabilities rather than raw endpoints:

```swift
public protocol GoogleAccessTokenProviding: Sendable {
    func accessToken() async throws -> GoogleAccessToken
}

public protocol GmailReading: Sendable {
    func messages(receivedAfter: Date, pageToken: GmailPageToken?) async throws -> GmailMessagePage
    func message(id: GmailMessageID, format: GmailMessageFormat) async throws -> GmailMessageRecord
    func changes(after historyID: GmailHistoryID, pageToken: GmailPageToken?) async throws -> GmailHistoryPage
}

public protocol GoogleCalendarReading: Sendable {
    func primaryCalendar() async throws -> GoogleCalendarRecord
    func events(
        calendarID: CalendarID,
        interval: DateInterval,
        syncToken: CalendarSyncToken?,
        pageToken: CalendarPageToken?
    ) async throws -> CalendarEventPage
}

public protocol GoogleTasksReading: Sendable {
    func taskLists(pageToken: GoogleTasksPageToken?) async throws -> GoogleTaskListPage
    func tasks(
        listID: GoogleTaskListID,
        updatedSince: Date?,
        pageToken: GoogleTasksPageToken?
    ) async throws -> GoogleTasksPage
}

public protocol GoogleSnapshotCaching: Sendable {
    func loadSnapshot(for binding: GoogleIdentityBinding) async throws -> GoogleDashboardSnapshot?
    func replaceSnapshot(
        _ snapshot: GoogleDashboardSnapshot,
        cursors: GoogleSyncCursors,
        for binding: GoogleIdentityBinding
    ) async throws
    func purge(for binding: GoogleIdentityBinding) async throws
}
```

Names may be adjusted during planning to match existing conventions, but the capability boundaries and absence of mutation methods are binding.

## Provider reads

### Shared token flow

Each manual sync loads the stored client configuration and refresh token, obtains a short-lived access token from the existing OAuth token endpoint, validates the exact approved scope set including the accepted Google email alias, and retains access tokens only in memory. A token refresh failure returns a finite reconnect state and never copies credentials to settings, cache, logs, process arguments, or environment variables.

### Gmail

Initial sync queries only messages newer than the 30-day cutoff. The list request retrieves opaque IDs and thread IDs; selected records are then fetched with the minimum format needed for list display and deterministic classification. The list shows sender, subject, provider timestamp, labels, and bounded snippet.

Selecting an email explicitly requests the full record when it is not already available in an allowed encrypted cache entry. MIME decoding supports bounded `text/plain` and sanitized display of `text/html`; scripts, remote resource loading, forms, active content, and automatic link opening are disabled. Attachment metadata may be displayed, but attachment bytes are never requested.

After a complete initial sync, the newest Gmail `historyId` is committed. Later manual syncs use `users.history.list`. All pages and referenced message reads must succeed before the cursor and snapshot advance. An expired history ID (HTTP 404) purges the Gmail partition and performs one bounded full resync.

### Calendar

The calendar client resolves exactly one source: the Calendar API record marked `primary == true`. Absence, duplication, malformed identity, or unreadable primary state fails closed. No calendar is selected from its display name.

The user-approved schedule mode is `primaryOnly`; activating Sync now is the explicit action that applies that configured mode. All non-primary calendars remain excluded and are not fetched for dashboard content.

Initial event sync covers `[startOfToday, startOfToday + 7 days)` in the user's local calendar and passes explicit time bounds. Pagination parameters remain stable. The final page's `nextSyncToken` is committed only with the complete snapshot. Incremental requests reuse compatible initial parameters and include deletions. HTTP 410 purges only the Calendar partition and performs one bounded full resync.

Cancelled events and provider deletions remove matching cached records. Event recurrence instances are rendered as returned by the API; M2B does not create or infer instances locally. All-day events retain date semantics, and timed events retain their provider time zone and absolute instants.

### Tasks

Every task list is enumerated read-only. Each list is paginated and then queried for incomplete tasks. Reconciliation polls may include completed, deleted, hidden, or assigned records only when required to remove or update previously cached items; UI eligibility remains incomplete tasks only.

Later manual syncs use the last committed poll time minus a fixed overlap window. Results are de-duplicated by opaque task ID and newest provider `updated` timestamp. The cursor advances only after every list and page commits. Google due values remain date-only; the UI must not fabricate a time.

## Bounded working set

- Calendar: exactly the next seven local calendar days, beginning today.
- Gmail: messages received within the last 30 days, newest first, capped at 200 messages and 10 provider pages.
- Tasks: at most 50 lists, 100 incomplete tasks per list, 500 incomplete tasks total, and 10 provider pages per list.
- Calendar: at most 500 returned event instances and 10 provider pages for the seven-day interval.
- Email bodies: fetched only after explicit selection or when the minimum classifier requires a bounded body fragment; never prefetch all full bodies.
- Email display fields: sender, subject, and snippet are each capped at 512 Unicode scalar values; a decoded displayed body is capped at 512 KiB before sanitization.
- Attachments: metadata only, with zero attachment-byte requests.
- Tasks incremental polling overlaps the last committed poll time by exactly five minutes.

Caps must produce a visible finite “more items available in Google” state rather than silently claiming the account is fully mirrored.

## Classification and encrypted cache

All provider text is untrusted data and has no instruction authority.

Minimum fields are classified in memory before durable persistence. The classifier is deterministic and local. Financial indicators, credentials/secrets indicators, health/legal indicators, ambiguous MIME, decoding uncertainty, or any unsupported form classify the record as `Private`. Unknown classification also fails closed to `Private`.

`Ordinary` records may be stored only in per-record AES-GCM envelopes. Authenticated metadata binds provider, confirmed account binding, opaque source ID, source version, schema version, key version, privacy class, created/updated times, and retention deadline. The cache content key is a separate Keychain item from the OAuth and private-settings keys and supports the same personal-signing fallback policy already reviewed for local use.

`Private` email bodies, event descriptions, task notes, and derivatives remain memory-only. Durable state may retain only the minimum opaque source identity, classification, version/cursor, and suppression metadata needed for reconciliation. The UI may show a private item during the current session but must not claim it is available offline.

The default retention for eligible encrypted records is 90 days. Provider deletion, disconnect, account-binding mismatch, privacy upgrade, retention expiry, cache authentication failure, unsupported schema, or lost content key purges the affected records and derivatives. There is no plaintext cache or recovery file.

## Manual sync transaction

1. The user clicks **Sync now**.
2. The application claims one exclusive sync operation; a second request is disabled or coalesced.
3. The existing credential boundary supplies one in-memory access token.
4. Calendar, Tasks, and Gmail top-level reads may proceed concurrently, while pagination within each provider remains ordered.
5. Each provider produces a complete candidate partition plus candidate cursors in memory.
6. Records are strictly decoded, bounded, classified, and reconciled against the previous committed snapshot.
7. Only after all three provider partitions succeed does one cache transaction replace the dashboard snapshot and cursors.
8. The UI publishes the new snapshot and an exact last-successful-sync timestamp.

Cancellation discards candidates and does not advance cursors. Closing the app mid-sync has the same effect. A partial provider success never becomes the new committed dashboard.

## UI design

The standard three-column window becomes a real-data dashboard after an explicit sync:

- **Schedule:** primary-calendar events for the seven-day horizon, grouped by day, with all-day/timed distinctions and time-zone-safe display.
- **Tasks:** incomplete tasks across all lists, showing list, title, due date if present, and completion state as read-only.
- **Email:** 30-day messages ordered newest first, showing sender, subject, date, labels, and snippet. Selecting a row opens a detail view with sanitized full body and attachment metadata.

The top safety banner remains `Read-only · no actions executed`. It adds:

- **Sync now**;
- an in-progress state with Cancel;
- last successful sync time;
- stale/offline/reconnect finite state; and
- bounded-result disclosure when provider caps are reached.

No provider read starts on app launch, view appearance, settings appearance, row selection other than the explicitly selected email detail, or timer. The app may load its encrypted local snapshot after the user activates **Load saved dashboard** or **Sync now**; it does not silently access private state during view construction.

Empty states distinguish no matching data from not synced, stale cache, disconnected account, private-memory-only content, and provider cap reached.

## Error behavior

| Failure | Required behavior |
|---|---|
| Offline, timeout, or Google 5xx | Preserve the last committed snapshot, mark it stale, keep cursors unchanged |
| Credential missing, rejected, or Keychain unavailable | Stop provider reads and present reconnect/Keychain finite state |
| Gmail history 404 | Purge Gmail partition and affected derivatives, then perform one bounded full Gmail resync |
| Calendar sync 410 | Purge Calendar partition/token, then perform one bounded full Calendar resync |
| Tasks partial pagination/poll | Retain the prior Tasks partition/cursor; retry from the overlap window next time |
| Strict decode or pagination invariant failure | Discard the entire candidate sync; never commit partial data |
| Cache tamper, unknown schema, or lost key | Purge rebuildable affected cache and require manual resync |
| Account-binding mismatch | Stop, purge the mismatched cache, and require explicit reconnection |
| Provider deletion | Purge source record, body, and all derived local data on the next successful transaction |
| User cancellation or app exit | Cancel requests, discard candidates, retain prior snapshot and cursors |

Diagnostics use allowlisted event names, finite reason codes, bounded counts, and coarse timestamps only. They never contain message text, subject, sender, recipients, labels, event text, attendee data, task text, list names, account values, provider IDs, cursor values, tokens, OAuth values, filesystem paths, or raw errors.

## Network policy

Allowed production provider traffic is limited to:

- the existing OAuth token and revoke endpoints using their already reviewed POST forms;
- Gmail `GET` profile/list/message/history routes under `https://gmail.googleapis.com/gmail/v1/users/me/`;
- Calendar `GET` calendar-list and events routes under `https://www.googleapis.com/calendar/v3/`;
- Tasks `GET` task-list and tasks routes under `https://tasks.googleapis.com/tasks/v1/`.

The allowlist validates scheme, exact host, method, normalized path template, bounded query keys, and absence of fragments/user-info. Redirects remain rejected. Authorization uses one Bearer header; secrets never appear in URLs. Any provider mutation method, write endpoint, batch mutation, upload route, broader scope, or unknown query key fails before transport.

## Testing strategy

Strict TDD is mandatory. Every production behavior begins with a focused failing test that demonstrates the missing behavior before implementation.

Tests use synthetic fixtures only and record behavior at the network, Keychain, clock, and filesystem boundaries. No automated test may use the network, system browser, real Keychain, live Google identity, real provider content, or a private local path.

Required suites include:

- strict Gmail, Calendar, and Tasks decoder validation;
- exact endpoint/method/query allowlists and mutation inverse canaries;
- pagination, cursor advancement, expired-cursor resync, deletion, overlap, and de-duplication behavior;
- conservative classification and zero durable Private-body tests;
- AES-GCM cache round trip, account binding, tamper/schema/key-loss purge, transaction atomicity, and retention;
- cancellation, app-exit, partial-sync, stale-cache, reconnect, and finite-error workflows;
- production composition proving no `M1SyntheticCalendarSource` in standard mode;
- UI accessibility, keyboard traversal, explicit-action-only reads, loading/empty/stale/capped states, and sanitized email detail rendering;
- full source scans proving no Google mutation capability or write scope is linked;
- signed build, exact executable launch, scratch cleanup, and owned-process lifecycle.

Every implementation task uses a fresh isolated SwiftPM scratch path and receives independent task review. The completed branch receives a whole-branch security/code review before live data access.

## Acceptance criteria

M2B is accepted only when:

1. Standard production composition uses the reviewed real Google readers and encrypted cache, not the synthetic source.
2. No provider read happens before explicit **Sync now** or **Load saved dashboard** activation.
3. One manual sync renders the primary calendar's next seven days, incomplete tasks from all lists, and bounded 30-day Gmail metadata/snippets.
4. Selecting one email renders its sanitized full body without fetching attachment bytes or remote content.
5. Incremental sync and invalid-cursor recovery preserve transaction and deletion guarantees.
6. Private or uncertain bodies are absent from durable storage, diagnostics, fixtures, evidence, and model input.
7. Offline/partial failures preserve the last valid encrypted snapshot and do not advance cursors.
8. Exact source and behavioral gates prove only the approved read scopes and GET provider routes are linked.
9. Fresh focused and full tests, integrated verifier, signature verification, and independent whole-branch review pass.
10. After explicit user authorization, a signed-app live canary sync displays real data with retained evidence limited to scopes, finite states, booleans, and counts.

## Delivery sequence

The implementation plan should divide M2B into independently reviewable tasks for:

1. domain records, bounds, cursors, and read/cache ports;
2. token refresh reuse for general read clients;
3. exact Google network policy expansion;
4. Gmail list/detail/history client;
5. primary-calendar event client;
6. Tasks list/task client;
7. deterministic privacy classification;
8. encrypted transactional cache and retention;
9. manual three-provider sync orchestration;
10. production composition and real-data dashboard UI;
11. integrated read-only/privacy verifier and signed-app acceptance;
12. independent whole-branch review followed by an explicitly authorized live canary.

Tasks may be split further where a single review surface would become too large. They must not be merged into one unreviewable implementation change.
