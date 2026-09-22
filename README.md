# Daily Planner

> A native macOS daily planning app with a local web UI, safety boundaries, and synthetic test fixtures.

**Public snapshot:** `0.2.0`

**Project status:** Phase One is complete and Phase Two is in progress. The read-only planning shell is being extended with richer mail and task workflows while the offline safety foundation remains the release gate.

If you build on this project, please credit **bhauw/Daily-Planner** and link back to this repository.

## What This Is

Daily Planner is an app project exploring a privacy-conscious native macOS planner with a local web interface. The repository contains the application source, supporting probes, tests, architecture notes, and synthetic fixtures used for offline verification.

This repository contains disposable M0/M0.5 probes, the approved local-v1 architecture, the M1 read-only shell, and the M2A Google read-only foundation for a private native macOS Daily Planner. Automated acceptance uses synthetic content and generated roots; no Google write or vault-content access is authorized.

## Current decision

- Native SwiftUI toolchain: `PASS`
- Official Codex App Server v2 transport: `PASS` and selected
- Deterministic Google OAuth safety boundary: `PASS`
- Live Google read-only canary: `BLOCKED_BY_USER_AUTH`
- Signed user-selected persisted-bookmark runs: `PASS` in both variants
- Locked-state Keychain observation: `BLOCKED_BY_USER_ACTION`
- Sandboxed no-panel bookmark save and sandboxed direct Codex launch: observed `FAIL`, with no denial cause inferred
- Personal local-v1 distribution: approved as one unsandboxed native app with explicit compensating controls
- Sandboxed main-app/helper isolation: deferred to a new v2-only feasibility design
- M1 read-only shell: preserved as the historical offline gate
- M2A Google read-only foundation: implementation and whole-branch review complete; one non-production verifier interruption race is explicitly waived; live canary remains user-authorized

The approved M2A plan authorizes the offline Google read-only foundation. Live Google access remains user-authorized; provider writes, vault-content access, and locked scheduling are not included. M1 remains the preserved offline shell until a live read-only canary is explicitly approved.

## Project Status

### Completed

- Established the native macOS application and local web-host architecture.
- Added deterministic OAuth, Keychain, vault-boundary, and loopback API safety checks.
- Built the read-only planning shell with synthetic calendar, mail, and task fixtures.
- Added offline acceptance coverage for the Swift and web layers.
- Published only sanitized source, tests, synthetic fixtures, and project documentation.
- Added the first in-context reply-drafting workflow and expanded mail workbench behavior.
- Added user-made topic colors and task placement between existing schedule blocks.

### Partially Finished

- The live read-only provider canary still requires an explicit user-authorized run.
- Locked-state Keychain behavior remains an interactive verification item.
- Sandboxed app/helper isolation is deferred to a future architecture pass.
- Live provider content remains behind the connection boundary and is not used by automated tests.
- The reply-drafting workflow still requires an explicitly configured assistant and user approval before any external action.
- Packaging and release automation remain local development workflows rather than hosted CI.

### Next Steps

1. Add focused tests for reply drafting, mail state transitions, and the new task/topic workflows.
2. Complete the user-authorized live read-only canary without recording credentials or provider content.
3. Improve setup and local verification documentation using synthetic examples only.
4. Revisit sandboxed app/helper isolation after the local-v1 architecture is stable.

## Read first

- [M0.5 feasibility handoff](docs/architecture/M0.5-Feasibility-Handoff.md)
- [M1 read-only shell handoff](docs/architecture/M1-Read-Only-Shell-Handoff.md)
- [M2A Google read-only handoff](docs/architecture/M2A-Google-Read-Only-Handoff.md)
- [Approved local-v1 distribution design](docs/superpowers/specs/2026-08-30-daily-planner-local-v1-distribution-design.md)
- [M1 read-only shell implementation plan](docs/superpowers/plans/2026-08-30-daily-planner-m1-read-only-shell.md)
- [M2A Google read-only foundation plan](docs/superpowers/plans/2026-08-30-daily-planner-m2a-google-read-only-foundation.md)
- [Field-level data lifecycle](docs/architecture/data-lifecycle-matrix.md)
- [Action state machine and provider reconciliation](docs/architecture/action-state-machine.md)
- [Sanitized evidence](docs/architecture/evidence)

## Repository layout

```text
Spikes/
  ToolchainProbe/          signed SwiftUI build/launch probe
  CodexBridgeProbe/        version-pinned App Server v2 JSONL probe
  GoogleOAuthProbe/        offline OAuth boundary + user-gated live canary
  SecurityBoundaryProbe/   signed sandbox/vault/Keychain/Codex boundary probe
docs/architecture/
  evidence/                sanitized machine-readable evidence
  M0.5-Feasibility-Handoff.md
  data-lifecycle-matrix.md
  action-state-machine.md
docs/superpowers/
  specs/                   approved architecture decisions
  plans/                   reviewed implementation plans
```

## Safe verification

Run Swift builds serially. In particular, never run the Codex subprocess suite alongside any other Swift build: the identical suite hung under three-way build contention and passed alone 18/18 in 4.727 seconds.

```bash
zsh Spikes/ToolchainProbe/Scripts/build-and-verify.sh
zsh Spikes/ToolchainProbe/Tests/verify-toolchain.sh --launch-cycle
zsh DailyPlanner/Tests/verify-m2a.sh

codex_scratch="$(mktemp -d /tmp/daily-planner-codex.XXXXXX)"
swift test --package-path Spikes/CodexBridgeProbe --scratch-path "$codex_scratch" --no-parallel

google_scratch="$(mktemp -d /tmp/daily-planner-google.XXXXXX)"
swift test --package-path Spikes/GoogleOAuthProbe --scratch-path "$google_scratch" --jobs 1
swift run --package-path Spikes/GoogleOAuthProbe --scratch-path "$google_scratch" --skip-build google-oauth-probe --dry-run

security_scratch="$(mktemp -d /tmp/daily-planner-security.XXXXXX)"
swift test --disable-index-store --package-path Spikes/SecurityBoundaryProbe --scratch-path "$security_scratch"
Spikes/SecurityBoundaryProbe/Scripts/build-variants.sh
```

Remove the three explicit scratch directories after the commands finish. Do not run `--live-readonly`, the interactive variants runner, or the lock-state helper without the owner's required authorization/action.

After M2A, `DailyPlanner/Tests/verify-m2a.sh` is the authoritative offline Daily Planner gate. `verify-m1.sh` remains a historical M1 check. The M2A verifier does not open a Google browser flow, access a real OAuth credential or Keychain item, or send provider traffic.

## Safety boundaries

- The real-vault permission selector stores only an opaque bookmark after explicit selection; M1 does not resolve it or read or write vault content.
- M2A permits only the exact read-only Google scope contract behind an explicit user Connect action; automated acceptance performs no live canary, Gmail, Calendar, or Tasks access, and no provider write.
- Codex receives synthetic probe text only, with `approvalPolicy: never`, no dynamic tools, and no Google/vault tools.
- No client identifier, authorization code, token, cookie, full authorization URL, private path, or provider content belongs in Git or diagnostic output.
- The real Obsidian vault is prohibited as probe input. The security probe accepts only its generated one-note `FakeVault`.
- Probe Keychain items and temporary files are exact-scoped and must be absent after verification.
- M2A visible calendar and preview content remains synthetic until M2B; the connection foundation does not yet display live provider data.
