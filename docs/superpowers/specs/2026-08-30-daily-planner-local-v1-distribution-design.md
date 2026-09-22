# Daily Planner Local-v1 Distribution Design

Date: 2026-08-30

Status: approved architecture for M1 implementation planning

Decision owner: project owner

## Authorization boundary

This document selects the distribution architecture for implementation planning. The project owner reviewed and approved it on 2026-08-30, so it authorizes a separate M1 implementation plan. It does not by itself authorize implementation, Google or vault writes, use of personal source data, or distribution to another user.

This decision intentionally supersedes only the provisional distribution ruling in the [M0.5 feasibility handoff](../../architecture/M0.5-Feasibility-Handoff.md). Current evidence is exact: both signed exact-folder persisted-bookmark gates now pass; the automated unsandboxed fake-vault and direct-Codex checks passed; sandboxed direct Codex launch failed without a proven cause; and the locked-state Keychain observation and live Google canary remain incomplete. The project owner approved the broader unsandboxed process boundary for a personal local v1 in chat and then approved this committed written specification, with the compensating application controls below. The handoff's Codex protocol, data lifecycle, OAuth, vault-writing, scheduler, Keychain-accessibility, and [action-state-machine](../../architecture/action-state-machine.md) contracts remain binding unless this document says otherwise. In particular, selecting the local distribution model does not convert the untested locked-state Keychain candidate into an approved class.

## Decision and alternatives

### 1. Recommended for v1: one local unsandboxed native app

Ship one native macOS application for personal, local, non-App-Store use. The app runs outside App Sandbox, launches the installed Codex executable directly as a supervised child process, stores Google credentials in exact Keychain items, and exposes vault access only after an explicit folder selection.

This is the smallest architecture consistent with the observed direct-launch result. It has one installation and one application lifecycle, avoids IPC and helper identity problems, and keeps cancellation and crash ownership in the process that owns the user interface and job queue.

The cost is material: macOS does not confine an unsandboxed app to the selected vault or to Google endpoints. The app and any compromised code executing inside it have the current user's filesystem and process privileges. The controls in this document reduce accidental access and constrain intended application behavior; they are not an operating-system security boundary.

### 2. Deferred for v2: sandboxed main app plus separately installed helper

A later version may put the user interface, Google adapter, and vault adapter in a sandboxed main app and move direct Codex execution to a separately installed helper. This could give the main app an enforceable file and network entitlement boundary.

It is not ready for v1. A new feasibility design must resolve helper installation and removal, stable code identity, mutual authentication, version negotiation, bounded IPC framing, request correlation, cancellation propagation, ownership of child processes, helper/main crash attribution, stale-helper recovery, and atomic update/rollback safety. The design must then prove those properties with signed synthetic end-to-end tests.

This option is deferred, not partially implemented by this specification. The earlier helper/server draft remains rejected; none of its broker, listener, or installation design is carried into v1. A v2 effort starts with a new reviewed feasibility design.

### 3. Rejected for v1: sandboxed app plus manually launched broker

A manually launched local broker would let a sandboxed app ask another process to run Codex without solving installation. It would also create two visible lifecycles, manual startup ordering, version skew, stale sessions, unclear cancellation ownership, ambiguous crash attribution, and support failures whenever the broker is absent or outdated.

It also creates a new trust boundary without a trustworthy installation boundary. The main app would need to discover and authenticate a separately launched process, frame untrusted IPC, prevent replay or cross-user connection, and explain which process holds content. Requiring the user to keep a second program alive is not acceptable for a personal daily planner. This approach is rejected rather than used as an interim architecture.

## Scope and non-goals

Local v1 supports one macOS user, one explicitly selected vault root, one connected Google identity, a resident app while the Mac is awake, and the approved Gmail, Calendar, Tasks, planning, proposal, review, execution, and reconciliation workflows.

Local v1 does not include:

- App Store distribution, App Sandbox, a helper, broker, server, launch daemon, or cloud backend;
- Developer ID signing, notarization, a public download, an automatic updater, or a production update channel;
- arbitrary executables, shell commands, user-supplied command-line arguments, plugins, or model tools that can mutate providers or the vault;
- broad home-directory access, filesystem discovery, vault crawling, access to multiple vault roots, or access to vault configuration internals;
- automatic inference of calendar roles, cross-device settings sync, multi-user administration, or a shared account;
- an exact wall-clock or always-on service promise while the Mac is asleep, powered off, or after the user quits the app.

## Architecture and component boundaries

