# Daily Planner M2A Google Read-Only Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an explicitly user-started, exact-scope Google read-only connection to the signed Daily Planner app without adding provider writes, automatic network access, source-content synchronization, or real-vault access.

**Architecture:** Domain owns finite connection values and capability ports; Application owns the two-phase connection and rollback workflow; Persistence owns two exact OAuth Keychain records and private-settings migration; `DailyPlannerGoogle` owns OAuth, loopback, allowlisted HTTP, and the three-read canary; Platform opens the system browser; UI exposes explicit connection controls. Production composition contains the real read-only adapter but performs no network or browser action until the user clicks Connect.

**Tech Stack:** Swift 6.3, SwiftPM, macOS 15+, Swift Concurrency, CryptoKit, Security.framework, Network.framework, Foundation URLSession, AppKit, SwiftUI, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-30-daily-planner-m2-read-only-vertical-slice-design.md`

## Global Constraints

- Exact scopes, in order: `openid`, `email`, `https://www.googleapis.com/auth/gmail.readonly`, `https://www.googleapis.com/auth/calendar.readonly`, `https://www.googleapis.com/auth/tasks.readonly`.
- Requested scope order must match exactly; granted scopes compare as an exact set. Missing, additional, or write scopes fail closed.
- Provider operations are GET-only. Only OAuth token exchange/refresh and explicit revoke may use POST.
- Browser/network/real-Keychain activity requires an explicit user action. Automated tests use injected fakes and synthetic `.example.test` identities only.
- OAuth values never enter source, environment, arguments, preferences, files, stdout/stderr, logs, evidence, crash text, or UI status. Only the exact Keychain records may persist client identifier and refresh token.
- Keychain service is `DailyPlanner.GoogleOAuth.v1`; accounts are exactly `client-identifier` and `refresh-token`; every query uses the data-protection Keychain, `kSecAttrSynchronizable=false`, no access group, and `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` for stored values.
- No Google provider mutation protocol, implementation, target dependency, route, or source token may be introduced.
- No Codex, vault-content read/write, notification, timer, scheduler, launch-at-login, action approval, or action execution capability belongs in M2A.
- Newly observed calendars remain M1 synthetic in M2A. Calendar-role behavior and the Excluded-reference default must remain unchanged.
- All visible root/settings states show `Read-only · no actions executed`; `canExecuteExternalAction` remains false.
- Do not add external Swift packages. Keep target dependencies inward and preserve the signed-app lifecycle verifier.
- Implement every production behavior through RED → verify RED → GREEN → verify GREEN. Tests assert real component behavior; fakes exist only at browser, listener, HTTP, Keychain, clock, and settings boundaries.
- No personal identifier, local private path, credential, authorization URL, provider content, or real account value may enter Git or evidence.

---

### Task 1: Domain connection contracts and encrypted identity field

**Files:**
- Create: `DailyPlanner/Sources/DailyPlannerDomain/GoogleConnection.swift`
- Modify: `DailyPlanner/Sources/DailyPlannerDomain/PrivateSettings.swift`
- Create: `DailyPlanner/Tests/DailyPlannerDomainTests/GoogleConnectionTests.swift`

**Interfaces:**
- Produces: `GoogleIdentityBinding`, `GooglePendingIdentity`, `GoogleConnectionReceipt`, `GoogleCredentialPresence`, `GoogleConnectionControllerError`, `GoogleConnectionControlling`, `GoogleOAuthCredentialStoring`, and `SystemBrowserOpening`.
- Produces: `PrivateSettings.googleAccountBinding: GoogleIdentityBinding?` with schema version 2 and a default `nil` initializer argument so existing call sites compile.
- Consumes: Foundation `URL`; no adapter, Security, AppKit, or network imports.

- [ ] **Step 1: Write failing domain tests**

```swift
func testIdentityBindingNormalizesCaseAndOuterWhitespace() throws {
    let binding = try GoogleIdentityBinding(normalizing: "  Student@Example.Test  ")
    XCTAssertEqual(binding.normalizedEmail, "student@example.test")
}

func testIdentityBindingRejectsControlCharactersAndMalformedAddresses() {
    for value in ["", "missing-at.example.test", "two@@example.test", "line@example.test\nInjected"] {
        XCTAssertThrowsError(try GoogleIdentityBinding(normalizing: value)) { error in
            XCTAssertEqual(error as? GoogleIdentityBindingError, .invalidEmail)
        }
    }
}

func testEmptySettingsHaveNoGoogleIdentityAndUseSchemaTwo() {
    XCTAssertEqual(PrivateSettings.empty.schemaVersion, 2)
    XCTAssertNil(PrivateSettings.empty.googleAccountBinding)
}
```

- [ ] **Step 2: Verify RED**

Run: `swift test --package-path DailyPlanner --filter GoogleConnectionTests --no-parallel`

Expected: compile failure because the Google connection types and settings field do not exist.

- [ ] **Step 3: Implement the minimal domain contracts**

```swift
public struct GoogleIdentityBinding: Codable, Equatable, Sendable {
    public let normalizedEmail: String

    public init(normalizing value: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pieces = normalized.split(separator: "@", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              !pieces[0].isEmpty,
              pieces[1].contains("."),
              !normalized.contains(where: { $0.isWhitespace }),
              !normalized.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw GoogleIdentityBindingError.invalidEmail
        }
        normalizedEmail = normalized
    }
}

public struct GooglePendingIdentity: Equatable, Sendable {
    public let displayEmail: String
    public let binding: GoogleIdentityBinding
}

public struct GoogleConnectionReceipt: Equatable, Sendable {
    public let scopes: [String]
    public let refreshSucceeded: Bool
    public let gmailProfileRead: Bool
    public let calendarListRead: Bool
    public let taskListsRead: Bool
    public let binding: GoogleIdentityBinding
}

public enum GoogleCredentialPresence: Equatable, Sendable { case none, clientOnly, complete, inconsistent }
public enum GoogleConnectionProgress: Equatable, Sendable { case connecting, awaitingConsent }
public enum GoogleOAuthCredentialStoreError: Equatable, Error, Sendable {
    case invalidValue, unavailable, malformed
}
public enum GoogleConnectionControllerError: Equatable, Error, Sendable {
    case notConfigured, invalidConfiguration, cancelled, offline, scopeMismatch
    case identityMismatch, credentialUnavailable, providerUnavailable, cleanupRequired
}

public protocol GoogleOAuthCredentialStoring: Sendable {
    func storeClientIdentifier(_ value: String) throws
    func loadClientIdentifier() throws -> String?
    func storeRefreshToken(_ value: String) throws
    func loadRefreshToken() throws -> String?
    func deleteAll() throws
    func presence() throws -> GoogleCredentialPresence
}

public protocol GoogleConnectionControlling: Sendable {
    func saveClientIdentifier(_ value: String) throws
    func credentialPresence() throws -> GoogleCredentialPresence
    func begin(
        progress: @escaping @Sendable (GoogleConnectionProgress) async -> Void
    ) async throws -> GooglePendingIdentity
    func confirmPendingIdentity() async throws -> GoogleConnectionReceipt
    func cancelPendingConnection() async
    func disconnect() async throws
}

public protocol SystemBrowserOpening: Sendable { func open(_ url: URL) async -> Bool }
```

