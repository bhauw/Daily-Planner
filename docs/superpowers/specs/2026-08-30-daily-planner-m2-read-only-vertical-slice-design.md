# Daily Planner M2 Read-Only Vertical Slice Design

Date: 2026-08-30

Status: approved in chat and approved after written-spec review; M2A planning authorized

## Outcome

M2 turns the verified M1 offline shell into a real-data, read-only Daily Planner. It connects one Google identity, reads Gmail, Calendar, and Google Tasks through exact read-only scopes, classifies content before persistence, uses only explicitly Planning calendars for decisions, reads minimum tag-selected context from an explicitly selected Obsidian vault, and renders a dry-run email-to-plan proposal without sending, posting, or writing anything externally.

M2 does not add Codex inference, email generation quality work, provider writes, Google labels/read-state changes, Calendar or Task creation, vault writes, notifications, background timers, launch-at-login, travel routing, or midnight summaries. Those remain later milestones.

## Delivery decomposition

M2 is too broad for one implementation plan. It is delivered as five independently testable increments, each retaining the read-only interlock:

1. **M2A — Google read-only foundation:** production OAuth/Keychain/network boundaries, connection UI, exact-scope and account validation, and a user-authorized live canary.
2. **M2B — Safe provider synchronization:** Gmail full/history sync, Calendar list/event sync tokens, Tasks overlap polling, privacy classification, encrypted Ordinary cache, and calendar-role enforcement.
3. **M2C — Tag-indexed vault read:** resolve only the selected bookmark, build an encrypted tag index, and return minimum eligible excerpts without touching `.obsidian/`.
4. **M2D — Dry-run planning pipeline:** combine eligible Gmail, Planning Calendar, Tasks, and vault context into deterministic local summaries, draft-shaped previews, conflict checks, and proposed actions with execution permanently disabled.
5. **M2E — Integrated read-only UI and acceptance:** expose connection/sync/privacy state in the three-column shell and pass signed, adversarial, privacy, accessibility, and zero-write acceptance gates.

The first implementation plan covers M2A only. M2B through M2E each receive a focused plan after the preceding increment passes review. This prevents live credentials, source-content persistence, vault access, and UI composition from landing as one unreviewable change.

## Binding constraints

- Platform remains native Swift 6 on macOS 15 or later, built through SwiftPM and the existing signed-app scripts.
- Production code remains layered: Domain imports no adapter, UI, Security, AppKit, or filesystem implementation; Application depends on Domain ports; adapters depend inward; App composition owns concrete wiring.
- Exact Google scopes are, in this exact order:
  1. `openid`
  2. `email`
  3. `https://www.googleapis.com/auth/gmail.readonly`
  4. `https://www.googleapis.com/auth/calendar.readonly`
  5. `https://www.googleapis.com/auth/tasks.readonly`
- Installed-app incremental authorization remains disabled. Any missing, additional, or reordered requested scope fails locally; any missing or additional granted scope fails onboarding and revokes the unusable grant.
- Google provider operations in M2 are GET-only. OAuth authorization-code exchange, refresh, and explicit revoke are the only permitted non-GET network operations and are not provider-content mutations.
- No Google, vault, or action write adapter is composed in M2. The dry-run interlock is structural, not a disabled button over reachable write code.
- A live OAuth flow or live provider read requires a separate, explicit user action in the signed app. Automated tests never open a browser, touch the real Keychain, use the real vault, or access the network.
- The user-designated external/reference calendar is runtime encrypted configuration only. No personal calendar identifier, email address, account identity, home address, note path, credential, authorization URL, or source content may enter Git, tests, evidence, logs, screenshots, or diagnostics.
- Every newly observed or unreadable calendar defaults to `Excluded reference`. Only calendars explicitly set to `Planning` may affect workload, conflicts, priority, summaries, proposals, assistant context, or aggregate state.
- Private includes banking, sensitive financial content, and anything uncertain. Private bodies and derivatives remain memory-only and never enter the cache, vault index, diagnostics, notifications, Codex, or test evidence.
- Ordinary content may be persisted only in authenticated encryption with a schema version, key version, source token, privacy class, and retention deadline. Default retention is 90 days.
- M2 never sends source content to Codex. The assistant column may display deterministic local output and a clear `Assistant generation unavailable in M2` state.
- All visible M2 screens retain a clear `Read-only · no actions executed` safety label.

## Architecture

### Package boundaries

The production package adds focused targets rather than importing the disposable probe package:

- `DailyPlannerDomain`: account-binding value types, sync cursors, privacy classes, source records, cache policy, context manifests, dry-run proposal types, and provider/vault read ports.
- `DailyPlannerApplication`: onboarding, sync orchestration, classification, cache lifecycle, vault context selection, and dry-run planning workflows.
- `DailyPlannerPersistence`: exact OAuth Keychain records, encrypted content cache, cursor/retention metadata, migration, purge, and tamper handling.
- `DailyPlannerGoogle`: OAuth request/session, allowlisted transport, token refresh, Gmail/Calendar/Tasks decoders and read clients. It depends on Domain/Application ports and contains no UI.
- `DailyPlannerVault`: bookmark resolution, coordinated contained reads, tag parsing/indexing, and minimum excerpt retrieval. It contains no write API.
- `DailyPlannerPlatform`: system browser, clock, folder picker, and Mac-specific finite status bridges.
- `DailyPlannerUI`: Settings connection flow, sync state, privacy/source labels, real-data queue and previews, and dry-run proposal presentation.
- `DailyPlannerApp`: concrete composition only.

The existing `Spikes/GoogleOAuthProbe` remains disposable evidence. M2 production code may reproduce its reviewed algorithms and test cases, but the app does not link against the spike target and does not reuse the spike Keychain identity.

### Core ports

Domain protocols expose capabilities rather than HTTP details:

```swift
public protocol GoogleAccountAuthorizing: Sendable {
    func connect(clientIdentifier: String) async throws -> GoogleConnectionReceipt
    func disconnect() async throws
    func connectionState() async -> GoogleConnectionState
}

public protocol GmailReading: Sendable {
    func fullSync(limit: Int) async throws -> GmailSyncPage
    func changes(after historyID: GmailHistoryID) async throws -> GmailHistoryPage
    func message(id: GmailMessageID, format: GmailMessageFormat) async throws -> GmailMessageRecord
}

public protocol GoogleCalendarReading: CalendarCatalogReading, PlanningCalendarReading,
    ExcludedReferenceViewing {
    func fullSync(calendarID: CalendarID) async throws -> CalendarSyncPage
    func changes(calendarID: CalendarID, syncToken: CalendarSyncToken) async throws -> CalendarSyncPage
}

public protocol GoogleTasksReading: Sendable {
    func taskLists() async throws -> [GoogleTaskList]
    func tasks(listID: GoogleTaskListID, updatedSince: Date?) async throws -> GoogleTasksPage
}

public protocol ClassifiedSourceCaching: Sendable {
    func replaceOrdinary(_ records: [ClassifiedSourceRecord]) async throws
    func applyOrdinary(_ changes: [ClassifiedSourceChange]) async throws
    func purge(_ sourceIDs: Set<OpaqueSourceID>) async throws
}

public protocol TaggedVaultContextReading: Sendable {
    func rebuildIndex() async throws -> VaultIndexReceipt
    func excerpts(matching tags: Set<VaultTag>, limit: Int) async throws -> [VaultExcerpt]
}
```

No M2 target defines a provider or vault mutation protocol.

## M2A — Google read-only foundation

### Connection flow

1. Settings accepts a Google Desktop OAuth client identifier after an explicit user action. The client identifier is never read from an environment variable, command argument, source file, preference, or URL.
2. Before browser launch, the app starts an IPv4 `127.0.0.1` listener on an ephemeral port and establishes a one-shot readiness gate. Ready, failure, cancellation, and timeout are mutually terminal; the browser can open at most once.
3. The app creates a fresh 43–128 character high-entropy PKCE verifier, S256 challenge, and 256-bit random state. The callback path is exactly `/oauth/callback`.
4. The system browser opens `https://accounts.google.com/o/oauth2/v2/auth` with the exact scope set, `response_type=code`, `access_type=offline`, `prompt=consent`, and `include_granted_scopes=false`.
5. The loopback listener accepts one bounded callback, requires exact path and constant-time state equality, rejects fragments, duplicate/conflicting values, oversized or fragmented-invalid headers, non-loopback clients, and any second completion.
6. The code is exchanged at `https://oauth2.googleapis.com/token` with the original verifier. Authorization code, verifier, state, access token, refresh token, client identifier, and full URLs remain memory-only except for the two approved Keychain records below.
7. The returned granted-scope set must exactly equal the approved set. The client performs only three initial canary reads: Gmail profile, Calendar list with one item, and Task lists with one item.
8. Gmail profile supplies the connected email identity. The user sees `Connected as …` and explicitly confirms it. The normalized identity binding is stored only in encrypted private settings; diagnostics retain only a finite `identityMatched` boolean.
9. Only after exact scopes, refreshed access, three canary reads, identity confirmation, and Keychain persistence all succeed does connection state become `connectedReadOnly`.
10. Any failure revokes the grant when possible, deletes both exact Keychain records, clears URL caches, closes the listener, discards access material, and returns a finite sanitized status.