```text
SwiftUI app and onboarding
          |
          v
Application workflows and resident scheduler
          |
          v
Domain contracts and action state machine
       /      |        |         \
      v       v        v          v
 Google   Vault     Codex      Local persistence
 adapter  adapter   supervisor  and Keychain
```

- **UI and onboarding** collect explicit consent, folder selection, calendar-role choices, OAuth connection, review, approval, and recovery actions. They do not call providers, files, or Codex directly.
- **Application workflows** own sync, deterministic filtering, job construction, proposal generation, approval, execution, reconciliation, and resident scheduling. They depend on domain protocols.
- **Domain contracts** own typed source items, calendar roles, assistant jobs, action bundles, canonical approvals, privacy modes, provider receipts, and the binding action state machine. Domain code imports no SwiftUI, Security, filesystem, Google, Codex, or persistence implementation.
- **Google adapter** is the only application component allowed to make external network requests. It implements exact OAuth and Gmail, Calendar, and Tasks operations. It cannot bypass action approval for a mutation.
- **Vault adapter** receives a capability for one selected root and accepts validated relative targets only. It never accepts an absolute path from a source item, model result, URL, or UI text field.
- **Codex supervisor** discovers one executable from a compiled allowlist, launches App Server v2 directly, validates every protocol envelope and typed output, owns cancellation and cleanup, and exposes no provider or vault write tool.
- **Persistence and Keychain adapters** separate non-content metadata, encrypted content envelopes, credentials, and append-only sanitized receipts. Plain source content never appears in an index, preference, crash report, or diagnostic event.
- **Platform services** own wake-aware scheduling, notifications, folder selection, and local lifecycle state. Notifications receive finite status codes and counts only.

Adapter direction is inward: infrastructure implements domain protocols, while domain and application code never import concrete adapters. Google, vault, and Codex adapters are independently replaceable. Fakes remain the default in implementation milestones until a separately reviewed live gate authorizes a real adapter.

## Codex child-process boundary

The v1 candidate set is compiled into the app and contains exactly these locations:

1. the current user's `.local/bin/codex`, constructed from the system home-directory API;
2. `/opt/homebrew/bin/codex`;
3. `/usr/local/bin/codex`;
4. `/Applications/Codex.app/Contents/Resources/codex`.

There is no executable picker, path preference, environment override, `PATH` search, or fallback to `which`. Discovery canonicalizes each candidate, resolves its link chain, requires a regular executable owned by the current user or root, and rejects a candidate or link chain that is group-writable or other-writable. It selects the first candidate that reports exactly `codex-cli 0.151.0` and matches the checked-in App Server v2 schema fingerprint. A missing or mismatched installation blocks assistant jobs and presents a finite remediation status; it never broadens discovery.

The supervisor sets `Process.executableURL` to the validated canonical URL and sets arguments from the literal application-owned vector `app-server`, `--stdio`. It never invokes a shell, concatenates a command string, interpolates source text, accepts arbitrary flags, or includes a file path in arguments. The child starts in an app-owned empty working directory with a minimal environment that excludes OAuth values, Keychain values, source content, authorization URLs, and vault information. Standard input and output carry only the bounded versioned App Server protocol. Raw standard error is drained and discarded.

The App Server client keeps the feasibility handoff's strict request, thread, turn, terminal-state, and typed-output validation. It uses `approvalPolicy: never`, no dynamic tools, and the least-capable Codex sandbox supported by the pinned schema. Only deterministic application code can convert validated output into a proposal. Codex cannot approve or execute an action.

Cancellation closes the active request, waits a bounded grace interval, terminates the owned child, escalates only to that revalidated owned process if necessary, reaps it, and records one finite result. A crash, malformed frame, identifier mismatch, protocol error, timeout, or unexpected exit fails the job without provider or vault mutation. stderr, prompts, transcripts, paths, process identifiers, arbitrary error descriptions, and partial protocol frames are never retained or shown.

Codex is a child executable on the local Mac, not an app-operated server. Codex may have its own documented service connectivity; the app neither proxies nor supplies credentials for it. Every non-private job passes an explicit outbound context manifest and disclosure check before bytes are sent to the child. Private-mode jobs send no content to Codex and do not persist source bodies.

## Vault capability boundary

Onboarding presents a system folder-selection panel. Vault access does not begin before the user confirms one directory. The resulting root capability and bookmark are local private settings and are never checked into Git, printed, logged, notified, or sent to Codex.

The vault adapter enforces all of the following for every operation:

1. Resolve the saved root, canonicalize it, and require the root to remain a directory.
2. Accept only application-generated relative path components. Reject absolute paths, empty components, `.` and `..`, control characters, alternate separators, and model- or provider-supplied path text.
3. Resolve every existing ancestor and the final existing target under file coordination. Reject symbolic links and any canonical target that is not equal to the selected root or its descendant by path-component comparison.
4. Recheck containment immediately before opening or replacing a file. A stale bookmark, moved root, race, permission error, or containment mismatch fails closed and requests explicit reselection.
5. Read only the exact daily-note or managed file requested by a typed workflow. Do not enumerate the home directory, neighboring directories, the complete selected root, or vault configuration internals.
6. Coordinate writes and atomically replace only the stable managed marker block described by the action-state-machine contract. Preserve all text outside that block.

The unsandboxed operating system process can technically access other user-readable locations. The adapter rules are compensating controls, not a claim that the selected root is kernel-enforced.

## Google credentials and network boundary

Google OAuth records use generic-password items in the data-protection Keychain with these exact keys:

| Service | Account | Value |
|---|---|---|
| `DailyPlanner.GoogleOAuth.v1` | `client-identifier` | OAuth desktop client identifier |
| `DailyPlanner.GoogleOAuth.v1` | `refresh-token` | refresh credential for the bound Google identity and exact granted scope set |

Every item sets `kSecAttrSynchronizable` to false and uses no shared access group. Add, read, replace, revoke, unlink, reset, and cleanup queries always include both exact service and exact account. An access token is memory-only and is discarded after use. The desktop flow proven by the read-only probe requires a client identifier but no stored client secret. OAuth values never fall back to preferences, files, environment variables, command arguments, URLs, model context, or persistence records.

Keychain accessibility remains a gated configuration decision. Until the manual lock/read/unlock acceptance gate passes on the implementation build, both records use the already proven `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, and scheduled work pauses while the Keychain is locked. If the gate proves the required resident behavior, a reviewed configuration revision may migrate the exact `refresh-token` item to `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; the client identifier may remain `WhenUnlockedThisDeviceOnly`. A failed or unrun gate never silently widens accessibility.

Application networking is deny-by-default in the Google adapter. Its external host and path allowlist is exactly:

- `accounts.google.com` at `/o/oauth2/v2/auth`, opened only in the system browser;
- `oauth2.googleapis.com` at `/token` and `/revoke`;
- `gmail.googleapis.com` under `/gmail/v1/`;
- `www.googleapis.com` under `/calendar/v3/`;
- `tasks.googleapis.com` under `/tasks/v1/`.

The IPv4 loopback OAuth callback is local input, not an external endpoint. Redirects to another host, non-TLS external requests, alternate ports, proxy destinations selected by content, analytics, telemetry, remote configuration, and update checks are rejected by application logic. The full authorization URL is constructed in memory, opened once, and never logged, persisted, notified, or sent to Codex. Because v1 is unsandboxed, this network allowlist is not enforced by macOS; compromised code in the process could bypass it.

## Calendar-role isolation

Calendar identifiers and their roles are encrypted private local settings. They are never hard-coded in Git, used as diagnostic identifiers, included in notifications, or sent to Codex. A newly observed calendar has no planning authority and defaults to `Excluded reference` until the user explicitly assigns a role.

- A `Planning` calendar may affect conflict checks, availability, free/busy results, workload, fatigue, summaries, and action generation.
- An `Excluded reference` calendar is manually viewable only. Its data contributes zero to conflict checks, free/busy, workload, fatigue, priority, digests, summaries, proposal context, and action generation.
- Manual viewing fetches only the requested excluded-calendar view, keeps its details out of planning indexes and model context, and does not persist them as source bodies.
- A role never changes because of a calendar name, event content, participant, location, frequency, model result, or inferred behavior.
- A role change requires an explicit user action and an append-only encrypted local audit record containing the old role, new role, local actor, and timestamp. The private identifier remains encrypted and does not enter ordinary logs.
- A role change invalidates affected derived state and unexecuted approvals. Changing to `Excluded reference` removes the calendar's prior contribution and recomputes planning outputs; changing to `Planning` begins contribution only after the next validated sync.

The filter is applied immediately after Calendar retrieval and before aggregation, prioritization, summaries, assistant context, or proposal generation. Downstream components consume an eligible planning stream rather than raw mixed-role events.

## Data flow

### Onboarding and configuration

