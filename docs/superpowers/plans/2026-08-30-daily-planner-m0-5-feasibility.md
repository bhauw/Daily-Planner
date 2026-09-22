# Daily Planner M0/M0.5 Feasibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the installed Apple toolchain, official Codex bridge, Google read-only desktop OAuth flow, and chosen macOS security/distribution boundary before any production Daily Planner scaffold or external write exists.

**Architecture:** All probes live under `Spikes/`, use synthetic content and a fake vault, and produce sanitized evidence under `docs/architecture/`. The Codex probe speaks the official version-pinned App Server JSONL protocol over stdio. The Google probe separates deterministic PKCE/loopback tests from a user-authorized read-only canary and stores its temporary refresh credential only in Keychain.

**Tech Stack:** Xcode 26.6, Swift 6.3, SwiftUI, Foundation, Network, CryptoKit, Security, XCTest/Swift Testing, Codex CLI 0.151+, Google OAuth 2.0 REST endpoints.

**Spec: external source “Daily Planner — Brief.md” (local path intentionally omitted).**

## Global Constraints

- No Gmail, Calendar, Tasks, attendee, notification, label, or vault write is allowed.
- The real Obsidian vault, email content, home address, résumé, Calendar details, and Tasks are not probe inputs.
- Google scopes are exactly `openid`, `email`, `https://www.googleapis.com/auth/gmail.readonly`, `https://www.googleapis.com/auth/calendar.readonly`, and `https://www.googleapis.com/auth/tasks.readonly`.
- Google installed apps do not support incremental authorization; this probe requests only the complete read-only scope set above.
- OAuth client IDs, authorization codes, access tokens, refresh tokens, cookies, and full authorization URLs never enter Git, stdout, logs, screenshots, reports, or crash output.
- The Google live canary stops for Braxton's explicit browser consent. Cancellation is a passing safe-exit case.
- Codex receives only synthetic text, runs with `approvalPolicy: never`, a read-only sandbox, no dynamic tools, and no access to Google or the real vault.
- Generate and pin Codex App Server JSON schema from the installed CLI before compiling the client.
- All content-bearing evidence is synthetic or redacted. Temporary Keychain items and fake-vault files are deleted after their tests.
- The production project is not scaffolded by this plan.

---

### Task 1: Signed SwiftUI toolchain probe

**Files:**
- Create: `Spikes/ToolchainProbe/Sources/ToolchainProbeApp/main.swift`
- Create: `Spikes/ToolchainProbe/Resources/Info.plist`
- Create: `Spikes/ToolchainProbe/Scripts/build-and-verify.sh`
- Create: `Spikes/ToolchainProbe/Tests/verify-toolchain.sh`
- Create: `docs/architecture/evidence/toolchain.txt`

**Interfaces:**
- Consumes: `/Applications/Xcode.app`, `xcodebuild`, `xcrun swiftc`, and `codesign`.
- Produces: an ad-hoc-signed local `ToolchainProbe.app` plus sanitized version/build/signature evidence.

- [ ] **Step 1: Write the failing verification script**

```bash
#!/bin/zsh
set -euo pipefail
probe_root="${0:A:h:h}"
app="$probe_root/.build/ToolchainProbe.app"
test -x "$app/Contents/MacOS/ToolchainProbe"
codesign --verify --deep --strict "$app"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" \
  | rg -xq 'com.example.dailyplanner.toolchain-probe'
```

- [ ] **Step 2: Run the verifier and confirm the red state**

Run: `zsh Spikes/ToolchainProbe/Tests/verify-toolchain.sh`

Expected: nonzero exit because `.build/ToolchainProbe.app` does not exist.

- [ ] **Step 3: Add the minimal native app**

```swift
import SwiftUI

@main
struct ToolchainProbeApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Text("Daily Planner")
                    .font(.title2)
                Text("Toolchain ready")
                    .accessibilityIdentifier("toolchain-ready")
            }
            .frame(width: 320, height: 180)
        }
    }
}
```