Set `PrivateSettings.currentSchemaVersion = 2`, add the optional binding, and preserve all existing initializer call sites through `googleAccountBinding: GoogleIdentityBinding? = nil`.

- [ ] **Step 4: Verify GREEN and regression safety**

Run: `swift test --package-path DailyPlanner --filter GoogleConnectionTests --no-parallel`

Expected: 3 tests pass.

Run: `swift test --package-path DailyPlanner --filter DailyPlannerDomainTests --no-parallel`

Expected: all Domain tests pass.

- [ ] **Step 5: Commit**

```bash
git add DailyPlanner/Sources/DailyPlannerDomain DailyPlanner/Tests/DailyPlannerDomainTests
git commit -m "feat: define Google read-only connection contracts"
```

### Task 2: Private-settings v1-to-v2 migration

**Files:**
- Modify: `DailyPlanner/Sources/DailyPlannerPersistence/EncryptedPrivateSettingsStore.swift`
- Modify: `DailyPlanner/Tests/DailyPlannerPersistenceTests/EncryptedPrivateSettingsStoreTests.swift`

**Interfaces:**
- Consumes: `PrivateSettings.currentSchemaVersion == 2` and optional `googleAccountBinding` from Task 1.
- Produces: authenticated v1 plaintext migration to an in-memory v2 `PrivateSettings`; v2 writes only; unsupported versions remain `.unsupportedSchema`.

- [ ] **Step 1: Write failing migration and confidentiality tests**

```swift
func testVersionOnePlaintextMigratesToVersionTwoWithoutGoogleBinding() throws {
    try writeLegacyV1Settings(calendarID: "synthetic-legacy-calendar")
    let loaded = try makeStore(key: Data(repeating: 0x2A, count: 32)).load()
    XCTAssertEqual(loaded.schemaVersion, 2)
    XCTAssertNil(loaded.googleAccountBinding)
    XCTAssertEqual(loaded.calendarRoles[CalendarID(rawValue: "synthetic-legacy-calendar")], .planning)
}

func testVersionTwoRoundTripEncryptsGoogleIdentity() throws {
    let store = makeStore(key: Data(repeating: 0x2A, count: 32))
    var settings = PrivateSettings.empty
    settings.googleAccountBinding = try GoogleIdentityBinding(normalizing: "owner@example.test")
    try store.replace(settings)
    XCTAssertEqual(try store.load(), settings)
    XCTAssertNil(try Data(contentsOf: envelopeURL).range(of: Data("owner@example.test".utf8)))
}

func testUnsupportedFuturePlaintextSchemaFailsAsUnsupportedSchema() throws {
    try writeAuthenticatedPlaintext(Data(#"{"schemaVersion":3}"#.utf8))
    XCTAssertThrowsError(try makeStore(key: Data(repeating: 0x2A, count: 32)).load()) { error in
        XCTAssertEqual(error as? PrivateSettingsStoreError, .unsupportedSchema)
    }
}
```

Define the test-only helpers in the same test file; they seal independently encoded fixture bytes with the literal test key and existing envelope format, never the production migration:

```swift
private struct LegacySettingsV1Fixture: Encodable {
    let schemaVersion = 1
    let vaultBookmark: Data? = nil
    let calendarRoles: [CalendarID: CalendarRole]
    let calendarRoleAudit: [CalendarRoleAuditEntry] = []
}

private func writeLegacyV1Settings(calendarID: String) throws {
    let payload = LegacySettingsV1Fixture(
        calendarRoles: [CalendarID(rawValue: calendarID): .planning]
    )
    try writeAuthenticatedPlaintext(JSONEncoder().encode(payload))
}

private func writeAuthenticatedPlaintext(_ plaintext: Data) throws {
    let key = SymmetricKey(data: Data(repeating: 0x2A, count: 32))
    let sealed = try AES.GCM.seal(plaintext, using: key)
    let envelope = EncryptedEnvelope(
        schemaVersion: 1,
        algorithm: "AES.GCM.256",
        keyVersion: 1,
        sealedBox: try XCTUnwrap(sealed.combined)
    )
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    try JSONEncoder().encode(envelope).write(to: envelopeURL, options: .atomic)
}
```

- [ ] **Step 2: Verify RED**

Run: `swift test --package-path DailyPlanner --filter EncryptedPrivateSettingsStoreTests --no-parallel`

Expected: migration test fails because v1 is rejected and the v2 binding is not decoded.

- [ ] **Step 3: Implement version-gated decode and migration**

Decode a minimal schema header first, then switch explicitly:

```swift
private struct SettingsSchemaHeader: Decodable { let schemaVersion: Int }

private struct LegacyPrivateSettingsV1: Decodable {
    let vaultBookmark: Data?
    let calendarRoles: [CalendarID: CalendarRole]
    let calendarRoleAudit: [CalendarRoleAuditEntry]
}

private func decodeSettings(_ plaintext: Data) throws -> PrivateSettings {
    let decoder = JSONDecoder()
    let version: Int
    do { version = try decoder.decode(SettingsSchemaHeader.self, from: plaintext).schemaVersion }
    catch { throw PrivateSettingsStoreError.readFailed }
    switch version {
    case 1:
        let legacy = try decoder.decode(LegacyPrivateSettingsV1.self, from: plaintext)
        return PrivateSettings(
            vaultBookmark: legacy.vaultBookmark,
            calendarRoles: legacy.calendarRoles,
            calendarRoleAudit: legacy.calendarRoleAudit,
            googleAccountBinding: nil
        )
    case PrivateSettings.currentSchemaVersion:
        return try decoder.decode(PrivateSettings.self, from: plaintext)
    default:
        throw PrivateSettingsStoreError.unsupportedSchema
    }
}
```

Map malformed supported payloads to `.readFailed`, preserve authentication failures, and update the old unsupported-settings test to use schema 3.

- [ ] **Step 4: Verify GREEN**

Run: `swift test --package-path DailyPlanner --filter EncryptedPrivateSettingsStoreTests --no-parallel`