### Credential storage

The production data-protection Keychain uses service `DailyPlanner.GoogleOAuth.v1` and exactly two accounts:

| Account | Value | Accessibility in M2 |
|---|---|---|
| `client-identifier` | Google Desktop OAuth client identifier | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| `refresh-token` | Refresh credential for the confirmed identity and exact read-only scope set | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |

Every query includes exact service and account, `kSecUseDataProtectionKeychain`, `kSecAttrSynchronizable=false`, and no shared access group. Add, read, replace, delete, disconnect, reset, and cleanup operate only on these two keys. Access tokens are memory-only. M2 does not enable locked or resident scheduling, so the pending lock-state gate does not widen accessibility.

### Network boundary

The injected transport rejects requests before sending unless all conditions match an allowlist:

| Purpose | Scheme/host/path | Methods |
|---|---|---|
| Token exchange/refresh | `https://oauth2.googleapis.com/token` | `POST` |
| Explicit revoke/cleanup | `https://oauth2.googleapis.com/revoke` | `POST` |
| Gmail | `https://gmail.googleapis.com/gmail/v1/users/me/...` | `GET` |
| Calendar | `https://www.googleapis.com/calendar/v3/...` | `GET` |
| Tasks | `https://tasks.googleapis.com/tasks/v1/...` | `GET` |
| OAuth callback | `http://127.0.0.1:<ephemeral>/oauth/callback` | loopback listener only |

No automatic redirect is followed. The URL session is ephemeral, has no cookie store or URL cache, and ignores system proxy credentials. Provider requests put the access token only in the `Authorization` header. Error mapping never returns response bodies, headers, URLs, identifiers, or tokens to UI or diagnostics.

### M2A UI states

Settings exposes finite states: `notConfigured`, `readyToConnect`, `connecting`, `awaitingConsent`, `confirmIdentity`, `connectedReadOnly`, `cancelled`, `offline`, `scopeMismatch`, `identityMismatch`, `credentialUnavailable`, `providerUnavailable`, and `cleanupRequired`.

The UI provides `Save client identifier`, `Connect Google`, `Cancel`, `Confirm account`, `Disconnect`, and `Retry cleanup`. It never displays tokens, authorization codes, scope response strings, raw errors, or full authorization URLs. Closing Settings cancels an active listener and makes no connection claim.

### M2A acceptance

- All OAuth, Keychain, transport, UI-model, and composition behavior is implemented test-first.
- Offline tests use recording fakes and synthetic `.example.test` identities only.
- A network spy proves no request occurs before an explicit connect action and every request matches the allowlist.
- Inverse tests prove an extra scope, write scope, unexpected host, redirect, method, path, callback, or Keychain account is rejected.
- Tests cover readiness ready-then-failed and failed-then-ready races and prove the browser opens once at most.
- Tests cover cancellation/timeout at listener, browser, exchange, refresh, each canary read, identity confirmation, and Keychain mutation.
- Sentinel tests prove credentials, URLs, identifiers, callback values, response bodies, and dynamic errors cannot reach persistence outside exact Keychain records, stdout/stderr, logs, UI status, evidence, or repository artifacts.
- The signed app passes connection-screen accessibility, keyboard focus, cancellation, and disconnect cleanup using injected fakes.
- The default automated verifier never performs a live network call or touches the real Keychain.
- A separate `--live-readonly-canary` acceptance route can run only after explicit user authorization. Its retained evidence contains the exact scope names and booleans for refresh, Gmail profile, Calendar list, Task lists, identity confirmation, Keychain cleanup/persistence disposition, and no private provider content.

## M2B — Safe provider synchronization

### Gmail