Use bundle identifier `com.example.dailyplanner.toolchain-probe`, minimum macOS 15.0, and an ad-hoc signature. The build script must compile with `xcrun swiftc -parse-as-library`, assemble the `.app` bundle from the checked-in `Info.plist`, sign with `codesign --force --sign -`, verify it, and never install it into `/Applications`.

- [ ] **Step 4: Build, verify, and launch once**

Run:

```bash
zsh Spikes/ToolchainProbe/Scripts/build-and-verify.sh
zsh Spikes/ToolchainProbe/Tests/verify-toolchain.sh
open Spikes/ToolchainProbe/.build/ToolchainProbe.app
```

Expected: both scripts exit 0; the window shows `Daily Planner` and `Toolchain ready`. Quit the probe after visual verification.

- [ ] **Step 5: Record sanitized evidence and commit**

Record only Xcode version, Swift version, target architecture, bundle identifier, and `codesign` verification result in `docs/architecture/evidence/toolchain.txt`.

```bash
git add Spikes/ToolchainProbe docs/architecture/evidence/toolchain.txt
git commit -m "spike: verify native SwiftUI toolchain"
```

---

### Task 2: Official Codex App Server structured-output probe

**Files:**
- Create: `Spikes/CodexBridgeProbe/Package.swift`
- Create: `Spikes/CodexBridgeProbe/Sources/CodexBridgeCore/AppServerMessage.swift`
- Create: `Spikes/CodexBridgeProbe/Sources/CodexBridgeCore/AppServerProcess.swift`
- Create: `Spikes/CodexBridgeProbe/Sources/CodexBridgeCore/ProbeStateMachine.swift`
- Create: `Spikes/CodexBridgeProbe/Sources/codex-bridge-probe/main.swift`
- Create: `Spikes/CodexBridgeProbe/Tests/CodexBridgeCoreTests/AppServerMessageTests.swift`
- Create: `Spikes/CodexBridgeProbe/Tests/CodexBridgeCoreTests/ProbeStateMachineTests.swift`
- Generate: `Spikes/CodexBridgeProbe/Schemas/` using the installed CLI
- Create: `docs/architecture/evidence/codex-bridge.json`

**Interfaces:**
- Consumes: newline-delimited App Server messages shaped as `AppServerMessage` and the installed `codex` executable path resolved with `/usr/bin/which codex`.
- Produces: `CodexProbeResult(protocolVersion: String, threadStarted: Bool, turnCompleted: Bool, structuredStatus: String, cleanupSucceeded: Bool)`.

- [ ] **Step 1: Generate the installed protocol schema**

Run:

```bash
mkdir -p Spikes/CodexBridgeProbe/Schemas
codex app-server generate-json-schema --out Spikes/CodexBridgeProbe/Schemas
```

Expected: schema generation exits 0. Record `codex --version` beside the generated schema; do not hand-edit generated files.

- [ ] **Step 2: Write failing codec and state-machine tests**

```swift
@Test func decodesThreadStartResponse() throws {
    let line = #"{"id":10,"result":{"thread":{"id":"thr_synthetic"}}}"#
    let message = try AppServerMessage.decode(line)
    #expect(message.id == 10)
    #expect(message.threadID == "thr_synthetic")
}

@Test func completesOnlyAfterMatchingTurnEvent() {
    var state = ProbeStateMachine()
    state.accept(.thread(id: "thr_synthetic"))
    state.accept(.turnStarted(id: "turn_synthetic"))
    state.accept(.turnCompleted(id: "turn_synthetic", status: "completed"))
    #expect(state.phase == .completed)
}
```

- [ ] **Step 3: Run the tests and confirm the red state**

Run: `swift test --package-path Spikes/CodexBridgeProbe`

Expected: compile failure because the core types do not exist.

- [ ] **Step 4: Implement the minimal JSONL process client**

`AppServerProcess` must launch `codex app-server --stdio` with `Process`, write one compact JSON object per line, read stdout one line at a time, retain stderr only in memory with token/path redaction, correlate responses by integer `id`, and terminate the child on cancellation or timeout. It must never invoke shell interpolation.

The live probe sequence is fixed:

1. `initialize` with client name `daily_planner_probe`, version `0.1.0`, and no experimental capability.
2. `initialized` notification.
3. `thread/start` with `cwd` set to a newly created empty temporary directory, `approvalPolicy: never`, `sandbox: readOnly`, and service name `daily_planner_probe`.
4. `turn/start` with synthetic input `Return exactly the structured probe result.` and this output schema:

```json
{
  "type": "object",
  "properties": {
    "source": { "type": "string", "const": "daily-planner-probe" },
    "status": { "type": "string", "enum": ["ok"] }
  },
  "required": ["source", "status"],
  "additionalProperties": false
}
```

5. Wait for the matching `turn/completed`; parse the final agent message as the schema above.
6. Archive the synthetic thread, terminate App Server, and remove the temporary directory.

- [ ] **Step 5: Run unit tests and the live probe**

Run:

```bash
swift test --package-path Spikes/CodexBridgeProbe
swift run --package-path Spikes/CodexBridgeProbe codex-bridge-probe
```

Expected: tests exit 0; the live probe returns `source=daily-planner-probe`, `status=ok`, archives its synthetic thread, and emits no prompt, token, home path, or model transcript.

- [ ] **Step 6: Fault-test and commit**

Tests must cover missing executable, early child exit, malformed JSON, response-ID mismatch, timeout, cancellation, protocol error, and structured-output rejection. Write only the sanitized `CodexProbeResult` plus CLI/schema versions to `docs/architecture/evidence/codex-bridge.json`.

```bash
git add Spikes/CodexBridgeProbe docs/architecture/evidence/codex-bridge.json
git commit -m "spike: prove Codex App Server bridge"
```

---

### Task 3: Google desktop OAuth read-only canary

**Files:**
- Create: `Spikes/GoogleOAuthProbe/Package.swift`
- Create: `Spikes/GoogleOAuthProbe/Sources/GoogleOAuthCore/PKCE.swift`
- Create: `Spikes/GoogleOAuthProbe/Sources/GoogleOAuthCore/OAuthRequest.swift`
- Create: `Spikes/GoogleOAuthProbe/Sources/GoogleOAuthCore/LoopbackCallback.swift`
- Create: `Spikes/GoogleOAuthProbe/Sources/GoogleOAuthCore/KeychainRefreshToken.swift`
- Create: `Spikes/GoogleOAuthProbe/Sources/GoogleOAuthCore/GoogleReadOnlyClient.swift`
- Create: `Spikes/GoogleOAuthProbe/Sources/google-oauth-probe/main.swift`
- Create: `Spikes/GoogleOAuthProbe/Tests/GoogleOAuthCoreTests/PKCETests.swift`
- Create: `Spikes/GoogleOAuthProbe/Tests/GoogleOAuthCoreTests/OAuthRequestTests.swift`
- Create: `Spikes/GoogleOAuthProbe/Tests/GoogleOAuthCoreTests/RedactionTests.swift`
- Create: `docs/architecture/evidence/google-oauth.json`

**Interfaces:**
- Consumes: `DAILY_PLANNER_GOOGLE_CLIENT_ID` from the process environment only; system-browser consent by Braxton.
- Produces: `GoogleReadOnlyProbeResult(scopes: [String], refreshSucceeded: Bool, gmailProfileRead: Bool, calendarListRead: Bool, taskListsRead: Bool, cleanupSucceeded: Bool)` containing no IDs, names, counts, titles, addresses, or tokens.

- [ ] **Step 1: Write deterministic failing PKCE/request tests**

```swift
@Test func authorizationRequestUsesOnlyApprovedReadScopes() throws {
    let request = OAuthRequest(clientID: "synthetic.apps.googleusercontent.com")
    #expect(request.scopes == ApprovedScopes.readOnly)
    #expect(request.redirectURL.host == "127.0.0.1")
    #expect(request.authorizationURL.query?.contains("gmail.modify") == false)
    #expect(request.authorizationURL.query?.contains("calendar.events") == false)
    #expect(request.scopes.contains("https://www.googleapis.com/auth/tasks") == false)
}
```

- [ ] **Step 2: Run tests and confirm the red state**