1. The user selects one vault directory; the vault adapter stores its capability locally.
2. The user enters the local OAuth client credential, completes system-browser consent, and the Google adapter stores the exact Keychain items only after identity and exact-scope validation.
3. The user explicitly assigns calendar roles. Unassigned calendars remain excluded.
4. The app validates the pinned Codex installation from the compiled candidates. No user-supplied executable path is accepted.

### Read, plan, and propose

1. The resident scheduler or an explicit user refresh starts a bounded workflow.
2. The Google adapter obtains a memory-only access token and reads only the approved resources. The vault adapter reads only typed targets inside the selected root.
3. Calendar-role filtering occurs before any derived calculation. Private-mode sources remain memory-only and bypass Codex.
4. For an eligible non-private job, the disclosure checker creates a bounded context manifest, strips credentials, private identifiers, paths, and unauthorized source fields, then sends content to the supervised Codex child.
5. The Codex adapter validates typed output. Deterministic application code turns valid output into a proposal; invalid output becomes a finite failed job.
6. Content persistence follows the binding data-lifecycle matrix. Private-mode source bodies are never written.

### Mutate and reconcile

Every Gmail, Calendar, Tasks, or vault mutation enters the binding action state machine at `proposed`. There is no adapter route around edit, deterministic preflight, canonical review, explicit approval, durable attempt journaling, final preflight, execution, and provider-specific reconciliation. Payload, source, target, disclosure, warning, calendar-role, or provider-capability changes invalidate approval.

Undo is a separate journaled compensating action and is offered only where the provider contract makes it truthful. An uncertain commit enters `unknownOutcome`, blocks automatic retry, and reconciles before any further write. Codex receives no mutation capability and cannot transition an action to `approved` or `executing`.

## Failure handling

| Failure | Required behavior |
|---|---|
| Codex absent, replaced, or version/schema mismatch | Block assistant jobs with a finite status; do not search elsewhere or accept a path. |
| Codex timeout, crash, malformed output, or cancellation | Stop and reap the owned process, discard raw streams, fail the job, and perform no external mutation. |
| OAuth denial, expiry, revocation, account mismatch, or scope mismatch | Fail closed, pause dependent reads and writes, preserve only encrypted queue state, and require full-set reconnection without silent scope widening. |
| Keychain locked, denied, corrupt, or missing | Do not copy a credential elsewhere; pause the workflow and show a generic recovery state. |
| Google timeout after a possible write | Enter `unknownOutcome` and run the provider reconciliation defined by the action state machine before retry. |
| Vault bookmark stale, root missing, or access denied | Stop vault work and require explicit reselection; never discover a replacement. |
| Vault traversal, symlink, race, or containment failure | Reject the operation, record a finite security counter with no path, and require review before retry. |
| Calendar role absent or local role record unreadable | Treat the calendar as `Excluded reference`; do not infer a role or use cached contribution. |
| Local store corruption or key loss | Fail closed, preserve usable non-content receipts, remove unreadable encrypted cache, and rebuild only after explicit reconnection. |
| App crash during a mutation | Recover the durable attempt as `unknownOutcome`; never infer that the provider rejected it. |

Logs and notifications use an allowlist of event names, finite reason codes, bounded counts, and coarse timestamps. They contain no raw email bodies, Calendar details, Tasks details, vault text, prompts, transcripts, stderr, filesystem paths, access or refresh tokens, OAuth client values, private identifiers, or full authorization URLs. Unexpected error descriptions are reduced to finite codes before crossing a diagnostic boundary. Notifications state only that attention, approval, reconnection, or review is required.

## Distribution and update posture

V1 is a single local `.app` used for personal development and operation on one Mac. It may be ad-hoc or development signed for local execution, but the project makes no Developer ID, notarization, Gatekeeper-free installation, App Store, or third-party support claim. No helper, broker, server, installer package, privileged component, login daemon, or automatic updater is included.

Updates are manual replacements performed while the app and its Codex child are stopped. The app records its schema and application version, verifies local migrations before deleting the prior schema, and refuses to open a newer unknown schema. A failed migration leaves the prior local store intact. Adding signing, notarization, a public channel, update signatures, rollback orchestration, App Store distribution, or helper isolation requires a separate reviewed milestone.

## Verification and acceptance gates

A later implementation plan must make each gate independently observable with synthetic fixtures before any personal-data or write canary:

1. **Artifact shape:** one native app, no sandbox entitlement claim, no helper/broker/server target, no listener, no installer, no update client, and no production provider enabled by default.
2. **Dependency direction:** domain and application targets compile without UI or infrastructure imports; fakes exercise every port.
3. **Codex discovery:** tests cover each compiled candidate, missing files, writable link chains, wrong owners, wrong versions, schema mismatch, multiple candidates, and rejection of path, environment, and argument injection. A process-spy test proves direct execution with only the two literal arguments and no shell.
4. **Codex lifecycle:** the existing serial protocol suite remains green and adds launch, cancellation, timeout, app crash recovery, child crash, malformed frames, stderr sentinels, and owned-process cleanup assertions. No captured sentinel may reach logs, notifications, evidence, or persistence.
5. **Vault isolation:** filesystem-spy and adversarial tests prove no access before selection; no home or sibling enumeration; exact-root-only reads; traversal, Unicode normalization, symlink, stale-bookmark, move, replacement-race, and coordinated atomic-write rejection or safe handling. The signed app must pass explicit folder selection and persisted relaunch with a generated fake vault.
6. **Keychain:** recording and signed-app tests assert the two exact service/account queries, data-protection Keychain, the currently approved device-only non-synchronizing accessibility, replacement, revocation, unlink, migration, and exact deletion. No OAuth value may appear in files, defaults, environment, arguments, diagnostics, or URL cache. The manual first-unlock/lock/read/unlock gate and a reviewed configuration revision must pass before locked scheduled work is enabled.
7. **Network:** an injected transport rejects every host, path, scheme, redirect, and method outside the Google allowlist. Offline tests are the default. A live read-only canary still requires explicit user authorization and sanitized boolean evidence.
8. **Private mode and DLP:** spies prove zero Codex submissions and zero persisted source bodies for private jobs. Canary strings representing source content, credentials, paths, private identifiers, stderr, and authorization parameters remain absent from logs, notifications, crash artifacts, persistence metadata, and evidence.
9. **Calendar roles:** truth-table tests prove `Planning` inputs can affect every allowed planning output and `Excluded reference` inputs affect none. New calendars default excluded; content cannot change a role; manual view does not populate planning state; role changes append a local audit record, invalidate approvals, purge prior contribution, and recompute.
10. **Mutation safety:** the complete action-state-machine, canonicalization, concurrency, crash injection, reconciliation, retry, dependency, and Undo suites pass with a global assertion that dry-run milestones make zero Google or vault writes.
11. **Failure and recovery:** Keychain denial, OAuth loss, offline Google, corrupt local state, unavailable vault, unavailable Codex, sleep/wake, duplicate instance, and interrupted manual update all produce finite recoverable states without sensitive output or duplicate work.
12. **Privacy and repository hygiene:** tracked sources, fixtures, docs, and evidence contain no credentials, authorization URLs, personal identifiers, personal source content, or local private paths. Calendar identifiers and roles are runtime local settings only.

Passing these gates does not itself authorize live writes. Live read-only access, first provider writes, and first vault write remain separately reviewed, narrow canaries under the action-state-machine contract.

## Reversibility and cost if the recommendation is wrong

The app keeps Codex, Google, vault, Keychain, scheduling, notifications, and persistence behind separate ports so the distribution boundary can change without changing domain schemas or approval semantics. The selected vault can be forgotten and reselected. OAuth can be revoked and reauthorized. Calendar roles can be changed explicitly and derived state recomputed. The compiled Codex candidate list and version pin can be revised in a reviewed release without adding an arbitrary-path mechanism.

If the unsandboxed recommendation is wrong, the primary cost is security exposure: a defect or compromise has a larger filesystem, subprocess, and network blast radius than the application's logical policy suggests. Migration to a sandboxed main app and helper may require a new installer, signed identities, IPC protocol, bookmark consent, credential migration or reauthorization, process-lifecycle redesign, update coordination, and user support. The adapter boundaries limit domain churn but do not remove that delivery cost.

If the Keychain accessibility choice is too permissive, credentials remain readable to the app after first unlock for longer than intended; if too restrictive in practice, locked resident work cannot run. A class change requires explicit migration or reauthorization and new lock-state evidence. If local-only distribution later proves insufficient, signing, notarization, update authenticity, rollback, and support become new security milestones rather than hidden v1 capabilities.

The accepted v1 trade is therefore narrow: one trusted user's local app, one selected vault capability, fixed Codex discovery, exact credential records, application-level network and data controls, and no claim of OS-enforced containment. Implementation planning is authorized; implementation follows only from the separately reviewed M1 plan and selected execution workflow.