- Initial sync lists only the newest bounded working set required by the UI, then fetches each selected message or thread with the minimum format needed for classification and display.
- Store the newest `historyId` after a complete paginated sync. Partial sync uses `users.history.list` with `startHistoryId`, applies specific change arrays, and advances the cursor only after all pages and cache changes commit.
- HTTP 404 for an expired/out-of-range history ID invalidates affected derived state, clears the Gmail cache partition, and performs a bounded full resync. It never infers that nothing changed.
- Source deletions purge cached bodies, summaries, drafts, context, and pending dry-run proposals tied to the source.
- Attachment bytes are not processed in M2B. Metadata and adversarial synthetic fixtures establish size/type/signature/encryption rejection seams for M3.

### Calendar

- Calendar-list sync discovers runtime calendars; every missing/new/unreadable role is `Excluded reference`.
- Event sync is per calendar. Initial pages use a stable bounded horizon and store `nextSyncToken` only from the last page. Incremental pages reuse all compatible initial parameters and include deletions.
- HTTP 410 invalidates that calendar's token and cached partition, then performs a full sync. A role change purges prior contribution and invalidates all affected previews.
- Only IDs returned by the role policy as Planning reach `planningEvents`. Excluded calendars remain accessible only through the explicit manual reference workflow and never populate planning/cache aggregates.

### Tasks

- Task lists are enumerated read-only. Each list uses paginated `tasks.list` with `updatedMin` based on the last successful poll minus a fixed overlap window.
- Responses are de-duplicated by opaque task ID and newest `updated` timestamp. Cursor time advances only after all pages apply.
- Polls include completed, deleted, hidden, and assigned states only when required to reconcile cached records; UI eligibility is computed separately.
- Google due values remain date-only. M2 never fabricates a due time.

### Classification and encrypted cache

- Classify minimum fields in memory before any durable write. Uncertain or financial content is Private.
- Private persists only an opaque source ID and privacy class when needed to suppress duplicate processing. Its body and all derivatives remain memory-only.
- Ordinary records use AES-GCM envelopes and a separate content key from private settings. Each record binds provider, account binding, opaque source ID, source version/cursor, schema, key version, privacy class, created/updated time, and retention deadline as authenticated metadata.
- Failed authentication, unknown schema, lost key, or migration failure purges the affected rebuildable cache; there is no plaintext fallback.
- Retention defaults to 90 days and supports 30/90/180 day settings. Provider deletion, unlink, privacy upgrade, retention expiry, reset, and key loss purge eligible content and derivatives.

## M2C — Tag-indexed vault read

- The user must already have selected a root through M1 onboarding and must explicitly enable `Use tagged vault context`.
- Resolve only the stored bookmark; balance security-scope start/stop; reject stale/missing access with a finite reselection state.
- Standardize and resolve every candidate beneath the selected root, reject symlinks, aliases, hard-link escapes where detectable, traversal, Unicode-normalization collisions, replacement races, non-regular files, and any `.obsidian` component.
- Enumerate Markdown files only within the selected root. Read frontmatter and inline tags first, classify index values before persistence, and store only encrypted normalized tag tokens plus opaque note tokens and change fingerprints.
- A context request queries the encrypted tag index, revalidates containment and fingerprint, opens only the minimum matching notes, and returns bounded excerpts. It never reads the entire vault to answer a query.
- Private/uncertain note content remains memory-only and is not returned to the M2 dry-run context pipeline.
- M2 defines no vault writer. Automated and signed acceptance use generated fake vaults only; the real vault is never a test fixture or evidence source.

## M2D — Dry-run planning pipeline

The vertical flow is:

```text
eligible Gmail source
  -> in-memory privacy classification
  -> Ordinary encrypted cache or Private memory-only record
  -> deterministic local summary + action/date extraction
  -> Planning-calendar conflict check + current Tasks overlap
  -> optional minimum tag-selected Ordinary vault excerpts
  -> typed dry-run proposal
  -> UI review only; executionAvailable == false
```

- Deterministic summaries identify sender category, requested action, explicit dates, uncertainty, and source age without claiming AI quality.
- Draft-shaped previews are clearly labeled local placeholders for validating the pipeline. They are not recipient-aware generation and cannot be sent.
- Conflict checking reads only Planning calendars. Excluded reference events cannot alter availability, workload, urgency, or proposed time.
- Proposed types are `replyPreview`, `calendarPreview`, `taskPreview`, `needsInformation`, or a combination. Every proposal includes source tokens, privacy class, assumptions, and `Dry run — nothing will be sent or added`.
- There is no approval transition, canonical execution payload, outbox insertion, provider mutation, or vault write in M2.

## M2E — Integrated UI and acceptance