Expected: all encrypted-settings tests pass, including legacy migration and ciphertext absence.

- [ ] **Step 5: Commit**

```bash
git add DailyPlanner/Sources/DailyPlannerPersistence/EncryptedPrivateSettingsStore.swift DailyPlanner/Tests/DailyPlannerPersistenceTests/EncryptedPrivateSettingsStoreTests.swift
git commit -m "feat: migrate private settings for Google identity"
```

### Task 3: Exact production OAuth Keychain records

**Files:**
- Modify: `DailyPlanner/Sources/DailyPlannerPersistence/SettingsKeychain.swift`
- Create: `DailyPlanner/Sources/DailyPlannerPersistence/GoogleOAuthKeychain.swift`
- Create: `DailyPlanner/Tests/DailyPlannerPersistenceTests/GoogleOAuthKeychainTests.swift`

**Interfaces:**
- Consumes: `GoogleOAuthCredentialStoring` and `GoogleCredentialPresence` from Task 1.
- Produces: `GoogleOAuthKeychain` with exact two-record queries; reuses internal `KeychainCalling` and an internal `SecurityKeychainCaller` made visible across the Persistence target.

- [ ] **Step 1: Write failing exact-query tests**

```swift
func testClientIdentifierAndRefreshTokenUseOnlyExactDeviceLocalRecords() throws {
    let caller = RecordingKeychainCaller()
    let store = GoogleOAuthKeychain(caller: caller)
    try store.storeClientIdentifier("synthetic-client.apps.example.test")
    try store.storeRefreshToken("synthetic-refresh-canary")
    XCTAssertEqual(caller.recordedCalls(), [
        .add(googleAddSnapshot(account: "client-identifier", dataLength: 34)),
        .add(googleAddSnapshot(account: "refresh-token", dataLength: 24)),
    ])
}

func testPresenceDistinguishesNoneClientOnlyCompleteAndInconsistent() throws {
    XCTAssertEqual(try makeStore(client: nil, refresh: nil).presence(), .none)
    XCTAssertEqual(try makeStore(client: "client", refresh: nil).presence(), .clientOnly)
    XCTAssertEqual(try makeStore(client: "client", refresh: "refresh").presence(), .complete)
    XCTAssertEqual(try makeStore(client: nil, refresh: "refresh").presence(), .inconsistent)
}

func testDeleteAllAttemptsBothExactAccountsAndIsIdempotent() throws {
    let caller = RecordingKeychainCaller(mutationStatuses: [errSecItemNotFound, errSecSuccess])
    try GoogleOAuthKeychain(caller: caller).deleteAll()
    XCTAssertEqual(caller.recordedCalls(), [
        .delete(googleBaseSnapshot(account: "client-identifier")),
        .delete(googleBaseSnapshot(account: "refresh-token")),
    ])
}
```

The snapshot helper includes class GenericPassword, service `DailyPlanner.GoogleOAuth.v1`, the literal account, data-protection `true`, synchronizable `false`, and no other keys; add snapshots also include WhenUnlockedThisDeviceOnly and the literal data length.

Define `ScriptedGoogleKeychainCaller` in the new test file as a `KeychainCalling` recorder keyed by the query's account. `makeStore(client:refresh:)` seeds only those two account responses. It must reject any third account in the fake with a test failure, so an unexpected production query cannot satisfy the fixture.

- [ ] **Step 2: Verify RED**

Run: `swift test --package-path DailyPlanner --filter GoogleOAuthKeychainTests --no-parallel`

Expected: compile failure because `GoogleOAuthKeychain` does not exist.

- [ ] **Step 3: Implement exact store behavior**

```swift
public struct GoogleOAuthKeychain: GoogleOAuthCredentialStoring, Sendable {
    public static let service = "DailyPlanner.GoogleOAuth.v1"
    public static let clientAccount = "client-identifier"
    public static let refreshAccount = "refresh-token"

    public func storeClientIdentifier(_ value: String) throws { try replace(value, account: Self.clientAccount) }
    public func loadClientIdentifier() throws -> String? { try load(account: Self.clientAccount) }
    public func storeRefreshToken(_ value: String) throws { try replace(value, account: Self.refreshAccount) }
    public func loadRefreshToken() throws -> String? { try load(account: Self.refreshAccount) }
}
```

`replace` rejects empty/control-containing values, adds first, updates only the exact duplicate record, and maps denial/corruption to `.credentialUnavailable`. `deleteAll` always attempts both deletes and throws only after both attempts. `presence` performs the two exact reads and never returns their values.

- [ ] **Step 4: Verify GREEN and existing Keychain regression tests**

Run: `swift test --package-path DailyPlanner --filter GoogleOAuthKeychainTests --no-parallel`

Expected: all new query tests pass.

Run: `swift test --package-path DailyPlanner --filter SettingsKeychainTests --no-parallel`

Expected: all existing private-settings Keychain tests pass unchanged.

- [ ] **Step 5: Commit**

```bash
git add DailyPlanner/Sources/DailyPlannerPersistence DailyPlanner/Tests/DailyPlannerPersistenceTests
git commit -m "feat: store exact Google OAuth credentials"
```

### Task 4: Google target, exact scopes, PKCE, state, and request construction

**Files:**
- Modify: `DailyPlanner/Package.swift`
- Create: `DailyPlanner/Sources/DailyPlannerGoogle/ApprovedGoogleScopes.swift`
- Create: `DailyPlanner/Sources/DailyPlannerGoogle/GoogleOAuthRequest.swift`
- Create: `DailyPlanner/Sources/DailyPlannerGoogle/PKCE.swift`
- Create: `DailyPlanner/Tests/DailyPlannerGoogleTests/GoogleOAuthRequestTests.swift`
- Create: `DailyPlanner/Tests/DailyPlannerGoogleTests/PKCETests.swift`

**Interfaces:**
- Produces SwiftPM product/target `DailyPlannerGoogle` depending only on `DailyPlannerDomain`; test target depends on Domain, Persistence, and Google.
- Produces exact `ApprovedGoogleScopes.readOnly`, `GoogleOAuthRequest`, `PKCEPair`, and `OAuthState` for Tasks 5–7.

- [ ] **Step 1: Write failing request and cryptography tests**

