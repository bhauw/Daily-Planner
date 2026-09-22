# Daily Planner Action State Machine and Provider Reconciliation

This is the binding domain contract for the later production scaffold. It does not authorize a provider write. All M1 clients remain fake and globally dry-run blocked.

## State machine

```text
proposed -> edited -> preflighted -> approved -> executing -> succeeded
    |          ^          |             |           |-----> failed
    |          |          |             |           |-----> blocked
    |          |          |             |           `-----> unknownOutcome
    `----------+----------+-------------+
          any payload/source/target-context mutation returns to edited/review
```

| From | Event / guard | To | Required side effect |
|---|---|---|---|
| none | Valid typed proposal created from eligible sources | `proposed` | Persist encrypted payload, source tokens, dependencies, disclosure draft; no approval |
| `proposed` | User changes, rejects, or accepts fields | `edited` | Record material edit provenance; clear prior preflight/approval if any |
| `edited` | Deterministic preflight passes with no unresolved warning | `preflighted` | Freeze complete review manifest and refreshed source/target snapshots |
| `preflighted` | User approves exactly the displayed manifest; bulk count <= 20 | `approved` | Persist `ApprovalRecord` with schema version + canonical hash + actor/time/tokens/warnings |
| `approved` | Final execution preflight confirms identical canonical hash, fresh source tokens, target interval, dependencies, recipients, attachments, and warnings | `executing` | Durable attempt journal is committed before provider call; serialize overlapping bundles |
| `executing` | Provider commit is positively identified and receipt sanitized | `succeeded` | Persist resource/status receipt and compensating Undo definition where valid |
| `executing` | Provider definitely rejected/no commit and retry policy is exhausted or requires review | `failed` | Persist finite failure; reconcile before any retry if ambiguity is possible |
| `executing` | Required prerequisite failed/paused, authorization missing, conflict appeared, or required information is missing | `blocked` | Record dependency/block reason; independent branches may continue |
| `executing` | Timeout/crash/disconnect could have occurred after provider commit | `unknownOutcome` | Stop automatic retry; enqueue provider-specific reconciliation |
| `unknownOutcome` | Reconciliation proves exact intended commit | `succeeded` | Attach found resource/message to original attempt; never create another |
| `unknownOutcome` | Reconciliation proves no commit | `failed` or `blocked` | A retry requires still-valid approval and a new final preflight; non-idempotent ambiguity stays blocked for manual review |
| `failed` / `blocked` | User edits or source/context changes | `edited` | New canonical manifest; old approval remains audit history but is unusable |
| terminal state | Approved compensating action completes | terminal + linked Undo receipt | Never rewrite original history; compensation is a separate journaled operation |

There is no direct `proposed -> approved`, `edited -> approved`, or `approved -> succeeded` transition. Preflight and a durable execution journal are mandatory.

## Canonical approval and invalidation

`ApprovalRecord.v1` hashes a deterministic canonical encoding, not display text or an in-memory object layout. The encoding uses sorted object keys, explicit null/absent semantics, normalized Unicode and line endings, fixed time/date/time-zone representations, stable array ordering where order is meaningful, sorted sets where it is not, and no floating-point values for exact fields.

The manifest includes:

- schema versions and action/bundle/correlation IDs;
- provider account and target Calendar/Task list/label IDs as opaque identifiers;
- complete To/CC/BCC/reply-all, subject/body, deterministic Gmail `Message-ID`, and attachment names/digests;
- attendees, start/end, IANA time zone, location, reminders, recurrence, `sendUpdates`, target Calendar, deterministic event ID, and label mapping;
- Task title/notes/due date (date-only), list, parent/position when applicable, and stable operation marker;
- Gmail labels/read-state changes and captured prior state;
- source/context disclosure manifest, privacy class, sensitive-data warnings, irreversible effects, risk level, dependency graph, and Undo statement;
- Gmail thread ID + message-ID set + latest history ID + canonical content hash; Calendar/Tasks resource ID + `etag`; target Calendar interval snapshot/token;
- user-visible assumptions and final normalized provider payload bytes/digest.

Any mutation after approval invalidates approval and returns the affected action/bundle to `edited`. This includes execution-time normalization; recipient, attendee, reply-all, attachment, body, date/time/time zone, location, reminder, `sendUpdates`, label/read state, target list/calendar, source token, target interval, privacy/disclosure, warning, dependency, schema, or provider-capability changes. Normalization must happen before review or be reviewed again.

Bulk approval is capped at 20 bundles. Preflight groups new recipients, attendee invitations/cancellations, attachments, sensitive context, irreversible sends, and changed sources. Items with unresolved warnings are excluded, not silently approved.

## Provider reconciliation and Undo