- The existing three-column balance remains: prioritized sources left, read-only schedule/conflict state center, and assistant/context/dry-run detail right.
- A connection/sync strip shows last successful read, finite degraded state, and manual `Sync now`. M2 adds no scheduler timer.
- Source rows show category, urgency, privacy, source type, and why they are prioritized. Private rows disclose no sensitive preview text while locked or outside the focused detail view.
- Settings groups Google connection, calendar roles, cache retention/reset, and vault-context permission. Destructive local reset identifies exact local data removed and does not alter Google or the vault.
- Bulk review may select dry-run proposals, but all execution controls remain absent or disabled with accessible explanations.

The integrated verifier must pass all M1 gates plus M2-specific suites for OAuth/network, sync cursors, classification/persistence, vault containment/tag selection, dry-run zero writes, UI accessibility, signed launch, source hygiene, inverse canaries, scratch cleanup, and exact owned-process lifecycle.

## Failure behavior

| Failure | Required result |
|---|---|
| User cancels browser consent | Close listener, clear transient values, retain no grant, show `cancelled` |
| Scope or identity mismatch | Revoke, delete exact credentials, clear cache, show finite reconnect state |
| Keychain locked/denied/corrupt | Pause dependent reads; never copy credentials elsewhere |
| Offline/timeout/5xx | Preserve last valid encrypted Ordinary cache, show stale timestamp, do not claim a fresh sync |
| Gmail history 404 | Purge Gmail partition and affected derivatives, then bounded full sync |
| Calendar sync 410 | Purge the affected calendar partition/token, then full sync with role unchanged |
| Tasks partial poll ambiguity | Retain old cursor, retry overlapping window, de-duplicate before commit |
| Cache tamper/schema/key loss | Purge rebuildable affected cache and require resync; no partial plaintext recovery |
| Privacy upgrade | Immediately purge durable body and every derived record; keep only allowed opaque metadata |
| Vault bookmark stale/denied | Stop vault work and require explicit reselection; Google sync may continue |
| Vault containment/race failure | Reject the note, increment a finite sanitized security counter, and return no excerpt |
| App closes mid-sync | Do not advance cursor; next manual sync safely repeats the incomplete page/window |

## Test and evidence policy

- TDD is mandatory: every production behavior starts with a focused failing test whose failure proves the missing behavior.
- Tests assert public behavior through real domain/application code; recording fakes are used only at network, Keychain, browser, clock, and filesystem boundaries.
- Fixtures contain only synthetic identities, messages, events, tasks, notes, credentials, and paths. Adversarial fixtures include prompt-injection text, finance/uncertain content, malformed MIME, oversized/encrypted/macro-like attachment metadata, calendar-role confusion, stale cursors, pagination races, path traversal, symlinks, Unicode collisions, and content canaries.
- No automated test may use the network, system browser, real Keychain, real Google identity, real vault, personal calendar identifier, or home-base data.
- Evidence files are sanitized schemas, scope names, booleans, counts, finite statuses, and tool versions only. They contain no dynamic provider content or local private paths.
- Live Google access, even read-only, is never inferred from offline coverage. It remains blocked until the user explicitly authorizes the signed-app canary.

## Completion criteria

M2 is complete only when:

1. M2A through M2E each pass task review and whole-branch review.
2. The merged verifier passes all M1 and M2 automated gates with zero failures and zero external writes.
3. A user-authorized signed-app read-only canary confirms exact scopes, refresh, Gmail profile, Calendar list, and Task lists with sanitized evidence.
4. The signed app can manually sync real data and render the dry-run vertical flow while the write-capability source scan proves no Google or vault mutation implementation is linked.
5. The configured external/reference calendar remains excluded at runtime and an acceptance canary proves excluded events influence nothing.
6. Private and uncertain bodies are absent from every durable store, index, diagnostic, notification, evidence artifact, and model submission.
7. The project handoff and real Obsidian project/session records describe the exact live and deferred boundaries.

Passing M2 does not authorize M3 Codex inference or any M4/M6 external write.

## Current official provider references

- Google OAuth for desktop apps: <https://developers.google.com/identity/protocols/oauth2/native-app>
- Gmail synchronization: <https://developers.google.com/workspace/gmail/api/guides/sync>
- Gmail history list: <https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.history/list>
- Calendar incremental synchronization: <https://developers.google.com/workspace/calendar/api/guides/sync>
- Calendar events list: <https://developers.google.com/workspace/calendar/api/v3/reference/events/list>
- Google Tasks list: <https://developers.google.com/workspace/tasks/reference/rest/v1/tasks/list>