```swift
func testRequestUsesExactScopesLoopbackPKCEAndNoIncrementalAuthorization() throws {
    let request = try GoogleOAuthRequest(
        clientIdentifier: "synthetic-client.apps.example.test",
        redirectPort: 43117,
        pkce: PKCEPair(verifier: String(repeating: "a", count: 43), challenge: "literal-challenge"),
        state: String(repeating: "b", count: 43)
    )
    XCTAssertEqual(request.redirectURL.absoluteString, "http://127.0.0.1:43117/oauth/callback")
    let items = try XCTUnwrap(URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
    XCTAssertEqual(items.first(where: { $0.name == "scope" })?.value, ApprovedGoogleScopes.readOnly.joined(separator: " "))
    XCTAssertEqual(items.first(where: { $0.name == "include_granted_scopes" })?.value, "false")
    XCTAssertEqual(items.first(where: { $0.name == "code_challenge_method" })?.value, "S256")
}

func testAnyScopeOrderOrMembershipChangeIsRejected() {
    let changedSets = [
        Array(ApprovedGoogleScopes.readOnly.reversed()),
        Array(ApprovedGoogleScopes.readOnly.dropLast()),
        ApprovedGoogleScopes.readOnly + ["https://www.googleapis.com/auth/gmail.modify"],
    ]
    for scopes in changedSets {
        XCTAssertThrowsError(try GoogleOAuthRequest(clientIdentifier: "client", redirectPort: 43117, scopes: scopes))
    }
}

func testGeneratedPKCEAndStateMeetEntropyAndAlphabetContracts() throws {
    let pkce = try PKCEPair.generate()
    let state = try OAuthState.generate()
    XCTAssertTrue((43...128).contains(pkce.verifier.count))
    XCTAssertEqual(pkce.method, "S256")
    XCTAssertGreaterThanOrEqual(state.count, 43)
    XCTAssertTrue(state.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) })
}
```

- [ ] **Step 2: Verify RED**

Run: `swift test --package-path DailyPlanner --filter DailyPlannerGoogleTests --no-parallel`

Expected: package/test-target failure because the Google target and types do not exist.

- [ ] **Step 3: Add the target and implement exact primitives**

```swift
public enum ApprovedGoogleScopes {
    public static let readOnly = [
        "openid",
        "email",
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/tasks.readonly",
    ]
}
```

Construct only `https://accounts.google.com/o/oauth2/v2/auth`, exact IPv4 loopback callback, S256, `response_type=code`, `access_type=offline`, `prompt=consent`, and `include_granted_scopes=false`. Generate 32 random bytes for state and 32 bytes for the verifier with `SecRandomCopyBytes`; encode Base64URL without padding. Provide constant-time `OAuthState.matches(expected:received:)` over UTF-8 bytes.

- [ ] **Step 4: Verify GREEN**

Run: `swift test --package-path DailyPlanner --filter DailyPlannerGoogleTests --no-parallel`

Expected: request, scope, PKCE, state, and constant-time comparison tests pass.

- [ ] **Step 5: Commit**

```bash
git add DailyPlanner/Package.swift DailyPlanner/Sources/DailyPlannerGoogle DailyPlanner/Tests/DailyPlannerGoogleTests
git commit -m "feat: add exact Google OAuth request boundary"
```

### Task 5: One-shot loopback authorization session

**Files:**
- Create: `DailyPlanner/Sources/DailyPlannerGoogle/GoogleOAuthCallback.swift`
- Create: `DailyPlanner/Sources/DailyPlannerGoogle/GoogleLoopbackListener.swift`
- Create: `DailyPlanner/Sources/DailyPlannerGoogle/GoogleAuthorizationSession.swift`
- Create: `DailyPlanner/Tests/DailyPlannerGoogleTests/GoogleOAuthCallbackTests.swift`
- Create: `DailyPlanner/Tests/DailyPlannerGoogleTests/GoogleAuthorizationSessionTests.swift`

**Interfaces:**
- Consumes: `GoogleOAuthRequest`, `OAuthState`, and `SystemBrowserOpening`.
- Produces: `GoogleAuthorizationGrant`, `GoogleAuthorizationSession.authorize(clientIdentifier:timeout:onAwaitingConsent:)`, `cancel()`, and an injected `GoogleLoopbackListening` boundary.

- [ ] **Step 1: Write failing parser, race, and browser-count tests**

```swift
func testCallbackAcceptsOnlyExactPathSingleCodeAndMatchingState() throws {
    let result = try GoogleOAuthCallback.parse(
        target: "/oauth/callback?code=synthetic-code&state=expected-state",
        expectedState: "expected-state"
    )
    XCTAssertEqual(result.authorizationCode, "synthetic-code")
}

func testCallbackRejectsWrongPathDuplicateCodeFragmentAndStateMismatch() {
    for target in [
        "/other?code=value&state=expected-state",
        "/oauth/callback?code=one&code=two&state=expected-state",
        "/oauth/callback?code=value&state=wrong",
        "/oauth/callback?code=value&state=expected-state#fragment",
    ] {
        XCTAssertThrowsError(try GoogleOAuthCallback.parse(target: target, expectedState: "expected-state"))
    }
}

func testReadyThenFailedOpensBrowserOnceAndCompletesOnce() async throws {
    let listener = ScriptedLoopbackListener(events: [.ready(port: 43117), .failed, .callback(code: "synthetic-code")])
    let browser = RecordingBrowser(result: true)
    let session = GoogleAuthorizationSession(listenerFactory: { listener }, browser: browser)
    _ = try await session.authorize(clientIdentifier: "client", timeout: 1)
    XCTAssertEqual(browser.openCount, 1)
    XCTAssertEqual(listener.terminalCompletionCount, 1)
}
```

Add the inverse ordering test `failedThenReady` and cancellation/timeout cases; assertions are on the real session result and owned listener closure, not only fake calls.

- [ ] **Step 2: Verify RED**

Run: `swift test --package-path DailyPlanner --filter 'GoogleOAuthCallbackTests|GoogleAuthorizationSessionTests' --no-parallel`

Expected: compile failure because callback/session types do not exist.

- [ ] **Step 3: Implement bounded listener and single completion gate**

`GoogleLoopbackListener` binds only `NWEndpoint.Host.ipv4(.loopback)` and `.any` port, accepts a bounded HTTP head, rejects non-GET and oversized/invalid input, replies with fixed success/failure HTML, and cancels every owned connection/listener on terminal completion. `GoogleAuthorizationSession` uses an `NSLock`-protected terminal gate so ready, failure, callback, cancellation, and timeout can win once only; it constructs the request after readiness and opens the browser at most once.

```swift
public struct GoogleAuthorizationGrant: Sendable {
    let authorizationCode: String
    let request: GoogleOAuthRequest
}

public protocol GoogleLoopbackListening: Sendable {
    func start(timeout: Duration, handler: @escaping @Sendable (GoogleLoopbackEvent) -> Void) throws
    func cancel()
}
```