Run: `swift test --package-path Spikes/GoogleOAuthProbe`

Expected: compile failure because OAuth core types do not exist.

- [ ] **Step 3: Implement PKCE, loopback callback, Keychain, and redaction**

Use `SecRandomCopyBytes` for a 64-byte verifier, `SHA256` for S256 challenge, a random 256-bit `state`, `NWListener` bound to `127.0.0.1` on an ephemeral port, and constant-time state comparison. Reject non-loopback hosts, duplicate callbacks, missing code, state mismatch, callback timeout, and browser cancellation.

Store the temporary refresh token with Security framework service `com.example.dailyplanner.spike.google-oauth`, account `readonly-canary`, and `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Never print Keychain status data beyond success/failure. Cleanup deletes this exact service/account item.

- [ ] **Step 4: Prove the dry-run safety boundary**

Run: `swift run --package-path Spikes/GoogleOAuthProbe google-oauth-probe --dry-run`

Expected: output lists the five approved scope names, confirms loopback/PKCE/state, and prints no client ID, full URL, authorization code, or token.

- [ ] **Step 5: Stop for Braxton's security-sensitive authorization**

Before `--live-readonly`, show Braxton the exact five scopes and explain that the system browser will ask to read Gmail metadata/content, Calendar, Tasks, and email identity. Continue only after explicit approval in chat and browser consent. Cancellation must cleanly exit with no Keychain item.

- [ ] **Step 6: Run the live read-only canary and refresh proof**

With the client ID supplied only through the environment, open the system browser, exchange the code, store the refresh token, discard the first access token, refresh a new access token from Keychain, and call only:

- Gmail `GET /gmail/v1/users/me/profile`
- Calendar `GET /calendar/v3/users/me/calendarList?maxResults=1`
- Tasks `GET /tasks/v1/users/@me/lists?maxResults=1`

The probe records booleans only. It then revokes the temporary grant when supported, deletes the Keychain item, clears `URLCache`, and exits.

- [ ] **Step 7: Fault-test and commit**

Cover state mismatch, denied consent, callback timeout, token endpoint error, refresh failure, account mismatch, Keychain denial, missing scope, accidental write-scope detection, redaction, and cleanup after interruption.

```bash
git add Spikes/GoogleOAuthProbe docs/architecture/evidence/google-oauth.json
git commit -m "spike: prove read-only Google OAuth"
```

---

### Task 4: macOS distribution, vault-bookmark, and Keychain boundary probe

**Files:**
- Create: `Spikes/SecurityBoundaryProbe/Package.swift`
- Create: `Spikes/SecurityBoundaryProbe/Sources/SecurityBoundaryProbeApp/main.swift`
- Create: `Spikes/SecurityBoundaryProbe/Sources/SecurityBoundaryProbeApp/ProbeViewModel.swift`
- Create: `Spikes/SecurityBoundaryProbe/Sources/SecurityBoundaryCore/BookmarkStore.swift`
- Create: `Spikes/SecurityBoundaryProbe/Sources/SecurityBoundaryCore/KeychainProbe.swift`
- Create: `Spikes/SecurityBoundaryProbe/Resources/Info.plist`
- Create: `Spikes/SecurityBoundaryProbe/Resources/Sandbox.entitlements`
- Create: `Spikes/SecurityBoundaryProbe/Resources/Unrestricted.entitlements`
- Create: `Spikes/SecurityBoundaryProbe/Scripts/build-variants.sh`
- Create: `Spikes/SecurityBoundaryProbe/Tests/SecurityBoundaryCoreTests.swift`
- Create: `docs/architecture/evidence/security-boundary.json`

**Interfaces:**
- Consumes: a generated fake vault under the task's temporary directory, one user-selected-folder grant, the installed Codex executable path, and two separately signed app variants.
- Produces: `SecurityBoundaryProbeResult(variant: String, bookmarkRoundTrip: Bool, bookmarkStaleDetected: Bool, keychainRoundTrip: Bool, codexLaunchResult: String, cleanupSucceeded: Bool)`.

- [ ] **Step 1: Write failing bookmark and Keychain tests**

Tests create a temporary fake vault containing only `Daily/2026-08-30.md` with synthetic text. They verify bookmark encode/resolve, stale detection after moving the folder, exact Keychain service/account isolation, and deletion. They never reference the real vault path.

- [ ] **Step 2: Run tests and confirm the red state**

Run: `swift test --package-path Spikes/SecurityBoundaryProbe`

Expected: compile failure because boundary types do not exist.

- [ ] **Step 3: Implement two signed variants**

Build an ad-hoc-signed unsandboxed variant and a sandboxed variant with only:

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.network.client</key><true/>
```

