# M1 Read-Only Shell Handoff

Date: 2026-08-30

Status: implementation acceptance recorded; independent task review and whole-branch verification remain required before any M1 completion claim.

## Safety-gate record

| Gate | Status | Evidence |
| --- | --- | --- |
| Signed build and owned launch cycle | PASS | The serial verifier builds and verifies the signed app, launches only its exact binary, observes its owned PID alive within a bounded poll, terminates and reaps only that PID, then re-verifies the signature. |
| Module dependency direction | PASS | SwiftPM target dependencies remain inward: Domain has no adapter dependency; Application depends only on Domain; Persistence and Platform implement or consume Domain/Application boundaries; UI has no concrete persistence/platform import. |
| Encrypted-settings round trip, tamper rejection, and plaintext absence | PASS | Persistence tests cover the envelope round trip, tamper rejection, and absence of private fixture text in stored bytes. |
| Explicit generated-root bookmark creation with zero vault-content reads/writes | PASS | The integrated acceptance harness uses one generated temporary root and saves only its opaque bookmark through the real encrypted settings store; it has no vault-content reader or writer. |
| Default Excluded-reference role and full exclusion truth table | PASS | Domain and application tests establish missing-role exclusion and verify excluded events influence no planning, aggregate, context, digest, summary, or action path. |
| Separate memory-only manual reference view | PASS | Application tests and the integrated acceptance flow retrieve the requested excluded calendar only through the separate reference view. |
| School-first stable queue | PASS | Priority and application tests verify deterministic School-first ordering for eligible Planning events. |
| Vancouver 06:00 / 12:00 / 21:00 slots, DST, and midnight eligibility | PASS | Local schedule tests cover Vancouver slot generation, DST behavior, and finite midnight eligibility; the integrated acceptance flow exercises the slots and eligible branch. |
| Balanced, accessibility-reviewed three-column shell and offline banner | PASS | Hosted AppKit tests validate the exact 1100×680 shell, accessibility structure, focus, banner, and no-overlap policy; live signed 1280×780 inspection validated balance, banner, settings, and focus. The live exact-1100×680 resize inspection could not be performed because the inspection tool repeatedly failed, so no exact live-size screenshot is claimed. |
| No live Google, Codex, provider write, or vault-content capability | PASS | The serial verifier rejects network, process, vault-I/O, bookmark-resolution, dynamic diagnostic, external-package, and prohibited-target source capabilities; its copied-source inverse canary proves the same hygiene function fails when forbidden content is injected. |
| Live Google read-only canary | BLOCKED_BY_USER_AUTH | No user authorization was supplied; no live Google flow was run. |
| Locked-state Keychain observation | BLOCKED_BY_USER_ACTION | The required lock/read/unlock observation has not been performed. |

## Operating boundary

M1 is an offline native shell. The real-vault selector may create and persist an opaque bookmark after explicit folder selection, but M1 neither resolves it nor reads, enumerates, coordinates, or writes vault content. It contains no live Google/OAuth route, Codex launch, provider write, assistant generation, notification delivery, scheduler timer, midnight write, or action execution capability.

The local-v1 helper design remains v2-only and is not partially introduced here. The two blocked gates above remain blocked rather than being inferred from synthetic coverage.

## Acceptance artifacts

- `DailyPlanner/Tests/DailyPlannerAcceptanceTests/M1SafetyAcceptanceTests.swift` provides the generated-only end-to-end acceptance harness. It uses no `SettingsKeychain`, personal vault, live calendar, credential, or real identifier.
- `DailyPlanner/Tests/verify-m1.sh` is the one serial command: full Swift tests without parallelism, signed build and verification, source hygiene plus inverse forbidden-token canary, diff check, and exact owned-PID lifecycle.
- Every acceptance temporary artifact is under one generated root or verifier-private scratch and has exact, idempotent cleanup. No test creates a Keychain item.