`authorize` also accepts `onAwaitingConsent: @Sendable () async -> Void`; it invokes that callback exactly once after listener readiness and immediately before the one browser-open attempt. Define `ScriptedLoopbackListener` and `RecordingBrowser` in the test file with the literal event sequence, terminal count, opened URLs, and no real socket/browser side effects.

- [ ] **Step 4: Verify GREEN and leak cleanup**

Run: `swift test --package-path DailyPlanner --filter 'GoogleOAuthCallbackTests|GoogleAuthorizationSessionTests' --no-parallel`

Expected: parser adversarial cases, both readiness races, browser failure, cancellation, timeout, single completion, and owned-resource cleanup pass.

- [ ] **Step 5: Commit**

```bash
git add DailyPlanner/Sources/DailyPlannerGoogle DailyPlanner/Tests/DailyPlannerGoogleTests
git commit -m "feat: add one-shot Google loopback authorization"
```

### Task 6: Allowlisted ephemeral HTTP transport

**Files:**
- Create: `DailyPlanner/Sources/DailyPlannerGoogle/GoogleHTTPTransport.swift`
- Create: `DailyPlanner/Sources/DailyPlannerGoogle/GoogleNetworkPolicy.swift`
- Create: `DailyPlanner/Tests/DailyPlannerGoogleTests/GoogleNetworkPolicyTests.swift`
- Create: `DailyPlanner/Tests/DailyPlannerGoogleTests/GoogleHTTPTransportTests.swift`

**Interfaces:**
- Produces: `GoogleHTTPTransport`, `GoogleHTTPResponse`, `URLSessionGoogleHTTPTransport`, and `GoogleNetworkPolicy.validate(_:)` for Task 7.
- Guarantees: no redirect, cookies, cache, credentials, or non-allowlisted request reaches URLSession.

- [ ] **Step 1: Write failing policy and redirect tests**

```swift
func testPolicyAcceptsOnlyExactOAuthPostsAndProviderGets() throws {
    let accepted = [
        request("POST", "https://oauth2.googleapis.com/token"),
        request("POST", "https://oauth2.googleapis.com/revoke"),
        request("GET", "https://gmail.googleapis.com/gmail/v1/users/me/profile"),
        request("GET", "https://www.googleapis.com/calendar/v3/users/me/calendarList?maxResults=1"),
        request("GET", "https://tasks.googleapis.com/tasks/v1/users/@me/lists?maxResults=1"),
    ]
    for request in accepted { XCTAssertNoThrow(try GoogleNetworkPolicy.validate(request)) }
}

func testPolicyRejectsWriteMethodsUnexpectedHostsPathsSchemesAndCredentials() {
    let rejected = [
        request("POST", "https://gmail.googleapis.com/gmail/v1/users/me/messages/send"),
        request("DELETE", "https://www.googleapis.com/calendar/v3/calendars/x/events/y"),
        request("GET", "https://evil.example.test/gmail/v1/users/me/profile"),
        request("GET", "http://gmail.googleapis.com/gmail/v1/users/me/profile"),
        request("GET", "https://user:password@gmail.googleapis.com/gmail/v1/users/me/profile"),
    ]
    for request in rejected { XCTAssertThrowsError(try GoogleNetworkPolicy.validate(request)) }
}

func testTransportRejectsRedirectWithoutSendingSecondRequest() async throws {
    let protocolSpy = RedirectingURLProtocolSpy()
    let transport = URLSessionGoogleHTTPTransport(protocolClasses: [type(of: protocolSpy)])
    let response = try await transport.send(request("GET", "https://gmail.googleapis.com/gmail/v1/users/me/profile"))
    XCTAssertEqual(response.statusCode, 302)
    XCTAssertEqual(protocolSpy.requestCount, 1)
}
```

- [ ] **Step 2: Verify RED**

Run: `swift test --package-path DailyPlanner --filter 'GoogleNetworkPolicyTests|GoogleHTTPTransportTests' --no-parallel`

Expected: compile failure because transport/policy types do not exist.

- [ ] **Step 3: Implement validation-before-send and no-redirect session**

The policy canonicalizes scheme/host/port, rejects user/password/fragments, and matches literal path prefixes. The transport validates before `session.data(for:)`. Its ephemeral configuration sets `urlCache=nil`, `requestCachePolicy=.reloadIgnoringLocalCacheData`, `httpCookieStorage=nil`, `httpShouldSetCookies=false`, and `urlCredentialStorage=nil`. A private session delegate returns `nil` from redirection callbacks.

```swift
public protocol GoogleHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> GoogleHTTPResponse
}

public struct GoogleHTTPResponse: Sendable {
    public let statusCode: Int
    public let data: Data
}
```

Define the `request(method:url:)` test helper with literal `URLRequest` construction. Define `RedirectingURLProtocolSpy` as a test-only `URLProtocol` subclass that emits one 302 response and records any second request in lock-protected static state reset in `tearDown`; it never opens a socket.

- [ ] **Step 4: Verify GREEN**

Run: `swift test --package-path DailyPlanner --filter 'GoogleNetworkPolicyTests|GoogleHTTPTransportTests' --no-parallel`

Expected: allowlist, malformed request, redirect, cache/cookie, and validation-before-send tests pass without real network access.

- [ ] **Step 5: Commit**

```bash
git add DailyPlanner/Sources/DailyPlannerGoogle DailyPlanner/Tests/DailyPlannerGoogleTests
git commit -m "feat: enforce Google read-only network allowlist"
```

### Task 7: Two-phase read-only canary controller and cleanup

**Files:**
- Create: `DailyPlanner/Sources/DailyPlannerGoogle/GoogleReadOnlyConnectionController.swift`
- Create: `DailyPlanner/Tests/DailyPlannerGoogleTests/GoogleReadOnlyConnectionControllerTests.swift`

**Interfaces:**
- Consumes: authorization session, exact credential store, allowlisted transport, approved scopes, and identity binding.
- Produces: concrete `GoogleConnectionControlling`; keeps authorization/access/refresh values inside a lock-protected memory-only pending grant until confirmation.

- [ ] **Step 1: Write failing success, exact-scope, and cleanup tests**