Both variants must use `NSOpenPanel` to select only the generated fake vault, save/resolve a security-scoped bookmark, round-trip a synthetic Keychain value, and attempt `codex --version` without shell interpolation. The sandboxed result may be denial; that is evidence, not a reason to widen entitlements.

- [ ] **Step 4: Run both variants and the lock-state check**

The automated run proves normal unlocked behavior and cleanup. Before the optional locked-state check, start a background helper that attempts to read a synthetic `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` item and writes only `readable=true|false` to the task's private artifact directory. Ask Braxton to lock and unlock the Mac once; never lock it automatically. Delete the item and private artifact immediately after recording the boolean.

- [ ] **Step 5: Record the distribution ruling and commit**

The evidence report compares:

- local development-signed unsandboxed app;
- sandboxed main app with bookmark plus a separately installed/helper Codex process.

Recommend the least-privileged variant that successfully proves fake-vault access and a supported Codex connection. State the cost if the rejected variant is chosen. Record no file path below Braxton's home directory.

```bash
git add Spikes/SecurityBoundaryProbe docs/architecture/evidence/security-boundary.json
git commit -m "spike: test macOS security boundary"
```

---

### Task 5: Architecture evidence handoff

**Files:**
- Create: `docs/architecture/M0.5-Feasibility-Handoff.md`
- Create: `docs/architecture/data-lifecycle-matrix.md`
- Create: `docs/architecture/action-state-machine.md`
- Create: `README.md`

**Interfaces:**
- Consumes: the three JSON/text evidence artifacts and reviewed probe code from Tasks 1–4.
- Produces: pass/fail gate table and binding architecture rulings for the later production scaffold.

- [ ] **Step 1: Write the gate table before conclusions**

The handoff must list every gate as `PASS`, `FAIL`, or `BLOCKED_BY_USER_AUTH`, link the exact evidence file/command, and separate observed behavior from recommendations. No aggregate `PASS` may hide a failed security property.

- [ ] **Step 2: Write the field-level lifecycle matrix**

Rows are source bodies, summaries, drafts, recipients, action payloads, assistant results, context excerpts, style profiles, attachments, tag index, receipts, logs, notifications, Private jobs, OAuth tokens, home-base location, and vault-summary blocks. Columns are source, classification-before-persistence, encrypted local form, Codex transmission, log/notification rule, retention, purge trigger, and rebuild behavior.

- [ ] **Step 3: Write the action state machine and provider reconciliation table**

Define the approved `proposed → edited → preflighted → approved → executing → succeeded | failed | blocked | unknownOutcome` transitions, canonical approval invalidation, Gmail deterministic `Message-ID`/Sent search, Calendar deterministic event ID, Tasks marker/reconciliation, dependency blocking, and provider-specific Undo.

- [ ] **Step 4: Make and document architecture rulings**

Choose the Codex transport, distribution/sandbox model, Keychain accessibility, vault bookmark/file-coordination strategy, Google OAuth publishing/scope strategy, and resident scheduler promise. Each ruling states evidence, rejected alternative, reversibility, and cost if wrong.

- [ ] **Step 5: Run complete verification and commit**

Run all probe tests, re-run the no-secret scan, confirm the real vault was untouched, confirm the temporary Keychain service is absent, and confirm Git contains no client ID/token/full auth URL.

```bash
git add README.md docs/architecture
git commit -m "docs: record Daily Planner feasibility decisions"
```

Expected: the handoff either authorizes the separate production-scaffold plan or names the exact unresolved gate. It never silently weakens the approved brief.
