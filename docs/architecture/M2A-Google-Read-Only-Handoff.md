# M2A Google Read-Only Handoff

Date: 2026-09-06

Status: implementation and whole-branch review complete; one non-production verifier interruption race is explicitly waived by the user. The live status remains `BLOCKED_BY_USER_AUTH`.

## What M2A provides

M2A adds the explicit Google connection foundation: exact ordered read-only scopes, bounded loopback authorization, exact device-local OAuth Keychain records, allowlisted read transport, finite connection workflow states, and Connect-focused UI. Construction and standard launch do not start a browser, read credentials, or send network traffic.

The signed app must still be launched in a separately authorized canary mode, and the user must explicitly click Connect and consent, before any live read-only claim can be made.

## Offline acceptance record

| Gate | Offline result | Boundary |
| --- | --- | --- |
| Exact scopes and OAuth Keychain identities | Executable Swift tests | The serial suite proves the literal five-scope order and the only two OAuth Keychain account names through injected seams. |
| Network policy | Executable Swift tests and source hygiene | Google transport accepts only the exact provider GETs plus token/revoke OAuth POSTs; provider writes and unexpected hosts are rejected. |
| Source capability boundary | M2A hygiene gate | Foundation networking and Network.framework are permitted only in `DailyPlannerGoogle`; system browser opening is permitted only in `MacSystemBrowser.swift`. Codex/process launch, vault resolution/content I/O, notifications, scheduler/login APIs, dynamic logs, and external packages are rejected. |
| Inverse canaries | Four scratch-only copies | Injected write scope, provider DELETE, unexpected provider host, and dynamic log each make the same hygiene function fail with a named class and file. |
| Signed lifecycle | Verifier plus explicit waiver | The verifier builds/signs the app and passes the normal 207-test lifecycle gate and exact standard-mode guardian handshake. A rare fast-leader interruption race in the non-production verifier remains deferred under the user-authorized release waiver; it does not run in the app and no live PID/provider operation is affected. |
| Evidence privacy | Sanitized schema and launch/evidence scan | Captured launch output and every verifier-generated evidence artifact are sanitized and scanned for credential, authorization-URL, provider-content, and private-path sentinels without printing a matched value. |
| Worktree and scratch cleanup | Hash-only baseline comparison and EXIT trap | The verifier compares pre/post staged, unstaged, full-status, and untracked-content fingerprints, preserving the pre-existing `HANDOFF.md` modification, then removes only its validated private scratch root after a bounded quiet window. |

`DailyPlanner/Tests/verify-m2a.sh` is authoritative after M2A. `DailyPlanner/Tests/verify-m1.sh` remains available as the historical M1 gate.

## Evidence and live boundary

`docs/architecture/evidence/google-oauth.json` is a sanitized contract, not live evidence. It keeps the top-level `BLOCKED_BY_USER_AUTH` status and records only exact scopes, finite statuses, booleans, and null observations.

Automated acceptance did not open a live browser, access Google data, use a real OAuth credential, create/read/delete a real Keychain item, or send provider traffic. It did not run the signed live canary. No live identity, credential, authorization value, authorization URL, provider response, or private path is recorded here.

## Product boundary and next gate

M2A is connection plus the initial read-only canary only. The visible calendar and preview data remain M1 synthetic until M2B; M2A does not display live provider data, create provider content, execute actions, read vault contents, run a scheduler, or send notifications.

The whole-branch comparison against the M2A plan/specification is complete with no remaining Critical or Important findings; deferred Minor items remain ledgered for later cleanup. Do not broaden this handoff into provider writes, merge, or push. A later user-present authorization is required to advance the live status.