| Operation | Concurrency / idempotency key | Ambiguous-outcome reconciliation | Automatic retry rule | Undo / compensation |
|---|---|---|---|---|
| Gmail send/reply | Deterministic RFC `Message-ID` derived from stable operation ID; bind thread/source message set + history ID + payload digest | Search Sent with `in:sent rfc822msgid:<deterministic-id>` through `messages.list`; fetch candidate metadata and require exact header/payload correlation | Never resend while uncertain. If exact sent message found -> `succeeded`; if search remains inconclusive -> manual review | Irreversible. Never claim recall; no Undo |
| Gmail labels / read state | Source thread/message IDs + latest history/content tokens; captured prior labels/read state | Re-read current state and compare intended delta plus operation receipt | Retry only if current source still matches and the intended delta is absent | Restore captured prior state only while source version matches; otherwise show diff and require approval |
| Calendar create, no attendees | API-valid deterministic event ID derived from stable operation ID; exact target Calendar | `events.get` deterministic ID; a duplicate/409 is reconciled as candidate existing commit only after payload correlation | Safe to repeat only with same deterministic ID and identical approved payload after final preflight | Delete created event after current `etag`/interval recheck; pause on provider/user changes |
| Calendar update/delete, no attendees | Resource ID + current `etag`/`If-Match`; pre-change encrypted snapshot; target interval snapshot | Fetch by resource ID; compare `etag`, current fields, and intended transformation | No blind retry after timeout; reconcile first, then retry only from the current version with still-valid approval | Restore pre-change snapshot or recreate only after fresh `etag`/interval checks; destructive/newer-edit conflicts require fresh approval |
| Calendar create/update/cancel with attendees | Same deterministic ID/`etag` plus exact attendee set and `sendUpdates` | Fetch event and compare attendee state, sequence/status, and intended fields; surface possible notification delivery separately | Never repeat an ambiguous communicating write automatically | Invitation delivery is consequential. Cancellation/update is a new external write with fresh approval; never describe it as silent Undo |
| Task create | Stable opaque operation marker embedded in `notes`; target list + payload digest; no client-supplied Task ID assumption | List/search target list within bounded reconciliation window, find exact marker, then compare title/notes/date-only due/status | Never insert again while uncertain; exact marker match -> attach returned ID and succeed; multiple/no conclusive matches -> manual review | Delete only after marker/resource/current-state recheck; if user changed it, show diff and require approval |
| Task update/delete | Resource ID + `etag`/`If-Match`, marker, encrypted pre-change snapshot | Fetch resource/tombstone and compare current `etag`, marker, and intended state | Reconcile before retry; never use wildcard `If-Match` to overwrite concurrent edits | Restore snapshot/recreate only after current-state check; newer changes or destructive compensation require approval |
| Managed midnight vault block | Date-derived stable start/end markers + standing-authorization version + content digest | Coordinate read, inspect the single marker pair and retry journal, compare digest | Idempotently replace the same block; never append a second block | A later coordinated replace/remove is possible under the narrow standing authorization; preserve all user text outside markers |

## Dependency execution

- A transactional group is a directed acyclic graph of typed actions. Validate acyclicity before approval.
- Execute prerequisites first. A dependent reply must not claim a meeting is confirmed until the required event and preparation Tasks succeed.
- Failed prerequisites block dependents; they never become implicit success through a sibling branch.
- `failed`, `blocked`, and unresolved `unknownOutcome` prerequisites block their descendants. Independent branches may continue.
- A missing route, venue, date, or time blocks only the affected action. Keep it on the paused shelf, correlate it with source/action keys, suppress duplicates, and recheck on related sync and scheduled scans.
- Paused actions expire after 30 days unless pinned and can be dismissed/reopened. Resumption always re-preflights.
- Overlapping bundles touching the same source, recipients/attendees, Calendar interval, Task, or Gmail state are serialized. A later bundle observes the earlier receipt and re-preflights.

## Retry, crash, and recovery invariants

1. Persist the approved canonical payload, source tokens, attempt number, and `executing` journal record before calling a provider.
2. Persist the sanitized provider receipt before marking `succeeded`.
3. After a crash with an open attempt, enter `unknownOutcome`; do not infer failure from missing local completion.
4. Reconcile before retry or compensation. Exponential backoff applies only after the operation is known not to have committed or is safely idempotent under the same key.
5. Auth expiry/revocation pauses writes and retains the encrypted queue. Reauthorization never widens scopes silently and does not resurrect invalid approvals.
6. Invalid Gmail history ID or Calendar sync token triggers a safe full resync of source state, followed by approval invalidation where tokens changed; it never duplicates provider writes.
7. Every retry and Undo creates a new linked receipt. History is append-only and sanitized.

## Provider test seams required before enabling writes

- Fake clock, sleep/wake/DST, timeout-before-commit and timeout-after-commit switches.
- Scripted Gmail Sent search outcomes: none, exact one, multiple, delayed visibility, and changed thread.
- Scripted Calendar insert 409/get match, mismatched payload, `etag` 412, interval conflict, attendee notification, and cancellation.
- Scripted Tasks marker outcomes: none, exact one, multiple, truncated date-only due, changed `etag`, and tombstone.
- Crash injection after journal write, after provider commit, after receipt write, and during compensation.
- Global assertion that no provider adapter receives a write in dry-run/read-only milestones.
- Canonicalization golden fixtures and mutation tests for every manifest field; one-bit change must invalidate approval.