```swift
func testBeginRefreshesAndPerformsOnlyThreeReadsBeforeReturningPendingIdentity() async throws {
    let harness = ControllerHarness.success(email: "Owner@Example.Test")
    let pending = try await harness.controller.begin(progress: { _ in })
    XCTAssertEqual(pending.binding.normalizedEmail, "owner@example.test")
    XCTAssertEqual(harness.transport.recordedMethodsAndPaths, [
        "POST /token", "POST /token", "GET /gmail/v1/users/me/profile",
        "GET /calendar/v3/users/me/calendarList", "GET /tasks/v1/users/@me/lists",
    ])
    XCTAssertNil(try harness.credentials.loadRefreshToken())
}

func testConfirmPersistsRefreshAndReturnsSanitizedReceipt() async throws {
    let harness = ControllerHarness.success(email: "owner@example.test")
    _ = try await harness.controller.begin(progress: { _ in })
    let receipt = try await harness.controller.confirmPendingIdentity()
    XCTAssertNotNil(try harness.credentials.loadRefreshToken())
    XCTAssertTrue(receipt.refreshSucceeded && receipt.gmailProfileRead)
    XCTAssertEqual(receipt.scopes, ApprovedGoogleScopes.readOnly)
}

func testEveryFailureRevokesDeletesBothCredentialsAndClearsPendingGrant() async throws {
    for point in ControllerFailurePoint.allCases {
        let harness = ControllerHarness.failure(at: point)
        do {
            _ = try await harness.controller.begin(progress: { _ in })
            XCTFail("Expected injected failure")
        } catch {
            XCTAssertNotNil(error as? GoogleConnectionControllerError)
        }
        XCTAssertEqual(try harness.credentials.presence(), .none)
        XCTAssertTrue(harness.transport.revocationAttemptedWhenCredentialExisted)
        do {
            _ = try await harness.controller.confirmPendingIdentity()
            XCTFail("A failed begin must not leave a confirmable grant")
        } catch {
            XCTAssertEqual(error as? GoogleConnectionControllerError, .notConfigured)
        }
    }
}
```

Failure points cover exchange, wrong granted scope, missing refresh, refresh, each of three reads, malformed identity, Keychain operations, cancel, and revoke/delete cleanup failure.

`ControllerHarness` lives in the new test file. It preloads only a synthetic client identifier, scripts complete documented token/profile/calendar-list/task-list JSON responses, records sanitized method/path pairs, and exposes credential presence and revocation-attempt booleans without exposing recorded header or body values to assertions.

- [ ] **Step 2: Verify RED**

Run: `swift test --package-path DailyPlanner --filter GoogleReadOnlyConnectionControllerTests --no-parallel`

Expected: compile failure because the controller does not exist.

- [ ] **Step 3: Implement exchange, refresh, canaries, pending confirmation, and cleanup**

Use exact endpoints and complete JSON response fixtures. Token exchange includes code, client ID, redirect URI, verifier, and `grant_type=authorization_code`; refresh includes client ID, refresh token, and `grant_type=refresh_token`. Granted scopes compare as an exact set. Provider GETs use `Authorization: Bearer` and never a query credential. Parse only Gmail `emailAddress`; Calendar/Tasks success requires valid top-level JSON of the documented resource kind.

On begin, reject a missing, complete, or inconsistent credential presence and allow only a saved client identifier. Forward `.connecting`, then forward `.awaitingConsent` only from the authorization session's after-ready/before-browser callback. On begin failure/cancel, revoke the best available credential, delete both Keychain records, clear the pending grant, and return a finite error. On confirm, persist the refresh token and destroy the pending credential copy. On disconnect, revoke loaded refresh token, attempt both exact deletes, clear pending memory, and report `.cleanupRequired` if any cleanup component fails. Saving a replacement client identifier is allowed only in none/client-only states; a complete connection must disconnect first.

- [ ] **Step 4: Verify GREEN and secret-canary absence**

Run: `swift test --package-path DailyPlanner --filter GoogleReadOnlyConnectionControllerTests --no-parallel`

Expected: all success/failure/cancel/disconnect cases pass; encoded receipts and finite errors contain none of the synthetic authorization, token, client ID, or URL canaries.

- [ ] **Step 5: Commit**

```bash
git add DailyPlanner/Sources/DailyPlannerGoogle/GoogleReadOnlyConnectionController.swift DailyPlanner/Tests/DailyPlannerGoogleTests/GoogleReadOnlyConnectionControllerTests.swift
git commit -m "feat: add two-phase Google read-only canary"
```

### Task 8: Application connection workflow and rollback

**Files:**
- Create: `DailyPlanner/Sources/DailyPlannerApplication/GoogleConnectionWorkflow.swift`
- Create: `DailyPlanner/Tests/DailyPlannerApplicationTests/GoogleConnectionWorkflowTests.swift`
- Modify: `DailyPlanner/Tests/DailyPlannerApplicationTests/TestSupport.swift`

**Interfaces:**
- Consumes: `GoogleConnectionControlling` and `PrivateSettingsStore`.
- Produces: `GoogleConnectionWorkflowState` and workflow methods `loadState()`, `saveClientIdentifier(_:)`, `begin(progress:)`, `confirm()`, `cancel()`, `disconnect()`.

- [ ] **Step 1: Write failing state/rollback tests**

```swift
func testNoCredentialsLoadsNotConfiguredAndDoesNotStartConnection() async {
    let harness = ConnectionWorkflowHarness(presence: .none)
    XCTAssertEqual(await harness.workflow.loadState(), .notConfigured)
    XCTAssertEqual(harness.controller.beginCount, 0)
}

func testBeginRequiresSavedClientIdentifierAndReturnsConfirmIdentity() async {
    let harness = ConnectionWorkflowHarness(presence: .clientOnly, pending: "owner@example.test")
    XCTAssertEqual(await harness.workflow.begin(progress: { _ in }), .confirmIdentity(displayEmail: "owner@example.test"))
    XCTAssertNil(harness.store.lastReplacement?.googleAccountBinding)
}

func testConfirmPersistsBindingOnlyAfterControllerConfirmation() async {
    let harness = ConnectionWorkflowHarness(presence: .clientOnly, pending: "owner@example.test")
    _ = await harness.workflow.begin(progress: { _ in })
    XCTAssertEqual(await harness.workflow.confirm(), .connectedReadOnly(displayEmail: "owner@example.test"))
    XCTAssertEqual(harness.store.lastReplacement?.googleAccountBinding?.normalizedEmail, "owner@example.test")
}

func testSettingsFailureAfterCredentialConfirmationRollsBackController() async {
    let harness = ConnectionWorkflowHarness(presence: .clientOnly, pending: "owner@example.test", settingsMode: .failReplace)
    _ = await harness.workflow.begin(progress: { _ in })
    XCTAssertEqual(await harness.workflow.confirm(), .cleanupRequired)
    XCTAssertEqual(harness.controller.disconnectCount, 1)
}
```

Add existing-binding mismatch, incomplete persistent state, cancel, disconnect, controller error mapping, and settings-read failure tests with literal state expectations.

- [ ] **Step 2: Verify RED**

Run: `swift test --package-path DailyPlanner --filter GoogleConnectionWorkflowTests --no-parallel`

Expected: compile failure because the workflow/state do not exist.

- [ ] **Step 3: Implement the finite workflow**

```swift
public enum GoogleConnectionWorkflowState: Equatable, Sendable {
    case notConfigured, readyToConnect, connecting, awaitingConsent
    case confirmIdentity(displayEmail: String), connectedReadOnly(displayEmail: String)
    case cancelled, offline, scopeMismatch, identityMismatch
    case credentialUnavailable, providerUnavailable, cleanupRequired
}
```

`loadState` combines credential presence and encrypted binding: none→notConfigured, clientOnly→readyToConnect, complete+binding→connected, every inconsistent combination→cleanupRequired. `begin(progress:)` refuses none/complete/inconsistent states, maps `.connecting` and `.awaitingConsent` from the controller without inventing progress, and cancels if a persisted binding differs. `confirm` persists binding only after controller confirmation and rolls back through disconnect on settings failure. `disconnect` clears both controller credentials and binding; partial cleanup remains visible. `ConnectionWorkflowHarness` defines a thread-safe recording controller and reuses the existing recording settings store; it records call order and returns literal states/errors only.

- [ ] **Step 4: Verify GREEN**

Run: `swift test --package-path DailyPlanner --filter GoogleConnectionWorkflowTests --no-parallel`

Expected: all state, ordering, mismatch, rollback, cancel, and disconnect tests pass.

Run: `swift test --package-path DailyPlanner --filter DailyPlannerApplicationTests --no-parallel`

Expected: all Application tests pass.

- [ ] **Step 5: Commit**

```bash
git add DailyPlanner/Sources/DailyPlannerApplication DailyPlanner/Tests/DailyPlannerApplicationTests
git commit -m "feat: orchestrate Google connection safely"
```

### Task 9: Settings UI, production composition, and explicit live-canary mode

**Files:**
- Create: `DailyPlanner/Sources/DailyPlannerPlatform/MacSystemBrowser.swift`
- Create: `DailyPlanner/Sources/DailyPlannerPlatform/LaunchMode.swift`
- Modify: `DailyPlanner/Package.swift`
- Modify: `DailyPlanner/Sources/DailyPlannerUI/PlannerAppModel.swift`
- Modify: `DailyPlanner/Sources/DailyPlannerUI/PlannerSettingsView.swift`
- Rename: `DailyPlanner/Sources/DailyPlannerUI/M1RootView.swift` to `DailyPlanner/Sources/DailyPlannerUI/PlannerRootView.swift`
- Modify: `DailyPlanner/Sources/DailyPlannerApp/AppComposition.swift`
- Modify: `DailyPlanner/Sources/DailyPlannerApp/main.swift`
- Modify: `DailyPlanner/Tests/DailyPlannerUITests/PlannerAppModelTests.swift`
- Rename: `DailyPlanner/Tests/DailyPlannerUITests/M1RootViewAccessibilityTests.swift` to `DailyPlanner/Tests/DailyPlannerUITests/PlannerRootViewAccessibilityTests.swift`
- Create: `DailyPlanner/Tests/DailyPlannerPlatformTests/MacSystemBrowserTests.swift`
- Create: `DailyPlanner/Tests/DailyPlannerAcceptanceTests/M2AReadOnlyAcceptanceTests.swift`

**Interfaces:**
- Consumes: connection workflow and all production adapters from Tasks 3–8.
- Produces: explicit UI actions and real composition with zero automatic connection; `LaunchMode.parse(arguments:)` recognizes only `--live-readonly-canary` as a mode flag and never accepts credential arguments.

- [ ] **Step 1: Write failing UI/model/composition acceptance tests**

```swift
func testOpeningSettingsAndAppLaunchPerformNoGoogleAction() async {
    let harness = PlannerModelHarness.makeGoogle(state: .notConfigured)
    harness.model.showSettings()
    await harness.model.loadGoogleConnectionState()
    XCTAssertEqual(harness.connection.beginCount, 0)
    XCTAssertEqual(harness.browser.openCount, 0)
}

func testExplicitButtonsDriveSaveBeginConfirmCancelAndDisconnect() async {
    let harness = PlannerModelHarness.makeGoogle(state: .notConfigured)
    harness.model.googleClientIdentifierDraft = "synthetic-client.apps.example.test"
    await harness.model.saveGoogleClientIdentifier()
    await harness.model.connectGoogle()
    await harness.model.confirmGoogleIdentity()
    await harness.model.disconnectGoogle()
    XCTAssertEqual(harness.connection.actions, [.save, .begin, .confirm, .disconnect])
}

func testM2ASafetyStateNeverOffersExecution() {
    let model = PlannerModelHarness.makeGoogle(state: .readyToConnect).model
    XCTAssertEqual(model.safetyBanner, "Read-only · no actions executed")
    XCTAssertFalse(model.canExecuteExternalAction)
    XCTAssertEqual(model.assistantState, .unavailable(.notIncludedInM2))
}

func testAcceptanceCompositionWithFakesDoesNotTouchNetworkBrowserOrKeychainUntilConnect() async {
    let harness = M2AAcceptanceHarness.generated()
    await harness.model.loadGoogleConnectionState()
    XCTAssertEqual(harness.externalCalls, [])
    XCTAssertFalse(harness.model.canExecuteExternalAction)
}
```

Accessibility tests host the real root/settings views and require identifiers `m2a-safety-banner`, `google-client-identifier-field`, `save-google-client-button`, `connect-google-button`, `cancel-google-button`, `confirm-google-identity-button`, and `disconnect-google-button` in their applicable states. The exposed snapshot must not contain synthetic client/token/authorization/URL canaries.

- [ ] **Step 2: Verify RED**

Run: `swift test --package-path DailyPlanner --filter 'PlannerAppModelTests|PlannerRootViewAccessibilityTests|M2AReadOnlyAcceptanceTests' --no-parallel`

Expected: compile/test failure because M2A model, views, composition, and acceptance harness do not exist.

- [ ] **Step 3: Implement explicit controls and real composition**

`PlannerAppModel` publishes only the finite workflow state, a transient client-ID draft, and a generic failure. It calls the workflow only from the six explicit methods. During begin it changes state only from the workflow's `.connecting` and `.awaitingConsent` progress callbacks. Dismissing Settings cancels pending connection. The client identifier uses a `SecureField` and clears after save; connected identity appears only in the focused Settings state. The root banner uses the exact M2A safety text and identifier.

`MacSystemBrowser` implements `SystemBrowserOpening` through an injected internal `WorkspaceURLOpening` boundary whose production implementation calls `NSWorkspace.shared.open` on the MainActor. Its test injects a recording workspace and proves the exact URL/result without opening a real browser. `AppComposition.makeRootModel()` wires `GoogleOAuthKeychain`, `URLSessionGoogleHTTPTransport`, `GoogleAuthorizationSession`, `GoogleReadOnlyConnectionController`, `GoogleConnectionWorkflow`, and the existing encrypted settings store. Calendar workflows remain wired to `M1SyntheticCalendarSource` until M2B. Construction and launch make no Google calls.

`LaunchMode.parse(arguments:)` accepts standard launch or the exact mode flag. Canary mode opens Settings and explains that the user must click Connect; it never starts OAuth automatically and never accepts a client ID/token argument.

- [ ] **Step 4: Verify GREEN, UI accessibility, and full package tests**

Run: `swift test --package-path DailyPlanner --filter 'PlannerAppModelTests|PlannerRootViewAccessibilityTests|M2AReadOnlyAcceptanceTests|MacSystemBrowserTests' --no-parallel`

Expected: explicit-action, no-auto-access, finite-state, safety, focus, and sensitive-text tests pass.

Run: `swift test --package-path DailyPlanner --no-parallel`

Expected: all package tests pass with no real browser, Keychain, or network access.

- [ ] **Step 5: Commit**

```bash
git add DailyPlanner/Package.swift DailyPlanner/Sources/DailyPlannerApp DailyPlanner/Sources/DailyPlannerPlatform DailyPlanner/Sources/DailyPlannerUI DailyPlanner/Tests/DailyPlannerPlatformTests DailyPlanner/Tests/DailyPlannerUITests DailyPlanner/Tests/DailyPlannerAcceptanceTests
git commit -m "feat: expose explicit Google read-only connection"
```

### Task 10: M2A verifier, inverse canaries, evidence schema, and handoff

**Files:**
- Create: `DailyPlanner/Tests/verify-m2a.sh`
- Modify: `DailyPlanner/Scripts/build-app.sh`
- Modify: `DailyPlanner/Tests/verify-signed-app.sh`
- Create: `docs/architecture/M2A-Google-Read-Only-Handoff.md`
- Modify: `docs/architecture/evidence/google-oauth.json`
- Modify: `README.md`

**Interfaces:**
- Consumes: complete M2A implementation and full test suite.
- Produces: one offline serial verifier and a sanitized live-canary evidence contract; does not run the live canary.

- [ ] **Step 1: Write the failing verifier contract as executable behavior**

Create `verify-m2a.sh` first with a source-hygiene function and run it before adapting the source allowlist. It must execute:

```zsh
swift test --package-path "$planner_root" --scratch-path "$scratch/swift" --no-parallel
zsh "$planner_root/Scripts/build-app.sh"
zsh "$planner_root/Tests/verify-signed-app.sh"
git -C "$repo_root" diff --check
verify_m2a_source_hygiene "$planner_root/Sources" "$planner_root/Package.swift"
```

The first run must fail because the legacy M1 hygiene rule rejects the intentional Google target.

- [ ] **Step 2: Verify RED**

Run: `zsh DailyPlanner/Tests/verify-m2a.sh`

Expected: nonzero at source hygiene with the intentional `DailyPlannerGoogle` network capability named; no live call occurs.

- [ ] **Step 3: Implement the exact M2A hygiene and lifecycle gates**

The final verifier must:

- allow `URLSession`, `URLRequest`, and `Network` only inside `Sources/DailyPlannerGoogle`;
- allow AppKit browser opening only inside `Sources/DailyPlannerPlatform/MacSystemBrowser.swift`;
- reject provider write scopes, Gmail send/modify routes, Calendar/Tasks mutation methods, provider `PUT|PATCH|DELETE`, Codex/process launch, vault bookmark resolution/content I/O, notifications, timers, scheduler/login APIs, dynamic logging, and external Swift packages;
- require the literal exact read-only scope list and exact two Keychain account names through executable tests, not source-grep assertions;
- copy Sources/Package to verifier scratch and prove inverse canaries fail by injecting one write scope, one provider DELETE request, one unexpected provider host, and one dynamic-log statement;
- build/sign, launch only the exact generated binary, observe its owned PID, terminate/reap only that PID, then re-verify signing;
- scan the app's captured launch output and all generated evidence for credential/URL/provider-content sentinel patterns;
- delete only its exact scratch root through an EXIT trap and verify the Git worktree remains unchanged after the run.

Keep the old M1 verifier as a historical gate but document that `verify-m2a.sh` is authoritative after M2A. Rename generic build scratch identifiers from `m1` to `daily-planner-build` without changing exact app-bundle cleanup/signing behavior.

Update `google-oauth.json` with `m2aImplementation: "READY_FOR_USER_AUTH"`, exact scope names, and boolean/null fields only; preserve top-level live status `BLOCKED_BY_USER_AUTH`. The handoff records that no live browser, Google data, real OAuth credential, or real Keychain item was used by automated acceptance.

- [ ] **Step 4: Verify GREEN twice and audit repository hygiene**

Run: `zsh DailyPlanner/Tests/verify-m2a.sh`

Expected: exit 0; all tests pass; signed lifecycle, four inverse canaries, secret scan, exact PID cleanup, scratch cleanup, and diff checks pass.

Run the same command a second time.

Expected: exit 0 again, proving deterministic cleanup and no stale owned process/artifact.

Run: `rg -n '@[A-Za-z0-9.-]+[.]edu|gmail[.]modify|calendar[.]events|auth/tasks([^.]|$)|Bearer[[:space:]]|access_token|refresh_token|authorization code|/Users/' DailyPlanner docs README.md`

Expected: no personal/private value; only deliberate schema/redaction/test references are manually classified and documented in the task report. No credential value, personal identifier, or local private path exists.

- [ ] **Step 5: Commit**

```bash
git add DailyPlanner/Tests/verify-m2a.sh DailyPlanner/Scripts/build-app.sh DailyPlanner/Tests/verify-signed-app.sh docs/architecture/M2A-Google-Read-Only-Handoff.md docs/architecture/evidence/google-oauth.json README.md
git commit -m "test: gate the M2A read-only foundation"
```

## Plan completion gate

After Task 10, run a whole-branch review against this plan and its spec. M2A implementation may be described as offline-ready only after the final reviewer has no open Critical or Important findings and a fresh controller-run `zsh DailyPlanner/Tests/verify-m2a.sh` exits 0. The live status remains `BLOCKED_BY_USER_AUTH` until the signed app is launched in canary mode and the user explicitly clicks Connect and consents. Do not merge, push, open the browser, or run the live canary without separate authorization.
