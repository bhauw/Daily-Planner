# Daily Planner Signed Helper IPC Feasibility Implementation Plan

> **Status: REJECTED DRAFT — DO NOT EXECUTE.** Three review rounds found unresolved cancellation, crash attribution, stream-framing, cancellation-boundedness, installed-artifact verification, and code-completeness defects. Reconsider the distribution architecture before writing a replacement plan.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Determine whether a separately signed and registered Codex helper can accept a synthetic, authenticated, versioned request from a separately signed sandboxed Daily Planner probe, supervise one synthetic Codex App Server turn, and clean up correctly after success, cancellation, timeout, and helper crash.

**Architecture:** Build only disposable targets under `Spikes/HelperIPCProbe`. A separately installed, signed installer host registers a separately signed login-item helper with `SMAppService`; the sandboxed main probe neither contains nor launches the helper or Codex. The helper advertises a loopback-only Bonjour endpoint with Network.framework, and peers exchange bounded, mutually signed protocol-v1 frames. Each installed signed owner creates its own Keychain private key and exchanges only public keys through one caller-owned private root. A control-pipe EOF cancels the Codex worker if the helper crashes, while the runner—not the dead helper or main—proves cleanup.

**Tech Stack:** macOS 15.0+, Swift 6.0 language mode, Swift Package Manager, Foundation, Network.framework (`NWListener`, `NWBrowser`, `NWConnection`), CryptoKit Ed25519/SHA-256, Security Keychain APIs, ServiceManagement `SMAppService`, XCTest/Swift Testing, shell verification with `codesign`, `plutil`, `ditto`, and the installed Codex CLI/schema already pinned by `Spikes/CodexBridgeProbe`.

**Spec:** `docs/architecture/M0.5-Feasibility-Handoff.md`, especially “Gate table,” R1, R2, and “Required next evidence” item 4.

## Global Constraints

- This is a disposable M0.5 feasibility probe. Do not create or modify a production app project, production helper, production installer, or M1 package.
- Use synthetic request text only: `Return exactly the structured probe result.` No Google account, OAuth flow, Gmail, Calendar, Tasks, notification, real vault, private note, résumé, home address, or other private content may be read or transmitted.
- No Google write, vault write, notification delivery, OAuth request, remote service write, or user-content write is authorized. Local writes are limited to exact probe-owned build, temporary install, Keychain, `SMAppService` registration, and sanitized evidence artifacts described here.
- The sandboxed main probe’s entitlements are exactly `com.apple.security.app-sandbox=true`, `com.apple.security.files.user-selected.read-write=true`, and `com.apple.security.network.client=true`. Do not add an app group, Keychain access group, global Mach lookup, automation, Apple Events, network server, temporary exception, or any other entitlement.
- Main, installer, helper, and worker are four separately signed code items/products. The helper is not embedded in the sandboxed main probe; it lives in the separately installed installer host’s `Contents/Library/LoginItems` directory and is registered through `SMAppService.loginItem(identifier:)`.
- `SMAppService` supplies no custom arguments when launching a login item. The helper’s no-argument entry point is serve mode; bootstrap modes are invoked directly on the installed helper before registration.
- The main probe never receives a Codex executable path and never uses `Process`. The helper receives the validated Codex location only through its one-time local provisioning channel and stores it in its exact probe Keychain item.
- The live Codex operation reuses App Server v2 with `approvalPolicy: never`, `sandbox: read-only`, no dynamic tools, an empty temporary cwd, the existing strict output schema, and the installed schema/CLI version recorded by `Spikes/CodexBridgeProbe`.
- IPC binds only to IPv4 and IPv6 loopback. Reject non-loopback accepted connections and discovered endpoints before reading an application frame. Bonjour is discovery only; successful mutual signature verification establishes peer identity.
- Protocol version is exactly `1`. Unknown versions, unknown message kinds, unknown enum values, duplicate IDs, out-of-order sequence numbers, stale session IDs, oversized frames, invalid signatures, and extra JSON keys fail closed.
- Every wire frame is at most 16,384 bytes. Every connection gets a 3-second handshake deadline. Normal synthetic Codex requests get a 120-second deadline; deterministic timeout tests use a 250-millisecond deadline.
- `ProbeRequest.messageID` identifies that request. A cancellation request uses a fresh `messageID` and a non-nil `targetJobID`; all non-cancel requests require `targetJobID == nil`.
- Network parameters set `acceptLocalOnly = true`. Filter Bonjour TXT `pv=1` and the pinned instance hash before applying the candidate limit; validate loopback after resolution and again after connection establishment.
- Each installed signed owner creates and retrieves its own private key in its own Keychain context. The caller root carries public keys only; no process writes another code item’s private-key item. Use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; make no locked-state claim.
- Raw stderr, prompts, transcripts, frame payloads, private paths, Keychain values, public-key bytes, signatures, nonces, process IDs, and arbitrary error descriptions never enter human-readable stdout, Git, JSON evidence, or the handoff. Bootstrap file descriptor 3 may carry exactly 32 public-key bytes into the caller-owned root; it is never printed or retained in evidence.
- One top-level caller creates `helper_root="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-helper-ipc.XXXXXX")"`, canonicalizes it, and passes it plus exact product paths to every nested script. Nested scripts never call `mktemp` or infer products. Cleanup requires the canonical root parent to equal canonical `${TMPDIR:-/tmp}`, basename prefix `daily-planner-helper-ipc.`, unregisters the exact service, stops validated owned processes, deletes five exact Keychain items, and removes only that root on `EXIT`, `INT`, `TERM`, and `HUP`.
- Run Swift builds serially. Never run this probe, `Spikes/CodexBridgeProbe`, or another Swift build concurrently with a Codex subprocess test.
- A successful implementation does not itself make the helper gate `PASS`. Only the executed signed end-to-end command and committed sanitized evidence may change the gate. A registration prompt or signing limitation is `BLOCKED_BY_USER_ACTION`; an observed technical property failure is `FAIL` without an inferred cause.
- Primary Apple references for the selected mechanisms are [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice), [SMAppService registration behavior](https://developer.apple.com/documentation/servicemanagement/smappservice/register%28%29), [Apple’s package-installer/launch-agent sample](https://developer.apple.com/documentation/servicemanagement/updating-your-app-package-installer-to-use-the-new-service-management-api), [NWBrowser Bonjour descriptors](https://developer.apple.com/documentation/network/nwbrowser/descriptor-swift.enum), [Network listeners](https://developer.apple.com/documentation/network/networklistener), [Curve25519 signing keys](https://developer.apple.com/documentation/cryptokit/curve25519/signing/privatekey), [Keychain services](https://developer.apple.com/documentation/security/keychain-services/), and [TN3127 code-signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).
- Do not replace this design with a global Mach service. Apple documents `NSXPCConnection` as the normal Mach-service IPC API and supports peer code-signing requirements, but a separately registered global Mach service would require main-app capability outside the binding entitlement ceiling. Loopback Network.framework IPC is the selected hypothesis for this probe, not a production distribution ruling.

## Exact File Map

| Path | Action | Responsibility |
|---|---|---|
| `Spikes/HelperIPCProbe/Package.swift` | Create, then modify | Task 1 declares protocol targets only; Tasks 3–6 add client, server, worker, and executable targets only when their source files exist. |
| `Spikes/HelperIPCProbe/Sources/HelperIPCProtocol/WireContract.swift` | Create | Finite request/response/status models and strict protocol-v1 envelope decoding. |
| `Spikes/HelperIPCProbe/Sources/HelperIPCProtocol/FrameCodec.swift` | Create | 4-byte big-endian length framing, 16 KiB limit, and canonical sorted-key payload bytes. |
| `Spikes/HelperIPCProbe/Sources/HelperIPCProtocol/Authentication.swift` | Create | Handshake transcript construction, Ed25519 signatures, session IDs, and sequence validation. |
| `Spikes/HelperIPCProbe/Sources/HelperIPCProtocol/IdentityStore.swift` | Create | Owner-only Keychain identity/peer/runtime storage and fd/stdin bootstrap primitives. |
| `Spikes/HelperIPCProbe/Sources/HelperIPCClient/HelperDiscovery.swift` | Create | `NetworkHelperDiscovery`, Bonjour browsing, pre-limit TXT filtering, loopback endpoint filtering, and cancellation. |
| `Spikes/HelperIPCProbe/Sources/HelperIPCClient/HelperClient.swift` | Create | `NetworkHelperConnector`, authenticated connection, correlation, deadlines, cancellation, and finite errors. |
| `Spikes/HelperIPCProbe/Sources/HelperIPCServer/HelperServer.swift` | Create | `NetworkServerTransport`, loopback listener/advertisement, mutual authentication, dispatch, and cleanup. |
| `Spikes/HelperIPCProbe/Sources/HelperIPCServer/JobRegistry.swift` | Create | One task per job ID, duplicate rejection, cancellation, active-job count, and shutdown. |
| `Spikes/HelperIPCProbe/Sources/HelperIPCServer/ProbeExecutor.swift` | Create | Concrete finite ping/hold/crash/Codex operation dispatch injected into `HelperServer`. |
| `Spikes/HelperIPCProbe/Sources/HelperIPCServer/CodexWorkerSession.swift` | Create | Launch and control the worker without shell interpolation; treat control-pipe EOF as cancellation. |
| `Spikes/HelperIPCProbe/Sources/HelperIPCServer/WorkerOwnership.swift` | Create | Private finite ownership receipt, atomic store, live-process matching, and safe cleanup target selection. |
| `Spikes/HelperIPCProbe/Sources/HelperIPCExecutableCore/CommandModes.swift` | Create | Finite main/installer/helper modes, including no-argument helper serve. |
| `Spikes/HelperIPCProbe/Sources/helper-ipc-probe-main/main.swift` | Create | Sandboxed CLI-style app modes for provisioning, running scenarios, and deleting its exact identity. |
| `Spikes/HelperIPCProbe/Sources/helper-ipc-probe-installer/main.swift` | Create | Separate installer-host modes for `SMAppService` register/status/unregister and helper provisioning. |
| `Spikes/HelperIPCProbe/Sources/helper-ipc-probe-helper/main.swift` | Create | Login-item helper entry point and probe-only crash scenario. |
| `Spikes/HelperIPCProbe/Sources/helper-ipc-codex-worker/main.swift` | Create | Existing `CodexBridgeCore.AppServerProcess` adapter plus parent-control-pipe monitoring and cleanup receipt. |
| `Spikes/HelperIPCProbe/Resources/MainInfo.plist` | Create | Main probe bundle ID and minimum macOS metadata. |
| `Spikes/HelperIPCProbe/Resources/MainSandbox.entitlements` | Create | Exact three-entitlement main-app ceiling. |
| `Spikes/HelperIPCProbe/Resources/InstallerInfo.plist` | Create | Separate installer-host bundle metadata. |
| `Spikes/HelperIPCProbe/Resources/HelperInfo.plist` | Create | Login-item bundle ID, `LSUIElement=true`, and background-only metadata. |
| `Spikes/HelperIPCProbe/Resources/Empty.entitlements` | Create | Explicit empty entitlement dictionary for installer, helper, and worker. |
| `Spikes/HelperIPCProbe/Scripts/build-signed-products.sh` | Create | Serial build, exact product assembly, inside-out signing, and strict verification. |
| `Spikes/HelperIPCProbe/Scripts/bootstrap-installed-products.sh` | Create | Installed owners generate private keys, exchange public keys, and helper stores exact runtime config. |
| `Spikes/HelperIPCProbe/Scripts/run-signed-e2e.sh` | Create | Private install, identity/config provisioning, registration, signed scenario execution, cleanup, and evidence staging. |
| `Spikes/HelperIPCProbe/Scripts/cleanup-probe-state.sh` | Create | Idempotent exact unregister/Keychain/process/private-root cleanup used by normal and signal paths. |
| `Spikes/HelperIPCProbe/Tests/HelperIPCProtocolTests/WireContractTests.swift` | Create | Strict finite enum, extra-key, version, framing, and sanitization tests. |
| `Spikes/HelperIPCProbe/Tests/HelperIPCProtocolTests/AuthenticationTests.swift` | Create | Mutual signature, transcript binding, replay, wrong-key, nonce, and sequence tests. |
| `Spikes/HelperIPCProbe/Tests/HelperIPCClientTests/HelperClientTests.swift` | Create | Discovery, correlation, timeout, cancellation, disconnect, and finite error tests with fakes. |
| `Spikes/HelperIPCProbe/Tests/HelperIPCServerTests/HelperServerTests.swift` | Create | Loopback rejection, duplicate job, crash mode gate, shutdown, and job cleanup tests. |
| `Spikes/HelperIPCProbe/Tests/HelperIPCServerTests/CodexWorkerSessionTests.swift` | Create | Worker EOF/cancellation and bounded result tests with a synthetic child fixture. |
| `Spikes/HelperIPCProbe/Tests/HelperIPCExecutableCoreTests/CommandModesTests.swift` | Create | No-argument helper startup and finite mode tests. |
| `Spikes/HelperIPCProbe/Tests/Integration/run-signed-contract.sh` | Create | Black-box assertions over four signed code items/products, exact entitlements, separation, and absence of embedded secrets/config. |
| `Spikes/CodexBridgeProbe/Sources/CodexBridgeCore/AppServerProcess.swift:1-620` | Modify | Add finite lifecycle and private ownership observers; neither value enters human-readable output/evidence. |
| `Spikes/CodexBridgeProbe/Tests/CodexBridgeCoreTests/AppServerMessageTests.swift:1-494` | Modify | Verify exactly one `.started` and `.stopped` lifecycle pair on success and cancellation. |
| `docs/architecture/evidence/helper-ipc.json` | Create after live run | Sanitized observed helper/install/IPC/fault/cleanup evidence only. |
| `docs/architecture/M0.5-Feasibility-Handoff.md:1-178` | Modify after live run | Update only the helper gate, Required next evidence, and R2 wording according to validated observed evidence. |
| `docs/architecture/evidence/security-boundary.json:1-97` | Modify after live run | Link the helper evidence from `distributionRuling` without rewriting prior observations. |
| `README.md:1-68` | Modify after live run | Add the serial helper command and current observed gate status. |

---

### Task 1: Strict finite protocol-v1 contract and frame codec

**Files:**
- Create: `Spikes/HelperIPCProbe/Package.swift`
- Create: `Spikes/HelperIPCProbe/Sources/HelperIPCProtocol/WireContract.swift`
- Create: `Spikes/HelperIPCProbe/Sources/HelperIPCProtocol/FrameCodec.swift`
- Create: `Spikes/HelperIPCProbe/Tests/HelperIPCProtocolTests/WireContractTests.swift`

**Interfaces:**
- Consumes: no previous task interfaces.
- Produces: `IPCProtocolVersion.current`, `ContractError`, `FrameError`, `StrictJSON`, `ProbeOperation`, `ProbeStatus`, `ProbeRequest`, `ProbeResponse`, `SignedFrame`, `FrameCodec.encode(_:)`, and `FrameCodec.decode(_:)` exactly as declared below.

- [ ] **Step 1: Create the package manifest and write strict decoding tests**

Create `Package.swift` with this complete initial manifest. It declares only directories created in Task 1:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HelperIPCProbe",
    platforms: [.macOS(.v15)],
    products: [.library(name: "HelperIPCProtocol", targets: ["HelperIPCProtocol"])],
    targets: [
        .target(name: "HelperIPCProtocol"),
        .testTarget(name: "HelperIPCProtocolTests", dependencies: ["HelperIPCProtocol"])
    ]
)
```

Create both source files with imports only so SwiftPM recognizes the target, then write the failing tests. Later tasks replace this whole manifest with the complete resulting block shown in that task only when all newly named source directories exist.

Write exactly these first tests:

```swift
@Test func rejectsUnknownVersionAndExtraKeys() throws {
    #expect(throws: ContractError.unsupportedVersion) {
        try ProbeRequest.decodeStrict(Data(#"{"protocolVersion":2,"messageID":"00000000-0000-0000-0000-000000000001","operation":"ping"}"#.utf8))
    }
    #expect(throws: ContractError.invalidEnvelope) {
        try ProbeRequest.decodeStrict(Data(#"{"protocolVersion":1,"messageID":"00000000-0000-0000-0000-000000000001","operation":"ping","path":"/private/synthetic"}"#.utf8))
    }
}

@Test func cancellationUsesFreshMessageIDAndExplicitTarget() throws {
    let jobID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let cancelID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    #expect(throws: ContractError.invalidCorrelation) {
        try ProbeRequest(protocolVersion: 1, messageID: jobID, operation: .cancel, targetJobID: jobID).validated()
    }
    let request = try ProbeRequest(protocolVersion: 1, messageID: cancelID, operation: .cancel, targetJobID: jobID).validated()
    #expect(request.targetJobID == jobID)
}

@Test func frameCodecRejectsZeroAndOversizedFrames() throws {
    #expect(throws: FrameError.invalidLength) { try FrameCodec.decode(Data([0, 0, 0, 0])) }
    let length = UInt32(FrameCodec.maximumPayloadBytes + 1).bigEndian
    #expect(throws: FrameError.frameTooLarge) {
        try withUnsafeBytes(of: length) { try FrameCodec.decode(Data($0)) }
    }
}

@Test func responseCannotCarryArbitraryText() throws {
    let response = ProbeResponse(
        protocolVersion: 1,
        messageID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        status: .succeeded,
        codex: .init(threadStarted: true, turnCompleted: true, structuredOutputAccepted: true),
        activeJobCount: 0,
        cleanup: .succeeded
    )
    let encoded = try StrictJSON.encode(response)
    let text = String(decoding: encoded, as: UTF8.self)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(Set(object.keys) == Set(["protocolVersion", "messageID", "status", "codex", "activeJobCount", "cleanup"]))
    #expect(!text.contains(NSHomeDirectory()))
    #expect(!text.contains("stderr"))
}

@Test func everyFiniteWireEnumRoundTrips() throws {
    for value in ProbeOperation.allCases {
        #expect(try StrictJSON.decode(ProbeOperation.self, from: StrictJSON.encode(value)) == value)
    }
    for value in ProbeStatus.allCases {
        #expect(try StrictJSON.decode(ProbeStatus.self, from: StrictJSON.encode(value)) == value)
    }
    for value in CleanupState.allCases {
        #expect(try StrictJSON.decode(CleanupState.self, from: StrictJSON.encode(value)) == value)
    }
    for value in RegistrationStatus.allCases {
        #expect(try StrictJSON.decode(RegistrationStatus.self, from: StrictJSON.encode(value)) == value)
    }
    for value in ScenarioName.allCases {
        #expect(try StrictJSON.decode(ScenarioName.self, from: StrictJSON.encode(value)) == value)
    }
}
```

- [ ] **Step 2: Run the focused tests and confirm the red state**

Run:

```bash
helper_scratch="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-helper-contract.XXXXXX")"
swift test --package-path Spikes/HelperIPCProbe --scratch-path "$helper_scratch" --filter HelperIPCProtocolTests --no-parallel
rm -rf "$helper_scratch"
```

Expected: compile failure because `ProbeRequest` does not exist; the manifest itself loads and all declared target directories exist.

- [ ] **Step 3: Implement the exact finite types and strict codec**

Define these public interfaces without free-form diagnostic strings:

```swift
public enum IPCProtocolVersion {
    public static let current: UInt16 = 1
}

public enum ContractError: Error, Sendable, Equatable {
    case unsupportedVersion
    case invalidEnvelope
    case invalidCorrelation
}

public enum FrameError: Error, Sendable, Equatable {
    case invalidLength
    case frameTooLarge
    case incompleteFrame
    case trailingBytes
}

public enum StrictJSON {
    public static func encode<Value: Encodable>(_ value: Value) throws -> Data
    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value
}

public enum ProbeOperation: String, Codable, Sendable, CaseIterable {
    case ping
    case runSyntheticCodex
    case holdUntilCancelled
    case crashAfterCodexStarts
    case cancel
}

public enum ProbeStatus: String, Codable, Sendable, CaseIterable {
    case succeeded
    case unsupportedVersion
    case invalidEnvelope
    case authenticationFailed
    case discoveryFailed
    case helperUnavailable
    case duplicateJob
    case timedOut
    case cancelled
    case helperCrashed
    case codexMissing
    case codexLaunchFailed
    case codexProtocolFailed
    case codexOutputRejected
    case cleanupFailed
}

public enum CleanupState: String, Codable, Sendable, Equatable, CaseIterable {
    case notObserved
    case succeeded
    case failed
}

public enum RegistrationStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case failed
}

public enum ScenarioName: String, Codable, Sendable, Equatable, CaseIterable {
    case ping
    case syntheticCodex
    case explicitCancellation
    case timeout
    case helperCrash
}

public struct ProbeRequest: Codable, Sendable, Equatable {
    public let protocolVersion: UInt16
    public let messageID: UUID
    public let operation: ProbeOperation
    public let targetJobID: UUID?
    public init(protocolVersion: UInt16, messageID: UUID, operation: ProbeOperation, targetJobID: UUID?)
    public func validated() throws -> Self
    public static func decodeStrict(_ data: Data) throws -> Self
}

public struct CodexOutcome: Codable, Sendable, Equatable {
    public let threadStarted: Bool
    public let turnCompleted: Bool
    public let structuredOutputAccepted: Bool
    public init(threadStarted: Bool, turnCompleted: Bool, structuredOutputAccepted: Bool)
}

public struct ProbeResponse: Codable, Sendable, Equatable {
    public let protocolVersion: UInt16
    public let messageID: UUID
    public let status: ProbeStatus
    public let codex: CodexOutcome?
    public let activeJobCount: UInt16?
    public let cleanup: CleanupState
    public init(protocolVersion: UInt16, messageID: UUID, status: ProbeStatus, codex: CodexOutcome?, activeJobCount: UInt16?, cleanup: CleanupState)
    public static func decodeStrict(_ data: Data) throws -> Self
}

public struct SignedFrame: Codable, Sendable, Equatable {
    public let protocolVersion: UInt16
    public let sessionID: Data
    public let sequence: UInt64
    public let payload: Data
    public let signature: Data
    public init(protocolVersion: UInt16, sessionID: Data, sequence: UInt64, payload: Data, signature: Data)
    public static func decodeStrict(_ data: Data) throws -> Self
}

public enum FrameCodec {
    public static let maximumPayloadBytes = 16_384
    public static func encode(_ payload: Data) throws -> Data
    public static func decode(_ frame: Data) throws -> Data
}
```

`ProbeRequest.validated()` requires protocol 1; `.cancel` requires a fresh `messageID`, non-nil `targetJobID`, and `messageID != targetJobID`; all other operations require `targetJobID == nil`. Every public wire model has the public initializer shown. `decodeStrict` first parses with `JSONSerialization`, compares the exact key set, then decodes; implement strict entrypoints for request, response, both hellos, signed frame, and later evidence. `StrictJSON.encode` uses `.sortedKeys` and `.withoutEscapingSlashes`. `FrameCodec.decode` requires exactly one complete frame, rejects trailing bytes, and never allocates from an unvalidated length.

- [ ] **Step 4: Run the focused tests and confirm green**

Run the Step 2 command again.

Expected: all `HelperIPCProtocolTests` pass; no test output contains a home path, raw payload, or arbitrary error description.

- [ ] **Step 5: Commit the contract**

```bash
git add Spikes/HelperIPCProbe/Package.swift Spikes/HelperIPCProbe/Sources/HelperIPCProtocol Spikes/HelperIPCProbe/Tests/HelperIPCProtocolTests/WireContractTests.swift
git commit -m "spike: define finite helper IPC contract"
```

---

### Task 2: Mutual authentication and owner-only identity/runtime stores

**Files:**
- Create: `Spikes/HelperIPCProbe/Sources/HelperIPCProtocol/Authentication.swift`
- Create: `Spikes/HelperIPCProbe/Sources/HelperIPCProtocol/IdentityStore.swift`
- Create: `Spikes/HelperIPCProbe/Tests/HelperIPCProtocolTests/AuthenticationTests.swift`

**Interfaces:**
- Consumes: Task 1 wire types.
- Produces: complete public authentication/session/store APIs below. No pairing executable creates another owner’s key.

- [ ] **Step 1: Write RED with complete test helpers**

Define in the test file:

```swift
private struct SessionFixture {
    var client: AuthenticatedSession; var server: AuthenticatedSession
    let mainPrivate: Curve25519.Signing.PrivateKey; let mainPublic: Curve25519.Signing.PublicKey
    static func make() throws -> Self {
        let main = Curve25519.Signing.PrivateKey(), helper = Curve25519.Signing.PrivateKey()
        let clientHello = try PeerAuthenticator.makeClientHello(privateKey: main, nonce: Data(repeating: 0x11, count: 32))
        try PeerAuthenticator.verifyClientHello(clientHello, pinnedKey: main.publicKey)
        let serverHello = try PeerAuthenticator.makeServerHello(clientHello: clientHello, privateKey: helper, nonce: Data(repeating: 0x22, count: 32))
        return Self(
            client: try PeerAuthenticator.verifyServerHello(serverHello, clientHello: clientHello, pinnedKey: helper.publicKey),
            server: try PeerAuthenticator.serverSession(clientHello: clientHello, serverHello: serverHello),
            mainPrivate: main, mainPublic: main.publicKey
        )
    }
}
private final class RecordingKeychainBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: Data] = [:]
    func read(service: String, account: String) throws -> Data? { lock.withLock { values[service + "|" + account] } }
    func replace(service: String, account: String, value: Data) throws { lock.withLock { values[service + "|" + account] = value } }
    func delete(service: String, account: String) throws { lock.withLock { values.removeValue(forKey: service + "|" + account) } }
    var remainingKeys: [String] { lock.withLock { values.keys.sorted() } }
}
```

Write these tests immediately below the helpers:

```swift
@Test func wrongKeyAndReplayFailClosed() throws {
    var fixture = try SessionFixture.make()
    let payload = Data("ping".utf8)
    let frame = try fixture.client.sign(payload: payload, privateKey: fixture.mainPrivate)
    let wrong = Curve25519.Signing.PrivateKey().publicKey
    #expect(throws: AuthenticationError.invalidSignature) { try fixture.server.verify(frame, pinnedKey: wrong) }
    #expect(try fixture.server.verify(frame, pinnedKey: fixture.mainPublic) == payload)
    #expect(throws: AuthenticationError.replayedOrOutOfOrder) { try fixture.server.verify(frame, pinnedKey: fixture.mainPublic) }
}

@Test func identityAndRuntimeStoresReplaceAndDeleteExactItems() throws {
    let backend = RecordingKeychainBackend()
    let owner = OwnedIdentityStore(service: "test.owner", privateKeyAccount: "private", peerPublicKeyAccount: "peer", backend: backend)
    let first = try owner.loadOrCreatePrivateKey().rawRepresentation
    #expect(try owner.loadOrCreatePrivateKey().rawRepresentation == first)
    #expect(try owner.exportPublicKey().count == 32)
    let peer = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
    try owner.replacePeerPublicKey(peer)
    #expect(try owner.peerPublicKey().rawRepresentation == peer)
    let runtime = HelperRuntimeStore(service: "test.owner", account: "runtime", backend: backend)
    let configuration = HelperRuntimeConfiguration(codexExecutablePath: "/synthetic/codex", callerRootPath: "/synthetic/root")
    try runtime.replace(configuration)
    #expect(try runtime.load() == configuration)
    try owner.deleteAll()
    try runtime.delete()
    #expect(backend.remainingKeys.isEmpty)
}

@Test func strictHellosAndRuntimeRejectExtraKeys() throws {
    let documents = [
        Data(#"{"supportedVersions":[1],"nonce":"AA==","signature":"AA==","extra":true}"#.utf8),
        Data(#"{"selectedVersion":1,"clientNonce":"AA==","serverNonce":"AA==","signature":"AA==","extra":true}"#.utf8),
        Data(#"{"codexExecutablePath":"/synthetic/codex","callerRootPath":"/synthetic/root","extra":true}"#.utf8)
    ]
    #expect(throws: ContractError.invalidEnvelope) { try ClientHello.decodeStrict(documents[0]) }
    #expect(throws: ContractError.invalidEnvelope) { try ServerHello.decodeStrict(documents[1]) }
    #expect(throws: ContractError.invalidEnvelope) { try HelperRuntimeConfiguration.decodeStrict(documents[2]) }
}
```

- [ ] **Step 2: Run RED**

Run the Task 1 command. Expected: compile failure for missing `AuthenticatedSession`, not an absent manifest target.

- [ ] **Step 3: Implement all cross-target APIs**

```swift
public struct ClientHello: Codable, Sendable, Equatable {
    public let supportedVersions: [UInt16]; public let nonce: Data; public let signature: Data
    public init(supportedVersions: [UInt16], nonce: Data, signature: Data)
    public static func decodeStrict(_ data: Data) throws -> Self
}
public struct ServerHello: Codable, Sendable, Equatable {
    public let selectedVersion: UInt16; public let clientNonce: Data; public let serverNonce: Data; public let signature: Data
    public init(selectedVersion: UInt16, clientNonce: Data, serverNonce: Data, signature: Data)
    public static func decodeStrict(_ data: Data) throws -> Self
}
public enum AuthenticationError: Error, Sendable, Equatable { case invalidHello, unsupportedVersion, invalidSignature, sessionMismatch, replayedOrOutOfOrder }
public enum PeerAuthenticator {
    public static func makeClientHello(privateKey: Curve25519.Signing.PrivateKey, nonce: Data) throws -> ClientHello
    public static func verifyClientHello(_ hello: ClientHello, pinnedKey: Curve25519.Signing.PublicKey) throws
    public static func makeServerHello(clientHello: ClientHello, privateKey: Curve25519.Signing.PrivateKey, nonce: Data) throws -> ServerHello
    public static func verifyServerHello(_ hello: ServerHello, clientHello: ClientHello, pinnedKey: Curve25519.Signing.PublicKey) throws -> AuthenticatedSession
    public static func serverSession(clientHello: ClientHello, serverHello: ServerHello) throws -> AuthenticatedSession
}
public enum SecureNonce { public static func bytes(count: Int) throws -> Data }
public struct AuthenticatedSession: Sendable {
    public let sessionID: Data; public private(set) var nextOutboundSequence: UInt64; public private(set) var expectedInboundSequence: UInt64
    public init(sessionID: Data, nextOutboundSequence: UInt64 = 1, expectedInboundSequence: UInt64 = 1)
    public mutating func sign(payload: Data, privateKey: Curve25519.Signing.PrivateKey) throws -> SignedFrame
    public mutating func verify(_ frame: SignedFrame, pinnedKey: Curve25519.Signing.PublicKey) throws -> Data
}
public protocol KeychainBackend: Sendable {
    func read(service: String, account: String) throws -> Data?
    func replace(service: String, account: String, value: Data) throws
    func delete(service: String, account: String) throws
}
public struct SystemKeychainBackend: KeychainBackend {
    public init()
    public func read(service: String, account: String) throws -> Data?
    public func replace(service: String, account: String, value: Data) throws
    public func delete(service: String, account: String) throws
}
public struct OwnedIdentityStore: Sendable {
    public init(service: String, privateKeyAccount: String, peerPublicKeyAccount: String, backend: any KeychainBackend)
    public func loadOrCreatePrivateKey() throws -> Curve25519.Signing.PrivateKey
    public func exportPublicKey() throws -> Data
    public func replacePeerPublicKey(_ data: Data) throws
    public func peerPublicKey() throws -> Curve25519.Signing.PublicKey
    public func deleteAll() throws
}
public struct HelperRuntimeConfiguration: Codable, Sendable, Equatable {
    public let codexExecutablePath: String; public let callerRootPath: String
    public init(codexExecutablePath: String, callerRootPath: String)
    public static func decodeStrict(_ data: Data) throws -> Self
}
public struct HelperRuntimeStore: Sendable {
    public init(service: String, account: String, backend: any KeychainBackend)
    public func replace(_ configuration: HelperRuntimeConfiguration) throws
    public func load() throws -> HelperRuntimeConfiguration
    public func delete() throws
}
```

The production backend uses the exact service/account, data-protection Keychain, and `WhenUnlockedThisDeviceOnly`. Domain-separate transcript bytes. The five live items are main private/main peer/helper private/helper peer/helper runtime.

- [ ] **Step 4: Run GREEN and commit**

Run Task 1 command; expected protocol/auth tests pass.

```bash
git add Spikes/HelperIPCProbe/Sources/HelperIPCProtocol/Authentication.swift Spikes/HelperIPCProbe/Sources/HelperIPCProtocol/IdentityStore.swift Spikes/HelperIPCProbe/Tests/HelperIPCProtocolTests/AuthenticationTests.swift
git commit -m "spike: add owner-bound helper identities"
```

---

### Task 3: Staged client target, loopback discovery, and direct cancellation

**Files:**
- Modify: `Spikes/HelperIPCProbe/Package.swift` (replace the complete Task 1 `let package = Package(...)` block with the complete Task 3 block below)
- Create: `Spikes/HelperIPCProbe/Sources/HelperIPCClient/HelperDiscovery.swift`
- Create: `Spikes/HelperIPCProbe/Sources/HelperIPCClient/HelperClient.swift`
- Create: `Spikes/HelperIPCProbe/Tests/HelperIPCClientTests/HelperClientTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces: exact dependency-injected client interfaces below.

- [ ] **Step 1: Stage only client targets and write RED with complete fakes**

Create both client source files with imports only, then replace the entire manifest with this resulting block:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HelperIPCProbe",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HelperIPCProtocol", targets: ["HelperIPCProtocol"]),
        .library(name: "HelperIPCClient", targets: ["HelperIPCClient"])
    ],
    targets: [
        .target(name: "HelperIPCProtocol"),
        .target(name: "HelperIPCClient", dependencies: ["HelperIPCProtocol"]),
        .testTarget(name: "HelperIPCProtocolTests", dependencies: ["HelperIPCProtocol"]),
        .testTarget(name: "HelperIPCClientTests", dependencies: ["HelperIPCClient"])
    ]
)
```

Define every helper in the test file:

```swift
private actor FakeChannel: HelperChannel {
    private(set) var requests: [ProbeRequest] = []
    private(set) var invalidated = false
    let forcedResponseID: UUID?
    init(forcedResponseID: UUID? = nil) { self.forcedResponseID = forcedResponseID }
    func roundTrip(_ request: ProbeRequest, timeout: Duration) async throws -> ProbeResponse {
        requests.append(request)
        return ProbeResponse(protocolVersion: 1, messageID: forcedResponseID ?? request.messageID, status: request.operation == .cancel ? .cancelled : .succeeded, codex: nil, activeJobCount: 0, cleanup: .succeeded)
    }
    func invalidate() async { invalidated = true }
}
private struct FakeDiscovery: HelperDiscovering {
    let values: [DiscoveredCandidate]
    func candidates(expectedInstance: Data, timeout: Duration, maximum: Int) async throws -> [DiscoveredCandidate] {
        Array(values.filter { $0.txtProtocol == 1 && $0.instanceID == expectedInstance }.prefix(maximum))
    }
}
private actor FakeConnector: HelperConnecting {
    let channel: any HelperChannel; private(set) var attempted: [DiscoveredCandidate] = []
    init(channel: any HelperChannel) { self.channel = channel }
    func connect(to candidate: DiscoveredCandidate, identities: ClientIdentities, timeout: Duration) async throws -> any HelperChannel {
        attempted.append(candidate); return channel
    }
}
private final class SequentialIDs: @unchecked Sendable {
    private let lock = NSLock(); private var values: [UUID]
    init(_ values: [UUID]) { self.values = values }
    func next() -> UUID { lock.withLock { values.removeFirst() } }
}

@Test func explicitCancelUsesFreshIDAndTarget() async {
    let jobID = UUID(), cancelID = UUID(), channel = FakeChannel(), ids = SequentialIDs([jobID, cancelID])
    let instance = Data(repeating: 7, count: 16)
    let candidate = DiscoveredCandidate(endpoint: .hostPort(host: "127.0.0.1", port: 41001), txtProtocol: 1, instanceID: instance)
    let client = HelperClient(
        discovery: FakeDiscovery(values: [candidate]), connector: FakeConnector(channel: channel),
        identities: ClientIdentities(mainPrivateKey: Curve25519.Signing.PrivateKey(), helperPublicKey: Curve25519.Signing.PrivateKey().publicKey),
        expectedInstance: instance, maximumCandidates: 3, makeMessageID: ids.next
    )
    let job = await client.start(.holdUntilCancelled, timeout: .seconds(3))
    let ack = await client.cancel(targetJobID: job.jobID, timeout: .seconds(3))
    let requests = await channel.requests
    #expect(ack.messageID == cancelID)
    #expect(requests.last == ProbeRequest(protocolVersion: 1, messageID: cancelID, operation: .cancel, targetJobID: jobID))
    #expect(await client.pendingRequestCount == 0)
}

@Test func txtFilteringOccursBeforeCandidateLimit() {
    let instance = Data(repeating: 7, count: 16)
    let wrong = DiscoveredCandidate(endpoint: .hostPort(host: "127.0.0.1", port: 41000), txtProtocol: 2, instanceID: instance)
    let first = DiscoveredCandidate(endpoint: .hostPort(host: "127.0.0.1", port: 41001), txtProtocol: 1, instanceID: instance)
    let second = DiscoveredCandidate(endpoint: .hostPort(host: "::1", port: 41002), txtProtocol: 1, instanceID: instance)
    #expect(NetworkHelperDiscovery.select([wrong, first, second], expectedInstance: instance, maximum: 2) == [first, second])
}

@Test func loopbackValidationRejectsResolvedAndConnectedNonLoopback() {
    #expect(LoopbackEndpointValidator.isLoopback(.hostPort(host: "127.0.0.1", port: 41001)))
    #expect(LoopbackEndpointValidator.isLoopback(.hostPort(host: "::1", port: 41001)))
    #expect(!LoopbackEndpointValidator.isLoopback(.hostPort(host: "192.0.2.1", port: 41001)))
}

@Test func mismatchedReplyInvalidatesChannelAndClearsPending() async {
    let requestID = UUID(), channel = FakeChannel(forcedResponseID: UUID()), ids = SequentialIDs([requestID])
    let instance = Data(repeating: 7, count: 16)
    let candidate = DiscoveredCandidate(endpoint: .hostPort(host: "127.0.0.1", port: 41001), txtProtocol: 1, instanceID: instance)
    let client = HelperClient(discovery: FakeDiscovery(values: [candidate]), connector: FakeConnector(channel: channel), identities: ClientIdentities(mainPrivateKey: .init(), helperPublicKey: Curve25519.Signing.PrivateKey().publicKey), expectedInstance: instance, makeMessageID: ids.next)
    #expect(await client.performFinite(.ping, timeout: .seconds(3)).status == .invalidEnvelope)
    #expect(await channel.invalidated)
    #expect(await client.pendingRequestCount == 0)
}
```

- [ ] **Step 2: Run RED**

```bash
helper_scratch="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-helper-transport.XXXXXX")"
swift test --package-path Spikes/HelperIPCProbe --scratch-path "$helper_scratch" --filter HelperIPCClientTests --no-parallel
rm -rf "$helper_scratch"
```

Expected: compile failure for missing `HelperChannel`; all declared target directories exist.

- [ ] **Step 3: Implement exact client interfaces**

```swift
public struct DiscoveredCandidate: Sendable, Equatable {
    public let endpoint: NWEndpoint; public let txtProtocol: UInt16; public let instanceID: Data
    public init(endpoint: NWEndpoint, txtProtocol: UInt16, instanceID: Data)
}
public enum InstanceIdentity {
    public static func pinned(mainPublicKey: Data) -> Data
}
public struct ClientIdentities: Sendable {
    public let mainPrivateKey: Curve25519.Signing.PrivateKey; public let helperPublicKey: Curve25519.Signing.PublicKey
    public init(mainPrivateKey: Curve25519.Signing.PrivateKey, helperPublicKey: Curve25519.Signing.PublicKey)
}
public protocol HelperDiscovering: Sendable {
    func candidates(expectedInstance: Data, timeout: Duration, maximum: Int) async throws -> [DiscoveredCandidate]
}
public protocol HelperChannel: Sendable {
    func roundTrip(_ request: ProbeRequest, timeout: Duration) async throws -> ProbeResponse
    func invalidate() async
}
public protocol HelperConnecting: Sendable {
    func connect(to candidate: DiscoveredCandidate, identities: ClientIdentities, timeout: Duration) async throws -> any HelperChannel
}
public enum LoopbackEndpointValidator {
    public static func isLoopback(_ endpoint: NWEndpoint) -> Bool
}
public final class NetworkHelperDiscovery: HelperDiscovering, @unchecked Sendable {
    public typealias BrowserFactory = @Sendable (NWBrowser.Descriptor, NWParameters) -> NWBrowser
    public init(serviceType: String, queue: DispatchQueue, makeBrowser: @escaping BrowserFactory = { NWBrowser(for: $0, using: $1) })
    public static func select(_ candidates: [DiscoveredCandidate], expectedInstance: Data, maximum: Int) -> [DiscoveredCandidate]
    public func candidates(expectedInstance: Data, timeout: Duration, maximum: Int) async throws -> [DiscoveredCandidate]
}
public final class NetworkHelperConnector: HelperConnecting, @unchecked Sendable {
    public typealias ConnectionFactory = @Sendable (NWEndpoint, NWParameters) -> NWConnection
    public init(queue: DispatchQueue, makeConnection: @escaping ConnectionFactory = { NWConnection(to: $0, using: $1) })
    public func connect(to candidate: DiscoveredCandidate, identities: ClientIdentities, timeout: Duration) async throws -> any HelperChannel
}
public struct StartedJob: Sendable {
    public let jobID: UUID; public let response: Task<ProbeResponse, Never>
    public init(jobID: UUID, response: Task<ProbeResponse, Never>)
}
public final class HelperClient: @unchecked Sendable {
    public init(discovery: any HelperDiscovering, connector: any HelperConnecting, identities: ClientIdentities, expectedInstance: Data, maximumCandidates: Int = 3, makeMessageID: @escaping @Sendable () -> UUID = UUID.init)
    public func start(_ operation: ProbeOperation, timeout: Duration) async -> StartedJob
    public func cancel(targetJobID: UUID, timeout: Duration) async -> ProbeResponse
    public func performFinite(_ operation: ProbeOperation, timeout: Duration) async -> ProbeResponse
    public func waitUntilActive(jobID: UUID, timeout: Duration) async -> Bool
    public var pendingRequestCount: Int { get async }
}
```

Implement the concrete production methods with this code; `NWAsync.ready/send/receiveFrame` are the exact continuation wrappers shown immediately afterward:

```swift
public enum TransportError: Error, Sendable, Equatable { case failed; case timedOut; case nonLoopback; case invalidTXT }

public static func select(_ candidates: [DiscoveredCandidate], expectedInstance: Data, maximum: Int) -> [DiscoveredCandidate] {
    Array(candidates.lazy.filter { $0.txtProtocol == 1 && $0.instanceID == expectedInstance }.prefix(maximum))
}

public func candidates(expectedInstance: Data, timeout: Duration, maximum: Int) async throws -> [DiscoveredCandidate] {
    let parameters = NWParameters.tcp
    parameters.acceptLocalOnly = true
    let browser = makeBrowser(.bonjourWithTXTRecord(type: serviceType, domain: nil), parameters)
    return try await withTaskCancellationHandler {
        try await withThrowingTaskGroup(of: [DiscoveredCandidate].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let gate = ContinuationGate(continuation)
                    browser.stateUpdateHandler = { state in if case .failed = state { gate.resume(throwing: TransportError.failed) } }
                    browser.browseResultsChangedHandler = { results, _ in
                        let decoded = results.compactMap { result -> DiscoveredCandidate? in
                            guard case let .bonjour(txt) = result.metadata,
                                  txt.dictionary.keys.sorted() == ["instance", "pv"],
                                  txt.dictionary["pv"] == "1",
                                  let encoded = txt.dictionary["instance"], let instance = Data(base64Encoded: encoded)
                            else { return nil }
                            return DiscoveredCandidate(endpoint: result.endpoint, txtProtocol: 1, instanceID: instance)
                        }
                        let selected = Self.select(decoded, expectedInstance: expectedInstance, maximum: maximum)
                        if !selected.isEmpty { gate.resume(returning: selected) }
                    }
                    browser.start(queue: queue)
                }
            }
            group.addTask { try await Task.sleep(for: timeout); throw TransportError.timedOut }
            let value = try await group.next()!
            group.cancelAll(); browser.cancel(); return value
        }
    } onCancel: { browser.cancel() }
}

public func connect(to candidate: DiscoveredCandidate, identities: ClientIdentities, timeout: Duration) async throws -> any HelperChannel {
    let parameters = NWParameters.tcp
    parameters.acceptLocalOnly = true
    let connection = makeConnection(candidate.endpoint, parameters)
    connection.start(queue: queue)
    try await NWAsync.ready(connection, timeout: timeout)
    guard let resolved = connection.currentPath?.remoteEndpoint, LoopbackEndpointValidator.isLoopback(resolved) else { connection.cancel(); throw TransportError.nonLoopback }
    let clientHello = try PeerAuthenticator.makeClientHello(privateKey: identities.mainPrivateKey, nonce: SecureNonce.bytes(count: 32))
    try await NWAsync.send(FrameCodec.encode(StrictJSON.encode(clientHello)), on: connection)
    let serverPayload = try await NWAsync.receivePayload(from: connection, timeout: timeout)
    let serverHello = try ServerHello.decodeStrict(serverPayload)
    let session = try PeerAuthenticator.verifyServerHello(serverHello, clientHello: clientHello, pinnedKey: identities.helperPublicKey)
    guard let postHandshake = connection.currentPath?.remoteEndpoint, LoopbackEndpointValidator.isLoopback(postHandshake) else { connection.cancel(); throw TransportError.nonLoopback }
    return NetworkHelperChannel(connection: connection, session: session, mainPrivateKey: identities.mainPrivateKey, helperPublicKey: identities.helperPublicKey)
}
```

```swift
private final class ContinuationGate<Value>: @unchecked Sendable {
    private let lock = NSLock(); private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func resume(returning value: Value) { lock.withLock { continuation?.resume(returning: value); continuation = nil } }
    func resume(throwing error: Error) { lock.withLock { continuation?.resume(throwing: error); continuation = nil } }
}

public enum NWAsync {
    public static func ready(_ connection: NWConnection, timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await withCheckedThrowingContinuation { continuation in
                let gate = ContinuationGate(continuation)
                connection.stateUpdateHandler = { state in
                    if case .ready = state { gate.resume(returning: ()) }
                    if case .failed = state { gate.resume(throwing: TransportError.failed) }
                }
            } }
            group.addTask { try await Task.sleep(for: timeout); throw TransportError.timedOut }
            _ = try await group.next(); group.cancelAll()
        }
    }
    public static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in error == nil ? continuation.resume() : continuation.resume(throwing: TransportError.failed) })
        }
    }
    public static func receivePayload(from connection: NWConnection, timeout: Duration) async throws -> Data {
        let frame = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 4, maximumLength: FrameCodec.maximumPayloadBytes + 4) { data, _, _, error in
                    if let data, error == nil { continuation.resume(returning: data) } else { continuation.resume(throwing: TransportError.failed) }
                }
            } }
            group.addTask { try await Task.sleep(for: timeout); throw TransportError.timedOut }
            let value = try await group.next()!; group.cancelAll(); return value
        }
        return try FrameCodec.decode(frame)
    }
}

private actor NetworkHelperChannel: HelperChannel {
    let connection: NWConnection
    var session: AuthenticatedSession
    let mainPrivateKey: Curve25519.Signing.PrivateKey
    let helperPublicKey: Curve25519.Signing.PublicKey
    init(connection: NWConnection, session: AuthenticatedSession, mainPrivateKey: Curve25519.Signing.PrivateKey, helperPublicKey: Curve25519.Signing.PublicKey) {
        self.connection = connection; self.session = session; self.mainPrivateKey = mainPrivateKey; self.helperPublicKey = helperPublicKey
    }
    func roundTrip(_ request: ProbeRequest, timeout: Duration) async throws -> ProbeResponse {
        let signed = try session.sign(payload: StrictJSON.encode(request), privateKey: mainPrivateKey)
        try await NWAsync.send(FrameCodec.encode(StrictJSON.encode(signed)), on: connection)
        let framePayload = try await NWAsync.receivePayload(from: connection, timeout: timeout)
        let received = try SignedFrame.decodeStrict(framePayload)
        let payload = try session.verify(received, pinnedKey: helperPublicKey)
        return try ProbeResponse.decodeStrict(payload)
    }
    func invalidate() async { connection.cancel() }
}
```

`HelperClient` tries selected candidates in order, rejects a response whose `messageID` differs from the request, invalidates on every terminal failure, and timeout calls `cancel(targetJobID:)` with a new ID.

- [ ] **Step 4: Run GREEN and commit**

Run Step 2; expected client tests pass.

```bash
git add Spikes/HelperIPCProbe/Package.swift Spikes/HelperIPCProbe/Sources/HelperIPCClient Spikes/HelperIPCProbe/Tests/HelperIPCClientTests
git commit -m "spike: add authenticated helper client"
```

---

### Task 4: Staged authenticated server and job registry

**Files:**
- Modify: `Spikes/HelperIPCProbe/Package.swift` (replace the complete Task 3 manifest block with the complete Task 4 block below)
- Create: `Spikes/HelperIPCProbe/Sources/HelperIPCServer/HelperServer.swift`
- Create: `Spikes/HelperIPCProbe/Sources/HelperIPCServer/JobRegistry.swift`
- Create: `Spikes/HelperIPCProbe/Sources/HelperIPCServer/ProbeExecutor.swift`
- Create: `Spikes/HelperIPCProbe/Tests/HelperIPCServerTests/HelperServerTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: exact injected server types below.

- [ ] **Step 1: Stage server targets and write RED with complete fixture**

Create all three server source files with imports only, then replace the entire manifest with this resulting block:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HelperIPCProbe",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HelperIPCProtocol", targets: ["HelperIPCProtocol"]),
        .library(name: "HelperIPCClient", targets: ["HelperIPCClient"]),
        .library(name: "HelperIPCServer", targets: ["HelperIPCServer"])
    ],
    targets: [
        .target(name: "HelperIPCProtocol"),
        .target(name: "HelperIPCClient", dependencies: ["HelperIPCProtocol"]),
        .target(name: "HelperIPCServer", dependencies: ["HelperIPCProtocol", "HelperIPCClient"]),
        .testTarget(name: "HelperIPCProtocolTests", dependencies: ["HelperIPCProtocol"]),
        .testTarget(name: "HelperIPCClientTests", dependencies: ["HelperIPCClient"]),
        .testTarget(name: "HelperIPCServerTests", dependencies: ["HelperIPCServer"])
    ]
)
```

Define `RecordingExecutor`, `InMemoryServerTransport`, and `ServerFixture` in the test file:

```swift
private actor RecordingExecutor: ProbeExecuting {
    private(set) var cancelled: [UUID] = []
    private var started: Set<UUID> = []
    func execute(operation: ProbeOperation, jobID: UUID) async -> ProbeResponse {
        started.insert(jobID)
        while operation == .holdUntilCancelled && !Task.isCancelled { await Task.yield() }
        return ProbeResponse(protocolVersion: 1, messageID: jobID, status: Task.isCancelled ? .cancelled : .succeeded, codex: nil, activeJobCount: 0, cleanup: .succeeded)
    }
    func cancel(jobID: UUID) async { cancelled.append(jobID) }
    func waitUntilStarted(_ jobID: UUID) async -> Bool {
        for _ in 0..<10_000 { if started.contains(jobID) { return true }; await Task.yield() }
        return false
    }
}
private actor InMemoryServerTransport: ServerTransport {
    private(set) var replies: [ProbeResponse] = []
    private var inbound: (@Sendable (AuthenticatedInbound) async -> Void)?
    func start(parameters: ServerParameters, onInbound: @escaping @Sendable (AuthenticatedInbound) async -> Void) async throws { inbound = onInbound }
    func reply(_ response: ProbeResponse, to connectionID: UUID) async { replies.append(response) }
    func stop() async {}
}
private struct ServerFixture {
    let transport: InMemoryServerTransport; let executor: RecordingExecutor; let registry: JobRegistry; let server: HelperServer
    static func make() -> Self {
        let transport = InMemoryServerTransport(), executor = RecordingExecutor(), registry = JobRegistry()
        return Self(transport: transport, executor: executor, registry: registry, server: HelperServer(transport: transport, executor: executor, registry: registry))
    }
}

private enum TestTimeout: Error { case elapsed }
private func boundedValue<T: Sendable>(_ task: Task<T, Never>, timeout: Duration) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { await task.value }
        group.addTask { try await Task.sleep(for: timeout); throw TestTimeout.elapsed }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}

@Test func cancellationTargetsRunningHoldWithFreshRequestID() async throws {
    let fixture = ServerFixture.make(), connectionID = UUID(), jobID = UUID(), cancelID = UUID()
    let hold = AuthenticatedInbound(connectionID: connectionID, request: ProbeRequest(protocolVersion: 1, messageID: jobID, operation: .holdUntilCancelled, targetJobID: nil), peerAuthenticated: true, remoteIsLoopback: true)
    let holdHandle = Task { await fixture.server.handle(hold) }
    #expect(await fixture.executor.waitUntilStarted(jobID))
    #expect(await fixture.registry.activeCount == 1)
    let cancel = AuthenticatedInbound(connectionID: connectionID, request: ProbeRequest(protocolVersion: 1, messageID: cancelID, operation: .cancel, targetJobID: jobID), peerAuthenticated: true, remoteIsLoopback: true)
    await fixture.server.handle(cancel)
    _ = try await boundedValue(holdHandle, timeout: .seconds(1))
    #expect(await fixture.executor.cancelled == [jobID])
    #expect(await fixture.registry.activeCount == 0)
    let replies = await fixture.transport.replies
    #expect(replies.contains { $0.messageID == cancelID && $0.status == .cancelled })
}
```

- [ ] **Step 2: Run RED**

Run server tests. Expected: compile failure for missing `ProbeExecuting`.

- [ ] **Step 3: Implement exact public interfaces**

```swift
public protocol ProbeExecuting: Sendable {
    func execute(operation: ProbeOperation, jobID: UUID) async -> ProbeResponse
    func cancel(jobID: UUID) async
}
public struct ServerParameters: Sendable {
    public let acceptLocalOnly: Bool; public let serviceType: String; public let txtProtocol: UInt16; public let instanceID: Data
    public init(acceptLocalOnly: Bool, serviceType: String, txtProtocol: UInt16, instanceID: Data)
}
public struct AuthenticatedInbound: Sendable {
    public let connectionID: UUID; public let request: ProbeRequest; public let peerAuthenticated: Bool; public let remoteIsLoopback: Bool
    public init(connectionID: UUID, request: ProbeRequest, peerAuthenticated: Bool, remoteIsLoopback: Bool)
}
public protocol ServerTransport: Sendable {
    func start(parameters: ServerParameters, onInbound: @escaping @Sendable (AuthenticatedInbound) async -> Void) async throws
    func reply(_ response: ProbeResponse, to connectionID: UUID) async
    func stop() async
}
public struct ServerIdentities: Sendable {
    public let helperPrivateKey: Curve25519.Signing.PrivateKey; public let mainPublicKey: Curve25519.Signing.PublicKey
    public init(helperPrivateKey: Curve25519.Signing.PrivateKey, mainPublicKey: Curve25519.Signing.PublicKey)
}
public final class NetworkServerTransport: ServerTransport, @unchecked Sendable {
    public init(identities: ServerIdentities, queue: DispatchQueue)
    public func start(parameters: ServerParameters, onInbound: @escaping @Sendable (AuthenticatedInbound) async -> Void) async throws
    public func reply(_ response: ProbeResponse, to connectionID: UUID) async
    public func stop() async
}
public actor JobRegistry {
    public init()
    public func insert(jobID: UUID, task: Task<ProbeResponse, Never>) -> Bool
    public func cancel(targetJobID: UUID) -> Bool
    public func finish(jobID: UUID)
    public func cancelAll() async
    public var activeCount: UInt16 { get }
}
public final class HelperServer: @unchecked Sendable {
    public init(transport: any ServerTransport, executor: any ProbeExecuting, registry: JobRegistry)
    public func start(parameters: ServerParameters) async throws
    public func handle(_ inbound: AuthenticatedInbound) async
    public func stop() async
    public var activeJobCount: UInt16 { get async }
}
public protocol CodexWorkExecuting: Sendable {
    func runSynthetic(jobID: UUID, timeout: Duration) async -> ProbeResponse
    func runUntilStartedForCrash(jobID: UUID, onStarted: @escaping @Sendable () -> Never) async -> Never
    func cancel(jobID: UUID) async
}
public final class ProbeExecutor: ProbeExecuting, @unchecked Sendable {
    public init(codex: any CodexWorkExecuting, crashNow: @escaping @Sendable () -> Never)
    public func execute(operation: ProbeOperation, jobID: UUID) async -> ProbeResponse
    public func cancel(jobID: UUID) async
}
```

Use these concrete `NetworkServerTransport` method bodies and private peer; Task 4’s resulting manifest explicitly gives `HelperIPCServer` access to public `NWAsync` and loopback validation from `HelperIPCClient`:

```swift
private actor ServerPeer {
    let connection: NWConnection
    var session: AuthenticatedSession
    let helperPrivateKey: Curve25519.Signing.PrivateKey
    let mainPublicKey: Curve25519.Signing.PublicKey
    init(connection: NWConnection, session: AuthenticatedSession, helperPrivateKey: Curve25519.Signing.PrivateKey, mainPublicKey: Curve25519.Signing.PublicKey) {
        self.connection = connection; self.session = session; self.helperPrivateKey = helperPrivateKey; self.mainPublicKey = mainPublicKey
    }
    func receive(timeout: Duration) async throws -> ProbeRequest {
        let frameData = try await NWAsync.receivePayload(from: connection, timeout: timeout)
        let frame = try SignedFrame.decodeStrict(frameData)
        return try ProbeRequest.decodeStrict(session.verify(frame, pinnedKey: mainPublicKey))
    }
    func send(_ response: ProbeResponse) async throws {
        let frame = try session.sign(payload: StrictJSON.encode(response), privateKey: helperPrivateKey)
        try await NWAsync.send(FrameCodec.encode(StrictJSON.encode(frame)), on: connection)
    }
    func cancel() { connection.cancel() }
}

public final class NetworkServerTransport: ServerTransport, @unchecked Sendable {
    private let identities: ServerIdentities, queue: DispatchQueue, lock = NSLock()
    private var listener: NWListener?, peers: [UUID: ServerPeer] = [:]
    public init(identities: ServerIdentities, queue: DispatchQueue) { self.identities = identities; self.queue = queue }
    public func start(parameters: ServerParameters, onInbound: @escaping @Sendable (AuthenticatedInbound) async -> Void) async throws {
        guard parameters.acceptLocalOnly, parameters.txtProtocol == 1 else { throw TransportError.failed }
        let network = NWParameters.tcp; network.acceptLocalOnly = true
        let listener = try NWListener(using: network, on: .any)
        listener.service = NWListener.Service(name: nil, type: parameters.serviceType, domain: nil, txtRecord: NWTXTRecord(["instance": parameters.instanceID.base64EncodedString(), "pv": "1"]))
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            Task {
                do {
                    try await NWAsync.ready(connection, timeout: .seconds(3))
                    guard let first = connection.currentPath?.remoteEndpoint, LoopbackEndpointValidator.isLoopback(first) else { throw TransportError.nonLoopback }
                    let helloData = try await NWAsync.receivePayload(from: connection, timeout: .seconds(3))
                    let clientHello = try ClientHello.decodeStrict(helloData)
                    try PeerAuthenticator.verifyClientHello(clientHello, pinnedKey: self.identities.mainPublicKey)
                    let serverHello = try PeerAuthenticator.makeServerHello(clientHello: clientHello, privateKey: self.identities.helperPrivateKey, nonce: SecureNonce.bytes(count: 32))
                    try await NWAsync.send(FrameCodec.encode(StrictJSON.encode(serverHello)), on: connection)
                    guard let second = connection.currentPath?.remoteEndpoint, LoopbackEndpointValidator.isLoopback(second) else { throw TransportError.nonLoopback }
                    let peer = ServerPeer(connection: connection, session: try PeerAuthenticator.serverSession(clientHello: clientHello, serverHello: serverHello), helperPrivateKey: self.identities.helperPrivateKey, mainPublicKey: self.identities.mainPublicKey)
                    let connectionID = UUID(); self.lock.withLock { self.peers[connectionID] = peer }
                    let request = try await peer.receive(timeout: .seconds(120))
                    await onInbound(AuthenticatedInbound(connectionID: connectionID, request: request, peerAuthenticated: true, remoteIsLoopback: true))
                } catch { connection.cancel() }
            }
        }
        self.listener = listener; listener.start(queue: queue)
    }
    public func reply(_ response: ProbeResponse, to connectionID: UUID) async {
        guard let peer = lock.withLock({ peers.removeValue(forKey: connectionID) }) else { return }
        try? await peer.send(response)
    }
    public func stop() async {
        listener?.cancel(); listener = nil
        let values = lock.withLock { let copy = Array(peers.values); peers.removeAll(); return copy }
        for peer in values { await peer.cancel() }
    }
}
```

`HelperServer.start` passes `{ [weak self] inbound in await self?.handle(inbound) }`. `ProbeExecutor` returns finite success for `.ping`, holds until task cancellation for `.holdUntilCancelled`, delegates `.runSyntheticCodex`, delegates `.crashAfterCodexStarts` to `runUntilStartedForCrash(jobID:onStarted: crashNow)`, and treats `.cancel` as `.invalidEnvelope` because cancellation is handled only by `HelperServer`. Cancel request IDs are never inserted as jobs.

- [ ] **Step 4: Run GREEN and commit**

```bash
git add Spikes/HelperIPCProbe/Package.swift Spikes/HelperIPCProbe/Sources/HelperIPCServer/HelperServer.swift Spikes/HelperIPCProbe/Sources/HelperIPCServer/JobRegistry.swift Spikes/HelperIPCProbe/Sources/HelperIPCServer/ProbeExecutor.swift Spikes/HelperIPCProbe/Tests/HelperIPCServerTests/HelperServerTests.swift
git commit -m "spike: add authenticated helper server"
```

---

### Task 5: Codex worker supervision across cancellation and helper crash

**Files:**
- Modify: `Spikes/HelperIPCProbe/Package.swift` (replace the complete Task 4 manifest block with the complete Task 5 block below)
- Modify: `Spikes/CodexBridgeProbe/Sources/CodexBridgeCore/AppServerProcess.swift:1-620`
- Modify: `Spikes/CodexBridgeProbe/Tests/CodexBridgeCoreTests/AppServerMessageTests.swift:1-494`
- Create: `Spikes/HelperIPCProbe/Sources/HelperIPCServer/CodexWorkerSession.swift`
- Create: `Spikes/HelperIPCProbe/Sources/HelperIPCServer/WorkerOwnership.swift`
- Create: `Spikes/HelperIPCProbe/Sources/helper-ipc-codex-worker/main.swift`
- Create: `Spikes/HelperIPCProbe/Tests/HelperIPCServerTests/CodexWorkerSessionTests.swift`

**Interfaces:**
- Consumes: `CodexBridgeCore.AppServerProcess`, `ProbeExecuting`, `ProbeResponse`, `ProbeStatus`, and `JobRegistry`.
- Produces: `CodexProcessLifecycle`, a backward-compatible `AppServerProcess` lifecycle observer, `CodexWorkerSession`, `WorkerControl`, and `WorkerResult`.

- [ ] **Step 1: Stage worker target and add failing lifecycle/EOF tests**

Create the worker source with imports only, then replace the entire manifest with this resulting block:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HelperIPCProbe",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HelperIPCProtocol", targets: ["HelperIPCProtocol"]),
        .library(name: "HelperIPCClient", targets: ["HelperIPCClient"]),
        .library(name: "HelperIPCServer", targets: ["HelperIPCServer"]),
        .executable(name: "helper-ipc-codex-worker", targets: ["helper-ipc-codex-worker"])
    ],
    dependencies: [.package(path: "../CodexBridgeProbe")],
    targets: [
        .target(name: "HelperIPCProtocol"),
        .target(name: "HelperIPCClient", dependencies: ["HelperIPCProtocol"]),
        .target(name: "HelperIPCServer", dependencies: ["HelperIPCProtocol", "HelperIPCClient"]),
        .executableTarget(name: "helper-ipc-codex-worker", dependencies: ["HelperIPCProtocol", .product(name: "CodexBridgeCore", package: "CodexBridgeProbe")]),
        .testTarget(name: "HelperIPCProtocolTests", dependencies: ["HelperIPCProtocol"]),
        .testTarget(name: "HelperIPCClientTests", dependencies: ["HelperIPCClient"]),
        .testTarget(name: "HelperIPCServerTests", dependencies: ["HelperIPCServer"])
    ]
)
```

Add to the existing Codex tests:

```swift
@Test func reportsFiniteChildLifecycleOnSuccess() async throws {
    let events = LifecycleRecorder()
    let fixture = try ProbeFixture(script: ServerScripts.valid)
    let process = AppServerProcess(
        executableURL: fixture.executableURL,
        temporaryDirectoryRoot: fixture.probeRoot,
        lifecycleObserver: events.record
    )
    _ = try await process.runProbe(timeout: .seconds(3))
    #expect(events.events == [.started, .stopped])
}

@Test func reportsFiniteChildLifecycleOnCancellation() async throws {
    let events = LifecycleRecorder()
    let fixture = try ProbeFixture(script: ServerScripts.blocking)
    let process = AppServerProcess(executableURL: fixture.executableURL, temporaryDirectoryRoot: fixture.probeRoot, lifecycleObserver: events.record)
    let task = Task { try await process.runProbe(timeout: .seconds(3)) }
    while events.events.isEmpty { await Task.yield() }
    task.cancel()
    _ = try? await task.value
    #expect(events.events == [.started, .stopped])
}
```

Define the helpers in that same Codex test file:

```swift
private final class LifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock(); private var storage: [CodexProcessLifecycle] = []
    func record(_ event: CodexProcessLifecycle) { lock.withLock { storage.append(event) } }
    var events: [CodexProcessLifecycle] { lock.withLock { storage } }
}
```

`ProbeFixture` and `ServerScripts.valid/blocking` already exist in this exact test file; use their existing `probeRoot` and `executableURL` properties without adding or renaming fixture state.

Add worker tests:

```swift
@Test func controlPipeEOFStopsWorkerAndRemovesRunDirectory() async throws {
    let fixture = try WorkerFixture.make(mode: .hold)
    try await fixture.start()
    #expect(try await fixture.readEvent() == .codexStarted)
    fixture.closeControlPipe()
    #expect(try await fixture.readResult().status == .cancelled)
    #expect(!fixture.runDirectoryExists)
    #expect(!fixture.childIsRunning)
}

@Test func workerMapsMalformedChildOutputToFiniteStatus() async throws {
    let fixture = try WorkerFixture.make(mode: .malformedJSON)
    try await fixture.start()
    let result = try await fixture.readResult()
    #expect(result.status == .codexProtocolFailed)
    #expect(result.cleanup == .succeeded)
    let encoded = try StrictJSON.encode(result)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(Set(object.keys) == Set(["status", "codex", "cleanup"]))
}
```

Define every worker helper in the same file:

```swift
private final class WorkerFixture: @unchecked Sendable {
    enum Mode { case hold, malformedJSON }
    let root: URL; let session: CodexWorkerSession
    private var resultTask: Task<WorkerResult, Never>?
    static func make(mode: Mode) throws -> WorkerFixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "helper-worker-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let workerBody = mode == .hold
            ? "#!/bin/zsh\nmkdir \"$PWD/run\"\nprint '{\"event\":\"codexStarted\"}'\nwhile IFS= read -r control; do [[ \"$control\" == cancel ]] && break; done\nrmdir \"$PWD/run\"\nprint '{\"status\":\"cancelled\",\"codex\":null,\"cleanup\":\"succeeded\"}'\n"
            : "#!/bin/zsh\nprint not-json\n"
        let worker = try makeExecutable(in: root, name: "worker", body: workerBody)
        let codex = try makeExecutable(in: root, name: "codex", body: "#!/bin/zsh\nexit 0\n")
        return WorkerFixture(root: root, session: CodexWorkerSession(workerExecutableURL: worker, codexExecutableURL: codex, callerRoot: root))
    }
    init(root: URL, session: CodexWorkerSession) { self.root = root; self.session = session }
    func start() async throws { resultTask = Task { await session.run(messageID: UUID(), timeout: .seconds(3)) } }
    func readEvent() async throws -> WorkerEvent {
        while !session.receivedCodexStarted { await Task.yield() }
        return .codexStarted
    }
    func closeControlPipe() { session.closeControlPipeForTesting() }
    func readResult() async throws -> WorkerResult { await resultTask!.value }
    var runDirectoryExists: Bool { FileManager.default.fileExists(atPath: root.appending(path: "run").path) }
    var childIsRunning: Bool { session.isRunning }
}
private func makeExecutable(in root: URL, name: String, body: String) throws -> URL {
    let url = root.appending(path: name); try Data(body.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}
```

- [ ] **Step 2: Run both focused suites and verify red**

```bash
codex_scratch="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-codex-lifecycle.XXXXXX")"
swift test --package-path Spikes/CodexBridgeProbe --scratch-path "$codex_scratch" --filter reportsFiniteChildLifecycleOnSuccess --no-parallel
rm -rf "$codex_scratch"
helper_scratch="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-helper-worker.XXXXXX")"
swift test --package-path Spikes/HelperIPCProbe --scratch-path "$helper_scratch" --filter CodexWorkerSessionTests --no-parallel
rm -rf "$helper_scratch"
```

Expected: compile failures because `CodexProcessLifecycle` and `CodexWorkerSession` do not exist.

- [ ] **Step 3: Add the minimal finite lifecycle hook without changing Codex behavior**

```swift
public enum CodexProcessLifecycle: Sendable, Equatable {
    case started
    case stopped
}

public init(
    executableURL: URL,
    temporaryDirectoryRoot: URL = FileManager.default.temporaryDirectory,
    lifecycleObserver: @escaping @Sendable (CodexProcessLifecycle) -> Void = { _ in },
    privateProcessIdentifierObserver: @escaping @Sendable (Int32?) -> Void = { _ in }
)
```

Call `privateProcessIdentifierObserver(process.processIdentifier)` and `.started` only after `Process.run()` succeeds; call `.stopped` exactly once and then `privateProcessIdentifierObserver(nil)` after exit on every success, error, timeout, and cancellation path. The private PID callback is consumed only by the worker’s mode-0600 ownership receipt and never printed or encoded into evidence. Do not expose an executable path, stderr, or transcript. Preserve all existing initializers/tests and the existing primary-failure/cleanup ownership semantics.

- [ ] **Step 4: Implement the worker control protocol and supervisor**

```swift
public enum WorkerControl: String, Codable, Sendable { case run; case cancel }
public enum WorkerEvent: String, Codable, Sendable { case codexStarted }

public struct WorkerResult: Codable, Sendable, Equatable {
    public let status: ProbeStatus
    public let codex: CodexOutcome?
    public let cleanup: CleanupState
    public init(status: ProbeStatus, codex: CodexOutcome?, cleanup: CleanupState)
}

public struct ExecutableIdentity: Codable, Sendable, Equatable {
    public let device: UInt64; public let inode: UInt64
    public init(device: UInt64, inode: UInt64)
}
public struct OwnedProcessIdentity: Codable, Sendable, Equatable {
    public let pid: Int32; public let startTimeNanoseconds: UInt64; public let executable: ExecutableIdentity; public let processGroupID: Int32
    public init(pid: Int32, startTimeNanoseconds: UInt64, executable: ExecutableIdentity, processGroupID: Int32)
}
public struct WorkerOwnershipReceipt: Codable, Sendable, Equatable {
    public let schemaVersion: UInt16; public let ownershipToken: UUID; public let worker: OwnedProcessIdentity; public let codex: OwnedProcessIdentity?
    public init(schemaVersion: UInt16 = 1, ownershipToken: UUID, worker: OwnedProcessIdentity, codex: OwnedProcessIdentity?)
    public static func decodeStrict(_ data: Data) throws -> Self
}
public protocol ProcessInspecting: Sendable {
    func identity(pid: Int32) -> OwnedProcessIdentity?
}
public struct OwnershipReceiptStore: Sendable {
    public init(callerRoot: URL)
    public func writeAtomically(_ receipt: WorkerOwnershipReceipt) throws
    public func remove(token: UUID) throws
}
public struct OwnershipCleanupPlanner: Sendable {
    public init(inspector: any ProcessInspecting)
    public func matchedTargets(receipt: WorkerOwnershipReceipt, expectedToken: UUID, workerExecutable: ExecutableIdentity, codexExecutable: ExecutableIdentity) -> [Int32]
}

public final class CodexWorkerSession: CodexWorkExecuting, @unchecked Sendable {
    public init(workerExecutableURL: URL, codexExecutableURL: URL, callerRoot: URL, receiptStore: OwnershipReceiptStore? = nil, makeProcess: @escaping @Sendable () -> Process = Process.init)
    public func run(messageID: UUID, timeout: Duration = .seconds(120)) async -> WorkerResult
    public func runSynthetic(jobID: UUID, timeout: Duration) async -> ProbeResponse
    public func runUntilStartedForCrash(jobID: UUID, onStarted: @escaping @Sendable () -> Never) async -> Never
    public func cancel() async
    public var isRunning: Bool { get }
    public var receivedCodexStarted: Bool { get }
    func closeControlPipeForTesting()
}
```

Implement the protocol adapter exactly as follows so the Task 6 `ProbeExecutor(codex: worker, ...)` constructor type-checks:

```swift
public func runSynthetic(jobID: UUID, timeout: Duration) async -> ProbeResponse {
    let result = await run(messageID: jobID, timeout: timeout)
    return ProbeResponse(protocolVersion: 1, messageID: jobID, status: result.status, codex: result.codex, activeJobCount: 0, cleanup: result.cleanup)
}

public func runUntilStartedForCrash(jobID: UUID, onStarted: @escaping @Sendable () -> Never) async -> Never {
    Task { _ = await run(messageID: jobID, timeout: .seconds(120)) }
    while !receivedCodexStarted { await Task.yield() }
    onStarted()
}
```

Add this complete cleanup-planner test fixture and the three mismatch cases to `CodexWorkerSessionTests.swift`:

```swift
private struct FakeProcessInspector: ProcessInspecting {
    let live: [Int32: OwnedProcessIdentity]
    func identity(pid: Int32) -> OwnedProcessIdentity? { live[pid] }
}

@Test func cleanupPlannerTargetsOnlyTokenStartTimeGroupAndExecutableMatches() {
    let token = UUID(), workerExecutable = ExecutableIdentity(device: 1, inode: 10), codexExecutable = ExecutableIdentity(device: 2, inode: 20)
    let worker = OwnedProcessIdentity(pid: 101, startTimeNanoseconds: 1_000, executable: workerExecutable, processGroupID: 101)
    let codex = OwnedProcessIdentity(pid: 102, startTimeNanoseconds: 1_100, executable: codexExecutable, processGroupID: 101)
    let receipt = WorkerOwnershipReceipt(ownershipToken: token, worker: worker, codex: codex)
    let valid = OwnershipCleanupPlanner(inspector: FakeProcessInspector(live: [101: worker, 102: codex]))
    #expect(valid.matchedTargets(receipt: receipt, expectedToken: token, workerExecutable: workerExecutable, codexExecutable: codexExecutable) == [102, 101])

    let reused = OwnedProcessIdentity(pid: 101, startTimeNanoseconds: 9_999, executable: workerExecutable, processGroupID: 101)
    let stale = OwnershipCleanupPlanner(inspector: FakeProcessInspector(live: [101: reused]))
    #expect(stale.matchedTargets(receipt: receipt, expectedToken: token, workerExecutable: workerExecutable, codexExecutable: codexExecutable).isEmpty)

    let wrongExecutable = OwnedProcessIdentity(pid: 102, startTimeNanoseconds: 1_100, executable: ExecutableIdentity(device: 9, inode: 99), processGroupID: 101)
    let mismatch = OwnershipCleanupPlanner(inspector: FakeProcessInspector(live: [101: worker, 102: wrongExecutable]))
    #expect(mismatch.matchedTargets(receipt: receipt, expectedToken: UUID(), workerExecutable: workerExecutable, codexExecutable: codexExecutable).isEmpty)
}
```

The helper launches the worker executable directly with `Process`, no shell, no path in arguments, and three pipes: control stdin, finite-event stdout, and discarded stderr. Provision the helper-only Codex executable URL from its exact Keychain item into the worker over the control pipe as a bounded bootstrap frame; the worker never prints it. The worker constructs `AppServerProcess(executableURL:)`, uses the exact existing synthetic prompt/schema, emits `.codexStarted` on the lifecycle observer, and maps `ProbeError` to the finite `ProbeStatus` allowlist.

The helper generates `ownershipToken`, sends it in the bounded binary bootstrap frame, starts the worker as a new process group, and records the exact worker executable device/inode. The worker records its PID, start time from `proc_pidinfo`, process-group ID, and executable device/inode; after `AppServerProcess` starts Codex it records the child’s corresponding identity and the already-validated external Codex device/inode. `OwnershipReceiptStore` writes strict JSON to `<callerRoot>/private/ownership/<token>.json.tmp`, applies mode `0600`, `fsync`s, and atomically renames to `<token>.json` inside a mode-`0700` directory. This private receipt is never printed, committed, copied to evidence, or included in stderr.

The worker concurrently monitors control stdin. EOF, `.cancel`, outer task cancellation, or deadline cancels `runProbe`; it waits for `AppServerProcess.isChildRunning == false`, removes its exact temporary cwd, writes one `WorkerResult`, removes the receipt, and exits. The internal test-only `closeControlPipeForTesting()` closes only that same write handle, exercising the EOF path rather than calling `cancel()`. For crash cleanup, `OwnershipCleanupPlanner` first requires filename token/content token/runner-held token equality, then re-reads each live PID and requires exact PID, start time, process group, and device/inode equality. It returns Codex before worker only when each independently matches; thus it can terminate the known external Codex child but never a stale/reused or arbitrary PID. Cleanup sends `SIGTERM`, waits 2 seconds, sends `SIGKILL` only to still-matching identities, waits for absence, and removes the receipt. The helper keeps the control write end open for the worker’s lifetime, so helper `SIGKILL` closes it automatically. No raw worker stderr is read or retained.

- [ ] **Step 5: Run full Codex and worker suites**

```bash
codex_scratch="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-codex-lifecycle.XXXXXX")"
swift test --package-path Spikes/CodexBridgeProbe --scratch-path "$codex_scratch" --no-parallel
rm -rf "$codex_scratch"
helper_scratch="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-helper-worker.XXXXXX")"
swift test --package-path Spikes/HelperIPCProbe --scratch-path "$helper_scratch" --filter CodexWorkerSessionTests --no-parallel
rm -rf "$helper_scratch"
```

Expected: existing Codex suite remains 18/18 plus the lifecycle tests; worker tests pass and prove EOF cleanup.

- [ ] **Step 6: Commit worker supervision**

```bash
git add Spikes/CodexBridgeProbe/Sources/CodexBridgeCore/AppServerProcess.swift Spikes/CodexBridgeProbe/Tests/CodexBridgeCoreTests/AppServerMessageTests.swift Spikes/HelperIPCProbe/Sources/HelperIPCServer/CodexWorkerSession.swift Spikes/HelperIPCProbe/Sources/HelperIPCServer/WorkerOwnership.swift Spikes/HelperIPCProbe/Sources/helper-ipc-codex-worker Spikes/HelperIPCProbe/Tests/HelperIPCServerTests/CodexWorkerSessionTests.swift
git commit -m "spike: supervise Codex helper worker"
```

---

### Task 6: Executable modes and owner-executed installed bootstrap

**Files:**
- Modify: `Spikes/HelperIPCProbe/Package.swift` (replace the complete Task 5 manifest block with the complete Task 6 block below)
- Create: `Spikes/HelperIPCProbe/Sources/HelperIPCExecutableCore/CommandModes.swift`
- Create: `Spikes/HelperIPCProbe/Sources/helper-ipc-probe-main/main.swift`
- Create: `Spikes/HelperIPCProbe/Sources/helper-ipc-probe-installer/main.swift`
- Create: `Spikes/HelperIPCProbe/Sources/helper-ipc-probe-helper/main.swift`
- Create: `Spikes/HelperIPCProbe/Tests/HelperIPCExecutableCoreTests/CommandModesTests.swift`
- Create: `Spikes/HelperIPCProbe/Scripts/bootstrap-installed-products.sh`

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces: finite mode parsers and one owner-executed bootstrap.

- [ ] **Step 1: Stage executable targets and write RED**

Create executable-core/test and three executable directories with import-only sources, then replace the entire manifest with this final resulting block:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HelperIPCProbe",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HelperIPCProtocol", targets: ["HelperIPCProtocol"]),
        .library(name: "HelperIPCClient", targets: ["HelperIPCClient"]),
        .library(name: "HelperIPCServer", targets: ["HelperIPCServer"]),
        .library(name: "HelperIPCExecutableCore", targets: ["HelperIPCExecutableCore"]),
        .executable(name: "helper-ipc-probe-main", targets: ["helper-ipc-probe-main"]),
        .executable(name: "helper-ipc-probe-installer", targets: ["helper-ipc-probe-installer"]),
        .executable(name: "helper-ipc-probe-helper", targets: ["helper-ipc-probe-helper"]),
        .executable(name: "helper-ipc-codex-worker", targets: ["helper-ipc-codex-worker"])
    ],
    dependencies: [.package(path: "../CodexBridgeProbe")],
    targets: [
        .target(name: "HelperIPCProtocol"),
        .target(name: "HelperIPCClient", dependencies: ["HelperIPCProtocol"]),
        .target(name: "HelperIPCServer", dependencies: ["HelperIPCProtocol", "HelperIPCClient"]),
        .target(name: "HelperIPCExecutableCore", dependencies: ["HelperIPCProtocol", "HelperIPCClient", "HelperIPCServer"]),
        .executableTarget(name: "helper-ipc-probe-main", dependencies: ["HelperIPCExecutableCore"]),
        .executableTarget(name: "helper-ipc-probe-installer", dependencies: ["HelperIPCExecutableCore"]),
        .executableTarget(name: "helper-ipc-probe-helper", dependencies: ["HelperIPCExecutableCore"]),
        .executableTarget(name: "helper-ipc-codex-worker", dependencies: ["HelperIPCProtocol", .product(name: "CodexBridgeCore", package: "CodexBridgeProbe")]),
        .testTarget(name: "HelperIPCProtocolTests", dependencies: ["HelperIPCProtocol"]),
        .testTarget(name: "HelperIPCClientTests", dependencies: ["HelperIPCClient"]),
        .testTarget(name: "HelperIPCServerTests", dependencies: ["HelperIPCServer"]),
        .testTarget(name: "HelperIPCExecutableCoreTests", dependencies: ["HelperIPCExecutableCore"])
    ]
)
```

Write these tests:

```swift
@Test func noArgumentHelperServes() throws { #expect(try HelperMode.parse([]) == .serve) }
@Test func mainAndInstallerRejectNoArguments() { #expect(throws: ModeError.invalid) { try MainMode.parse([]) }; #expect(throws: ModeError.invalid) { try InstallerMode.parse([]) } }
@Test func helperRejectsServeFlagBecauseServiceManagementPassesNoFlag() { #expect(throws: ModeError.invalid) { try HelperMode.parse(["--serve"]) } }
@Test func exportModeRejectsStdoutAndStderrDescriptors() {
    let provider = FixedPublicKeyProvider(bytes: Data(repeating: 7, count: 32)), writer = RecordingDescriptorWriter()
    #expect(throws: ModeError.unsafeDescriptor) { try PublicKeyExporter(provider: provider, writer: writer, descriptor: STDOUT_FILENO) }
    #expect(throws: ModeError.unsafeDescriptor) { try PublicKeyExporter(provider: provider, writer: writer, descriptor: STDERR_FILENO) }
}
@Test func exportModeWritesOnlyThirtyTwoBinaryBytesToDescriptorThree() throws {
    let writer = RecordingDescriptorWriter()
    let exporter = try PublicKeyExporter(provider: FixedPublicKeyProvider(bytes: Data(repeating: 7, count: 32)), writer: writer, descriptor: 3)
    try exporter.export()
    #expect(writer.writes.count == 1)
    #expect(writer.writes.first?.0 == 3)
    #expect(writer.writes.first?.1 == Data(repeating: 7, count: 32))
    #expect(writer.writes.allSatisfy { $0.0 != STDOUT_FILENO && $0.0 != STDERR_FILENO })
}

private struct FixedPublicKeyProvider: PublicKeyProviding {
    let bytes: Data
    func exportPublicKey() throws -> Data { bytes }
}
private final class RecordingDescriptorWriter: DescriptorWriting, @unchecked Sendable {
    private let lock = NSLock(); private var storage: [(Int32, Data)] = []
    func writeAll(_ data: Data, to descriptor: Int32) throws { lock.withLock { storage.append((descriptor, data)) } }
    var writes: [(Int32, Data)] { lock.withLock { storage } }
}
```

Expected RED: missing `HelperMode`; manifest loads because all new targets have sources.

- [ ] **Step 2: Implement exact modes and owner channels**

```swift
public enum MainMode: Equatable {
    case bootstrapExportPublicKey, bootstrapImportPeerKey, bootstrapReady, run(ScenarioName), deleteState
    public static func parse(_ arguments: [String]) throws -> Self
}
public enum HelperMode: Equatable {
    case serve, bootstrapExportPublicKey, bootstrapImportPeerKey, bootstrapRuntime, bootstrapReady, cleanupOwnedProcesses(token: UUID), deleteState
    public static func parse(_ arguments: [String]) throws -> Self
}
public enum InstallerMode: Equatable {
    case register, status, unregister
    public static func parse(_ arguments: [String]) throws -> Self
}
public enum ModeError: Error, Equatable { case invalid; case unsafeDescriptor; case invalidPublicKeyLength }
public extension ScenarioName {
    var operation: ProbeOperation {
        switch self {
        case .ping: .ping
        case .syntheticCodex: .runSyntheticCodex
        case .explicitCancellation: .holdUntilCancelled
        case .timeout: .holdUntilCancelled
        case .helperCrash: .crashAfterCodexStarts
        }
    }
}
public protocol PublicKeyProviding: Sendable { func exportPublicKey() throws -> Data }
extension OwnedIdentityStore: PublicKeyProviding {}
public protocol DescriptorWriting: Sendable { func writeAll(_ data: Data, to descriptor: Int32) throws }
public struct POSIXDescriptorWriter: DescriptorWriting { public init(); public func writeAll(_ data: Data, to descriptor: Int32) throws }
public struct PublicKeyExporter: Sendable {
    public init(provider: any PublicKeyProviding, writer: any DescriptorWriting = POSIXDescriptorWriter(), descriptor: Int32 = 3) throws
    public func export() throws
}
public enum FiniteStatusLine { public static func encode(_ response: ProbeResponse) throws -> String }
public enum ServiceRunLoop { public static func waitUntilCancelled() async }
public struct InstallerController {
    public init(service: SMAppService)
    public func perform(_ mode: InstallerMode) throws -> RegistrationStatus
}
public struct ScenarioRunResult: Codable, Sendable, Equatable {
    public let name: ScenarioName; public let response: ProbeResponse; public let helperRecovered: Bool
    public init(name: ScenarioName, response: ProbeResponse, helperRecovered: Bool)
}
public final class MainScenarioRunner: @unchecked Sendable {
    public init(client: HelperClient)
    public func run(_ scenario: ScenarioName) async -> ScenarioRunResult
}
public enum BoundedAwait {
    public static func value<T: Sendable>(_ task: Task<T, Never>, timeout: Duration) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
```

Implement `MainScenarioRunner.run` with distinct paths, not `scenario.operation` forwarding:

```swift
public func run(_ scenario: ScenarioName) async -> ScenarioRunResult {
    switch scenario {
    case .ping:
        return ScenarioRunResult(name: scenario, response: await client.performFinite(.ping, timeout: .seconds(3)), helperRecovered: false)
    case .syntheticCodex:
        return ScenarioRunResult(name: scenario, response: await client.performFinite(.runSyntheticCodex, timeout: .seconds(120)), helperRecovered: false)
    case .explicitCancellation:
        let job = await client.start(.holdUntilCancelled, timeout: .seconds(120))
        guard await client.waitUntilActive(jobID: job.jobID, timeout: .seconds(3)) else {
            return ScenarioRunResult(name: scenario, response: ProbeResponse(protocolVersion: 1, messageID: job.jobID, status: .helperUnavailable, codex: nil, activeJobCount: nil, cleanup: .notObserved), helperRecovered: false)
        }
        let acknowledgement = await client.cancel(targetJobID: job.jobID, timeout: .seconds(3))
        guard acknowledgement.status == .cancelled else { return ScenarioRunResult(name: scenario, response: acknowledgement, helperRecovered: false) }
        let completion = await BoundedAwait.value(job.response, timeout: .seconds(3)) ?? ProbeResponse(protocolVersion: 1, messageID: job.jobID, status: .timedOut, codex: nil, activeJobCount: nil, cleanup: .failed)
        return ScenarioRunResult(name: scenario, response: completion, helperRecovered: false)
    case .timeout:
        let job = await client.start(.holdUntilCancelled, timeout: .seconds(120))
        guard await client.waitUntilActive(jobID: job.jobID, timeout: .seconds(3)) else {
            return ScenarioRunResult(name: scenario, response: ProbeResponse(protocolVersion: 1, messageID: job.jobID, status: .helperUnavailable, codex: nil, activeJobCount: nil, cleanup: .notObserved), helperRecovered: false)
        }
        try? await Task.sleep(for: .milliseconds(250))
        _ = await client.cancel(targetJobID: job.jobID, timeout: .seconds(3))
        _ = await BoundedAwait.value(job.response, timeout: .seconds(3))
        return ScenarioRunResult(name: scenario, response: ProbeResponse(protocolVersion: 1, messageID: job.jobID, status: .timedOut, codex: nil, activeJobCount: 0, cleanup: .succeeded), helperRecovered: false)
    case .helperCrash:
        let response = await client.performFinite(.crashAfterCodexStarts, timeout: .seconds(120))
        let mapped = response.status == .helperUnavailable ? ProbeResponse(protocolVersion: 1, messageID: response.messageID, status: .helperCrashed, codex: CodexOutcome(threadStarted: true, turnCompleted: false, structuredOutputAccepted: false), activeJobCount: nil, cleanup: .notObserved) : response
        return ScenarioRunResult(name: scenario, response: mapped, helperRecovered: false)
    }
}
```

`BoundedAwait.value` races the supplied task against `Task.sleep(for:)`, cancels the losing waiter, and returns `nil` on deadline; it never cancels the underlying job. `HelperClient.waitUntilActive` sends signed `.ping` requests until the response contains `activeJobCount == 1`, sleeping 25 ms between attempts and stopping at the supplied deadline. Because `cancel(targetJobID:)` obtains its own ID from `makeMessageID`, both explicit-cancellation and timeout paths use a cancellation ID distinct from the hold job ID and from each other.

`PublicKeyExporter.init` rejects every descriptor except `3`; `export()` requires exactly 32 bytes and invokes one `writeAll` to descriptor 3. Neither `MainMode.parse` nor `HelperMode.parse` accepts `--fd`, `1`, or `2`. Peer import reads exactly 32 stdin bytes. Helper runtime import reads strict bounded Codex/root config. Ready mode loads/signs/verifies local state and prints only `bootstrap_status=ready|failed`.

Use this exact target assembly in the three entry points (the mode switches call only the shown dependencies):

```swift
// helper-ipc-probe-main/main.swift, `case let .run(scenario)`
let owner = OwnedIdentityStore(service: "com.example.dailyplanner.helper-ipc-probe.main", privateKeyAccount: "ipc-signing-key-v1", peerPublicKeyAccount: "helper-public-key-v1", backend: SystemKeychainBackend())
let client = HelperClient(
    discovery: NetworkHelperDiscovery(serviceType: "_dailyplanner-helper._tcp", queue: DispatchQueue(label: "helper.discovery")),
    connector: NetworkHelperConnector(queue: DispatchQueue(label: "helper.connection")),
    identities: ClientIdentities(mainPrivateKey: try owner.loadOrCreatePrivateKey(), helperPublicKey: try owner.peerPublicKey()),
    expectedInstance: InstanceIdentity.pinned(mainPublicKey: try owner.exportPublicKey())
)
let result = await MainScenarioRunner(client: client).run(scenario)
print(String(decoding: try StrictJSON.encode(result), as: UTF8.self))

// helper-ipc-probe-helper/main.swift, no-argument .serve case
let owner = OwnedIdentityStore(service: "com.example.dailyplanner.helper-ipc-probe.helper", privateKeyAccount: "ipc-signing-key-v1", peerPublicKeyAccount: "main-public-key-v1", backend: SystemKeychainBackend())
let runtime = try HelperRuntimeStore(service: "com.example.dailyplanner.helper-ipc-probe.helper", account: "runtime-config-v1", backend: SystemKeychainBackend()).load()
let worker = CodexWorkerSession(workerExecutableURL: Bundle.main.bundleURL.appending(path: "Contents/MacOS/helper-ipc-codex-worker"), codexExecutableURL: URL(filePath: runtime.codexExecutablePath), callerRoot: URL(filePath: runtime.callerRootPath))
let executor = ProbeExecutor(codex: worker, crashNow: { Darwin.kill(Darwin.getpid(), SIGKILL); fatalError() })
let transport = NetworkServerTransport(identities: ServerIdentities(helperPrivateKey: try owner.loadOrCreatePrivateKey(), mainPublicKey: try owner.peerPublicKey()), queue: DispatchQueue(label: "helper.listener"))
let server = HelperServer(transport: transport, executor: executor, registry: JobRegistry())
try await server.start(parameters: ServerParameters(acceptLocalOnly: true, serviceType: "_dailyplanner-helper._tcp", txtProtocol: 1, instanceID: InstanceIdentity.pinned(mainPublicKey: try owner.peerPublicKey().rawRepresentation)))
await ServiceRunLoop.waitUntilCancelled()

// helper-ipc-probe-installer/main.swift
let service = SMAppService.loginItem(identifier: "com.example.dailyplanner.helper-ipc-probe.helper")
let status = try InstallerController(service: service).perform(try InstallerMode.parse(Array(CommandLine.arguments.dropFirst())))
print("registration_status=\(status.rawValue)")
```

- [ ] **Step 3: Implement exact bootstrap order**

Implement `bootstrap-installed-products.sh` with this finite body after the shebang and `set -euo pipefail`:

```bash
umask 077
[[ "$#" -eq 8 ]] || exit 64
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --root) root="$2";; --main) main="$2";; --helper) helper="$2";; --codex) codex="$2";; *) exit 64;;
  esac
  shift 2
done
root="$(cd "$root" && pwd -P)"
base="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
[[ "$(dirname "$root")" == "$base" && "$(basename "$root")" == daily-planner-helper-ipc.* ]] || exit 65
for executable in "$main" "$helper" "$codex"; do [[ -x "$executable" ]] || exit 66; /usr/bin/codesign --verify --strict "$executable"; done
main_public="$root/main.public"; helper_public="$root/helper.public"; runtime_json="$root/runtime.json"
( exec 3>"$main_public"; "$main" --bootstrap-export-public-key 3>&3 )
( exec 3>"$helper_public"; "$helper" --bootstrap-export-public-key 3>&3 )
[[ "$(/usr/bin/stat -f %z "$main_public")" == 32 && "$(/usr/bin/stat -f %z "$helper_public")" == 32 ]] || exit 67
"$main" --bootstrap-import-peer-key <"$helper_public"
"$helper" --bootstrap-import-peer-key <"$main_public"
/usr/bin/plutil -create json "$runtime_json"
/usr/bin/plutil -replace codexExecutablePath -string "$codex" "$runtime_json"
/usr/bin/plutil -replace callerRootPath -string "$root" "$runtime_json"
"$helper" --bootstrap-runtime <"$runtime_json"
[[ "$("$main" --bootstrap-ready)" == bootstrap_status=ready ]] || exit 68
[[ "$("$helper" --bootstrap-ready)" == bootstrap_status=ready ]] || exit 68
/bin/rm -f "$main_public" "$helper_public" "$runtime_json"
```

This script never invokes `security`; only each installed owner’s export mode calls its own `loadOrCreatePrivateKey()`.

- [ ] **Step 4: Run GREEN and commit**

```bash
git add Spikes/HelperIPCProbe/Package.swift Spikes/HelperIPCProbe/Sources/HelperIPCExecutableCore Spikes/HelperIPCProbe/Sources/helper-ipc-probe-main Spikes/HelperIPCProbe/Sources/helper-ipc-probe-installer Spikes/HelperIPCProbe/Sources/helper-ipc-probe-helper Spikes/HelperIPCProbe/Tests/HelperIPCExecutableCoreTests Spikes/HelperIPCProbe/Scripts/bootstrap-installed-products.sh
git commit -m "spike: add owner bootstrap modes"
```

---

### Task 7: Signed products, separate installation, registration, and cleanup

**Files:**
- Create: `Spikes/HelperIPCProbe/Resources/MainInfo.plist`
- Create: `Spikes/HelperIPCProbe/Resources/MainSandbox.entitlements`
- Create: `Spikes/HelperIPCProbe/Resources/InstallerInfo.plist`
- Create: `Spikes/HelperIPCProbe/Resources/HelperInfo.plist`
- Create: `Spikes/HelperIPCProbe/Resources/Empty.entitlements`
- Create: `Spikes/HelperIPCProbe/Scripts/build-signed-products.sh`
- Create: `Spikes/HelperIPCProbe/Scripts/cleanup-probe-state.sh`
- Create: `Spikes/HelperIPCProbe/Tests/Integration/run-signed-contract.sh`

**Interfaces:**
- Consumes: explicit caller root/product paths and Task 6 modes.
- Produces: four signed code items/products plus finite `RegistrationStatus`.

- [ ] **Step 1: Write RED black-box contract**

Create `run-signed-contract.sh` with the following body after `#!/bin/zsh` and `set -euo pipefail`:

```bash
umask 077
[[ "$#" -eq 10 ]] || exit 64
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --root) root="$2";; --main) main="$2";; --installer) installer="$2";; --helper) helper="$2";; --worker) worker="$2";; *) exit 64;;
  esac
  shift 2
done
root="$(cd "$root" && pwd -P)"; base="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
[[ "$(dirname "$root")" == "$base" && "$(basename "$root")" == daily-planner-helper-ipc.* ]] || exit 65
[[ "$helper" == "$installer/Contents/Library/LoginItems/DailyPlannerHelperIPCService.app" ]] || exit 66
[[ "$worker" == "$helper/Contents/MacOS/helper-ipc-codex-worker" ]] || exit 66
[[ "$main" != "$installer" && "$main" != "$helper" && "$main" != "$worker" && "$installer" != "$helper" && "$installer" != "$worker" && "$helper" != "$worker" ]] || exit 66
for product in "$main" "$installer" "$helper" "$worker"; do [[ -e "$product" ]] || exit 67; /usr/bin/codesign --verify --strict "$product"; done
identifiers="$root/identifiers.txt"; : >"$identifiers"; /bin/chmod 600 "$identifiers"
for product in "$main" "$installer" "$helper" "$worker"; do
  details="$root/codesign.$(/usr/bin/stat -f %i "$product")"
  /usr/bin/codesign -d --verbose=4 "$product" 2>"$details"
  /usr/bin/sed -n 's/^Identifier=//p' "$details" >>"$identifiers"
  /bin/rm -f "$details"
done
[[ "$(/usr/bin/sort -u "$identifiers" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == 4 ]] || exit 68
main_entitlements="$root/main.entitlements.plist"; installer_entitlements="$root/installer.entitlements.plist"; helper_entitlements="$root/helper.entitlements.plist"; worker_entitlements="$root/worker.entitlements.plist"
/usr/bin/codesign -d --entitlements "$main_entitlements" "$main" 2>/dev/null
/usr/bin/codesign -d --entitlements "$installer_entitlements" "$installer" 2>/dev/null
/usr/bin/codesign -d --entitlements "$helper_entitlements" "$helper" 2>/dev/null
/usr/bin/codesign -d --entitlements "$worker_entitlements" "$worker" 2>/dev/null
[[ "$(/usr/bin/grep -c '<key>' "$main_entitlements")" == 3 ]] || exit 69
for key in com.apple.security.app-sandbox com.apple.security.files.user-selected.read-write com.apple.security.network.client; do [[ "$(/usr/bin/plutil -extract "$key" raw "$main_entitlements")" == true ]] || exit 69; done
[[ "$(/usr/bin/grep -c '<key>' "$installer_entitlements" || true)" == 0 ]] || exit 69
[[ "$(/usr/bin/grep -c '<key>' "$helper_entitlements" || true)" == 0 ]] || exit 69
[[ "$(/usr/bin/grep -c '<key>' "$worker_entitlements" || true)" == 0 ]] || exit 69
[[ ! -e "$main/Contents/Library/LoginItems/DailyPlannerHelperIPCService.app" ]] || exit 70
[[ "$(/usr/bin/find "$main" "$installer" -type f \( -name '*.public' -o -name 'runtime.json' -o -name '*private-key*' \) -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == 0 ]] || exit 71
/bin/rm -f "$identifiers" "$main_entitlements" "$installer_entitlements" "$helper_entitlements" "$worker_entitlements"
print 'signed_contract=PASS'
```

Before products exist, invoke the script with the exact paths below and confirm RED exit 67 because the first product is absent; no manifest target is missing.

- [ ] **Step 2: Build/sign/install with explicit ownership**

`build-signed-products.sh --root ROOT --products PRODUCTS` never creates/infer roots. Assemble helper under installer and main separately; sign worker→helper→installer→main without `--deep`; verify with strict/deep verification. Use explicit `DAILY_PLANNER_HELPER_SIGN_IDENTITY` or diagnostic `-`. Install main/installer as sibling paths beneath root with `ditto`, then reverify installed copies before Task 6 bootstrap.

- [ ] **Step 3: Register and clean exactly**

Installer maps `SMAppService.loginItem(identifier:)` status to `RegistrationStatus` without localized text. User approval becomes `requiresApproval`. Do not open settings automatically.

`cleanup-probe-state.sh` requires root plus all four exact product paths; validates canonical root parent equals canonical `${TMPDIR:-/tmp}` and prefix; unregisters, invokes owner delete modes, and invokes helper `--cleanup-owned-processes TOKEN` for each private receipt token. That mode uses `OwnershipCleanupPlanner` and the exact worker/Codex executable identities, revalidates identity before each signal, removes receipts, verifies five exact Keychain items absent, removes root, and is idempotent under repeated signal traps.

- [ ] **Step 4: Run GREEN and commit**

Run the signed contract immediately after building:

```bash
contract_root="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-helper-ipc.XXXXXX")"
products="$contract_root/products"
main="$products/DailyPlannerHelperIPCMain.app"
installer="$products/DailyPlannerHelperIPCInstaller.app"
helper="$installer/Contents/Library/LoginItems/DailyPlannerHelperIPCService.app"
worker="$helper/Contents/MacOS/helper-ipc-codex-worker"
trap 'zsh Spikes/HelperIPCProbe/Scripts/cleanup-probe-state.sh --root "$contract_root" --main "$main" --installer "$installer" --helper "$helper" --worker "$worker"' EXIT INT TERM HUP
zsh Spikes/HelperIPCProbe/Scripts/build-signed-products.sh --root "$contract_root" --products "$products"
zsh Spikes/HelperIPCProbe/Tests/Integration/run-signed-contract.sh --root "$contract_root" --main "$main" --installer "$installer" --helper "$helper" --worker "$worker"
```

Expected: build exits 0, the contract prints only `signed_contract=PASS`, all four signed code items/products and exact entitlements verify, and the trap removes the private root. Registration/no-argument launch remains Task 8’s live check. Ad-hoc signing rejection remains a finite failure, not a pass.

```bash
git add Spikes/HelperIPCProbe/Resources Spikes/HelperIPCProbe/Scripts/build-signed-products.sh Spikes/HelperIPCProbe/Scripts/cleanup-probe-state.sh Spikes/HelperIPCProbe/Tests/Integration/run-signed-contract.sh
git commit -m "spike: assemble signed helper products"
```

---

### Task 8: Signed end-to-end success, cancellation, timeout, crash, and cleanup evidence

**Files:**
- Modify: `Spikes/HelperIPCProbe/Sources/HelperIPCProtocol/WireContract.swift` (Task 1 finite-model declarations, after `ProbeResponse`)
- Modify: `Spikes/HelperIPCProbe/Tests/HelperIPCProtocolTests/WireContractTests.swift` (Task 1 test file, append evidence-validation tests)
- Create: `Spikes/HelperIPCProbe/Scripts/run-signed-e2e.sh`
- Create after execution: `docs/architecture/evidence/helper-ipc.json`

**Interfaces:**
- Consumes: Tasks 1–7 plus the validated installed `codex`.
- Produces: one strict `HelperIPCEvidence.v1` document and no other retained artifact.

- [ ] **Step 1: Write an evidence-schema test that fails before the runner exists**

Add these complete fixtures and validation tests to `WireContractTests.swift`:

```swift
private func requiredScenario(_ name: ScenarioName) -> ScenarioEvidence {
    switch name {
    case .ping:
        ScenarioEvidence(name: name, status: .succeeded, codex: nil, activeJobCountAfter: 0, workerStopped: true, codexStopped: true, helperRecovered: true, helperCleanup: .succeeded, runnerCleanup: .notObserved, cleanupProvenance: .helper)
    case .syntheticCodex:
        ScenarioEvidence(name: name, status: .succeeded, codex: CodexOutcome(threadStarted: true, turnCompleted: true, structuredOutputAccepted: true), activeJobCountAfter: 0, workerStopped: true, codexStopped: true, helperRecovered: true, helperCleanup: .succeeded, runnerCleanup: .notObserved, cleanupProvenance: .helper)
    case .explicitCancellation:
        ScenarioEvidence(name: name, status: .cancelled, codex: nil, activeJobCountAfter: 0, workerStopped: true, codexStopped: true, helperRecovered: true, helperCleanup: .succeeded, runnerCleanup: .notObserved, cleanupProvenance: .helper)
    case .timeout:
        ScenarioEvidence(name: name, status: .timedOut, codex: nil, activeJobCountAfter: 0, workerStopped: true, codexStopped: true, helperRecovered: true, helperCleanup: .succeeded, runnerCleanup: .notObserved, cleanupProvenance: .helper)
    case .helperCrash:
        ScenarioEvidence(name: name, status: .helperCrashed, codex: CodexOutcome(threadStarted: true, turnCompleted: false, structuredOutputAccepted: false), activeJobCountAfter: 0, workerStopped: true, codexStopped: true, helperRecovered: true, helperCleanup: .notObserved, runnerCleanup: .succeeded, cleanupProvenance: .runner)
    }
}

private func passingEvidence(scenarios: [ScenarioEvidence] = ScenarioName.allCases.map(requiredScenario)) -> HelperIPCEvidence {
    HelperIPCEvidence(
        schemaVersion: 1, recordedAt: "2026-08-30", syntheticInputOnly: true,
        signing: SignatureEvidence(signingClass: .adHoc, mainValid: true, installerValid: true, helperValid: true, workerValid: true, mainEntitlementCeilingExact: true),
        installation: InstallationEvidence(separateProducts: true, helperAbsentFromMainBundle: true, registrationStatus: .enabled, unregistered: true),
        transport: TransportEvidence(loopbackOnly: true, bonjourDiscovered: true, protocolVersion: 1, mainAuthenticatedHelper: true, helperAuthenticatedMain: true),
        scenarios: scenarios, cleanup: CleanupEvidence(keychainItemsRemaining: 0, registeredServicesRemaining: 0, ownedProcessesRemaining: 0, privateRootsRemaining: 0),
        gateStatus: .pass
    )
}

@Test func passRequiresExactCompleteScenarioSetAndObservations() throws {
    let evidence = passingEvidence()
    let data = try StrictJSON.encode(evidence)
    #expect(try HelperIPCEvidence.decodeStrict(data) == evidence)
    #expect(throws: EvidenceError.invalidPass) { try passingEvidence(scenarios: []).validated() }
    for missing in ScenarioName.allCases {
        #expect(throws: EvidenceError.invalidPass) { try passingEvidence(scenarios: ScenarioName.allCases.filter { $0 != missing }.map(requiredScenario)).validated() }
    }
    var duplicate = ScenarioName.allCases.map(requiredScenario); duplicate.append(requiredScenario(.ping))
    #expect(throws: EvidenceError.invalidPass) { try passingEvidence(scenarios: duplicate).validated() }
    var wrong = ScenarioName.allCases.map(requiredScenario)
    wrong[1] = ScenarioEvidence(name: .syntheticCodex, status: .succeeded, codex: CodexOutcome(threadStarted: true, turnCompleted: false, structuredOutputAccepted: true), activeJobCountAfter: 0, workerStopped: true, codexStopped: true, helperRecovered: true, helperCleanup: .succeeded, runnerCleanup: .notObserved, cleanupProvenance: .helper)
    #expect(throws: EvidenceError.invalidPass) { try passingEvidence(scenarios: wrong).validated() }
}

@Test func failAndBlockedHaveFiniteDistinctValidationRules() throws {
    let failed = HelperIPCEvidence(schemaVersion: 1, recordedAt: "2026-08-30", syntheticInputOnly: true, signing: SignatureEvidence(signingClass: .adHoc, mainValid: true, installerValid: true, helperValid: true, workerValid: true, mainEntitlementCeilingExact: true), installation: InstallationEvidence(separateProducts: true, helperAbsentFromMainBundle: true, registrationStatus: .failed, unregistered: true), transport: TransportEvidence(loopbackOnly: false, bonjourDiscovered: false, protocolVersion: 1, mainAuthenticatedHelper: false, helperAuthenticatedMain: false), scenarios: [], cleanup: CleanupEvidence(keychainItemsRemaining: 0, registeredServicesRemaining: 0, ownedProcessesRemaining: 0, privateRootsRemaining: 0), gateStatus: .fail)
    #expect(try failed.validated() == failed)
    let blocked = HelperIPCEvidence(schemaVersion: 1, recordedAt: "2026-08-30", syntheticInputOnly: true, signing: failed.signing, installation: InstallationEvidence(separateProducts: true, helperAbsentFromMainBundle: true, registrationStatus: .requiresApproval, unregistered: true), transport: failed.transport, scenarios: [], cleanup: failed.cleanup, gateStatus: .blockedByUserAction)
    #expect(try blocked.validated() == blocked)
    #expect(throws: EvidenceError.invalidBlocked) { try HelperIPCEvidence(schemaVersion: 1, recordedAt: blocked.recordedAt, syntheticInputOnly: true, signing: blocked.signing, installation: blocked.installation, transport: blocked.transport, scenarios: [requiredScenario(.ping)], cleanup: blocked.cleanup, gateStatus: .blockedByUserAction).validated() }
}
```

Define the exact-key helper in the same file:

```swift
private func collectJSONKeys(_ data: Data) throws -> Set<String> {
    func walk(_ value: Any, into keys: inout Set<String>) {
        if let object = value as? [String: Any] {
            for (key, child) in object { keys.insert(key); walk(child, into: &keys) }
        } else if let array = value as? [Any] {
            for child in array { walk(child, into: &keys) }
        }
    }
    var keys = Set<String>()
    walk(try JSONSerialization.jsonObject(with: data), into: &keys)
    return keys
}
```

Add this exact-key/value test; it does not reject the legitimate `messageID` or `signing` keys:

```swift
@Test func evidenceRejectsSecretBearingExactKeysAndPrivatePathValues() throws {
    let data = try StrictJSON.encode(passingEvidence())
    let base = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for key in ["privateKey", "publicKey", "signature", "nonce", "stderr", "path", "pid", "prompt", "transcript"] {
        var object = base; object[key] = "synthetic"
        #expect(throws: ContractError.invalidEnvelope) { try HelperIPCEvidence.decodeStrict(JSONSerialization.data(withJSONObject: object)) }
    }
    var privateValue = base; privateValue["recordedAt"] = "/private/synthetic"
    #expect(throws: EvidenceError.invalidDate) { try HelperIPCEvidence.decodeStrict(JSONSerialization.data(withJSONObject: privateValue)) }
    let keys = try collectJSONKeys(data)
    #expect(keys.contains("signing"))
}
```

The evidence model is:

```swift
public struct HelperIPCEvidence: Codable, Sendable, Equatable {
    public let schemaVersion: UInt16              // 1
    public let recordedAt: String                 // YYYY-MM-DD only
    public let syntheticInputOnly: Bool
    public let signing: SignatureEvidence
    public let installation: InstallationEvidence
    public let transport: TransportEvidence       // loopback, Bonjour, protocol=1, mutual auth booleans
    public let scenarios: [ScenarioEvidence]      // exact five names once each for PASS
    public let cleanup: CleanupEvidence           // zero counters/booleans
    public let gateStatus: GateStatus             // PASS|FAIL|BLOCKED_BY_USER_ACTION
    public init(schemaVersion: UInt16, recordedAt: String, syntheticInputOnly: Bool, signing: SignatureEvidence, installation: InstallationEvidence, transport: TransportEvidence, scenarios: [ScenarioEvidence], cleanup: CleanupEvidence, gateStatus: GateStatus)
    public static func decodeStrict(_ data: Data) throws -> Self
    public func validated() throws -> Self
}

public enum EvidenceError: Error, Sendable, Equatable { case invalidDate; case invalidPass; case invalidFail; case invalidBlocked }
public enum GateStatus: String, Codable, Sendable, Equatable { case pass = "PASS"; case fail = "FAIL"; case blockedByUserAction = "BLOCKED_BY_USER_ACTION" }
public enum SigningClass: String, Codable, Sendable, Equatable { case adHoc; case development; case developerID }
public enum CleanupProvenance: String, Codable, Sendable, Equatable { case helper; case runner; case notObserved }

public struct SignatureEvidence: Codable, Sendable, Equatable {
    public let signingClass: SigningClass
    public let mainValid: Bool
    public let installerValid: Bool
    public let helperValid: Bool
    public let workerValid: Bool
    public let mainEntitlementCeilingExact: Bool
    public init(signingClass: SigningClass, mainValid: Bool, installerValid: Bool, helperValid: Bool, workerValid: Bool, mainEntitlementCeilingExact: Bool)
}

public struct InstallationEvidence: Codable, Sendable, Equatable {
    public let separateProducts: Bool
    public let helperAbsentFromMainBundle: Bool
    public let registrationStatus: RegistrationStatus
    public let unregistered: Bool
    public init(separateProducts: Bool, helperAbsentFromMainBundle: Bool, registrationStatus: RegistrationStatus, unregistered: Bool)
}

public struct TransportEvidence: Codable, Sendable, Equatable {
    public let loopbackOnly: Bool
    public let bonjourDiscovered: Bool
    public let protocolVersion: UInt16
    public let mainAuthenticatedHelper: Bool
    public let helperAuthenticatedMain: Bool
    public init(loopbackOnly: Bool, bonjourDiscovered: Bool, protocolVersion: UInt16, mainAuthenticatedHelper: Bool, helperAuthenticatedMain: Bool)
}

public struct ScenarioEvidence: Codable, Sendable, Equatable {
    public let name: ScenarioName
    public let status: ProbeStatus
    public let codex: CodexOutcome?
    public let activeJobCountAfter: UInt16
    public let workerStopped: Bool
    public let codexStopped: Bool
    public let helperRecovered: Bool
    public let helperCleanup: CleanupState
    public let runnerCleanup: CleanupState
    public let cleanupProvenance: CleanupProvenance
    public init(name: ScenarioName, status: ProbeStatus, codex: CodexOutcome?, activeJobCountAfter: UInt16, workerStopped: Bool, codexStopped: Bool, helperRecovered: Bool, helperCleanup: CleanupState, runnerCleanup: CleanupState, cleanupProvenance: CleanupProvenance)
}

public struct CleanupEvidence: Codable, Sendable, Equatable {
    public let keychainItemsRemaining: UInt16
    public let registeredServicesRemaining: UInt16
    public let ownedProcessesRemaining: UInt16
    public let privateRootsRemaining: UInt16
    public init(keychainItemsRemaining: UInt16, registeredServicesRemaining: UInt16, ownedProcessesRemaining: UInt16, privateRootsRemaining: UInt16)
}
```

`decodeStrict` rejects non-exact keys, decodes, then calls `validated()`. Date syntax is exactly four ASCII digits, `-`, two digits, `-`, two digits. `PASS` requires all signing booleans, separation/absence/enabled/unregistered, all transport booleans with protocol 1, zero cleanup counters, and the exact five unique scenario records produced by `requiredScenario`. `FAIL` requires registration not `.requiresApproval`, a unique subset of known scenarios, and at least one failed PASS invariant. `BLOCKED_BY_USER_ACTION` requires `.requiresApproval`, no scenarios, no IPC observations, successful unregister/zero cleanup, and otherwise-valid signing/separation observations.

- [ ] **Step 2: Run the evidence test and confirm red**

Run the Task 1 focused test command.

Expected: compile failure because `HelperIPCEvidence` is not defined.

- [ ] **Step 3: Implement the strict evidence model and signed runner**

`run-signed-e2e.sh` creates the only root under `${TMPDIR:-/tmp}`, passes it/exact product paths everywhere, and executes:

1. Verify the tracked no-private-path scan is clean before building.
2. Resolve `codex` with `command -v`, require executable, require `codex --version` to match `^codex-cli [0-9]+(\.[0-9]+)+$`, and run `codesign --verify --strict` on the resolved code. Store the path only in a mode-0600 pipe/file under the private root.
3. Run `build-signed-products.sh --root "$helper_root" --products "$products"`, then invoke `run-signed-contract.sh` with the exact root/main/installer/helper/worker paths. Require its sole line `signed_contract=PASS` before installing main/installer as siblings with `ditto` and re-verifying.
4. Run Task 6 bootstrap on installed owners; root receives public keys only and deletes them after both ready checks.
5. Run installer `--register`; poll finite `--status` for at most 5 seconds. If approval is required, emit `gateStatus=BLOCKED_BY_USER_ACTION`, run full cleanup, and stop without running IPC.
6. Run main `ping`; require discovery, loopback, protocol-v1 selection, mutual signatures, and `status=succeeded`.
7. Run main `syntheticCodex`; require one synthetic structured App Server turn, thread archive acknowledgement, `structuredOutputAccepted=true`, no active jobs, and worker cleanup.
8. Run main `explicitCancellation`; start hold, send signed cancel with fresh ID and target, observe cancel ack and original job cancellation.
9. Run main `timeout`; require a different fresh cancel ID/target, `timedOut`, zero jobs/worker/child.
10. Run main `helperCrash`; helper dies only after `.started`. Main records `helperCrashed` and `helperCleanup=.notObserved`; it never claims cleanup. Runner independently validates the private ownership receipt, exact owned processes absent, receipt removal, helper relaunch, rediscovery/authentication, and records `runnerCleanup=.succeeded`, provenance `.runner`.
11. Unregister; delete all five Keychain items; verify no owned process; cleanup exact root.
12. Create strict evidence. A technical failure stays `FAIL`.

No command may tee raw helper/worker/Codex stderr. Redirect it to a mode-0600 file, use only exit status for classification, and delete it before producing evidence.

- [ ] **Step 4: Run offline tests before the signed live probe**

```bash
helper_scratch="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-helper-all.XXXXXX")"
swift test --package-path Spikes/HelperIPCProbe --scratch-path "$helper_scratch" --no-parallel
rm -rf "$helper_scratch"
```

Expected: all helper tests pass with only synthetic fixtures and no registered helper.

- [ ] **Step 5: Run the signed live proof serially**

Run:

```bash
zsh Spikes/HelperIPCProbe/Scripts/run-signed-e2e.sh
```

Expected for a technical pass: one finite line `helper_ipc_gate=PASS`; evidence records strict signing, separate installation, enabled registration, loopback/mutual authentication, protocol 1, synthetic Codex, direct cancellation, timeout cancellation, runner-proven crash cleanup, and zero cleanup counters. Approval yields `BLOCKED_BY_USER_ACTION`; other failures yield `FAIL`.

- [ ] **Step 6: Inspect the evidence and hygiene before committing**

```bash
plutil -lint docs/architecture/evidence/helper-ipc.json
! rg -n '/Users/|/private/|/Volumes/|Bearer |sk-[A-Za-z0-9_-]+' docs/architecture/evidence/helper-ipc.json
! rg -n 'iCloud~md~obsidian|Mobile Documents|Daily Planner — Brief' Spikes/HelperIPCProbe docs/architecture/evidence/helper-ipc.json
git diff --check
```

Expected: JSON is valid, both scans return no matches, and `git diff --check` exits 0.

- [ ] **Step 7: Commit only observed evidence**

```bash
git add Spikes/HelperIPCProbe/Sources/HelperIPCProtocol/WireContract.swift Spikes/HelperIPCProbe/Tests/HelperIPCProtocolTests/WireContractTests.swift Spikes/HelperIPCProbe/Scripts/run-signed-e2e.sh docs/architecture/evidence/helper-ipc.json
git commit -m "spike: record signed helper IPC evidence"
```

---

### Task 9: Conditional handoff update and complete serial verification

**Files:**
- Modify: `docs/architecture/M0.5-Feasibility-Handoff.md:1-178`
- Modify: `docs/architecture/evidence/security-boundary.json:1-97`
- Modify: `README.md:1-68`

**Interfaces:**
- Consumes: the committed `HelperIPCEvidence.v1` observation from Task 8 and all prior evidence unchanged.
- Produces: an evidence-linked helper gate and reproducible verification instructions; it does not authorize M1 while any other required gate remains blocked.

- [ ] **Step 1: Update the helper gate strictly from observed evidence**

First load the complete file bytes with `HelperIPCEvidence.decodeStrict`; stop without editing any documentation if strict decoding or cross-field validation fails. Only after that succeeds: if `gateStatus == PASS`, change only the helper row to `PASS` and summarize the finite observed properties; if it is `FAIL`, keep `FAIL` and name the failed finite property without assigning an unproven cause; if it is `BLOCKED_BY_USER_ACTION`, use that exact status and state the precise System Settings approval action.

In all cases:

- Link `docs/architecture/evidence/helper-ipc.json` and `zsh Spikes/HelperIPCProbe/Scripts/run-signed-e2e.sh`.
- Preserve the existing Google, interactive bookmark, and lock-state statuses.
- Keep the production scaffold unauthorized unless every required gate has separately passed and the distribution ruling has been reviewed.
- Describe the proven boundary narrowly: separate installer host, separately signed registered helper, sandboxed main, loopback Bonjour/Network.framework, mutual Ed25519 authentication, version 1, and synthetic Codex only.
- State that Developer ID/notarization, upgrade/migration, production pairing recovery, locked execution, and App Store acceptance remain outside this proof.

- [ ] **Step 2: Update security evidence and README without rewriting history**

Increment `security-boundary.json.schemaVersion` only if its schema changes; otherwise preserve it and add a `helperIPCEvidence` object beneath `distributionRuling` containing only the relative evidence path and gate status. Do not change the recorded sandboxed direct-launch `FAIL`.

Add the helper test and signed runner to README’s serial commands, with the background-item approval caveat. Keep “not a production app” and all safety boundaries.

- [ ] **Step 3: Run the complete repository verification serially**

```bash
zsh Spikes/ToolchainProbe/Scripts/build-and-verify.sh
zsh Spikes/ToolchainProbe/Tests/verify-toolchain.sh --launch-cycle

codex_scratch="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-codex-final.XXXXXX")"
swift test --package-path Spikes/CodexBridgeProbe --scratch-path "$codex_scratch" --no-parallel
rm -rf "$codex_scratch"

google_scratch="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-google-final.XXXXXX")"
swift test --package-path Spikes/GoogleOAuthProbe --scratch-path "$google_scratch" --jobs 1
swift run --package-path Spikes/GoogleOAuthProbe --scratch-path "$google_scratch" --skip-build google-oauth-probe --dry-run
rm -rf "$google_scratch"

security_scratch="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-security-final.XXXXXX")"
swift test --disable-index-store --package-path Spikes/SecurityBoundaryProbe --scratch-path "$security_scratch"
rm -rf "$security_scratch"
Spikes/SecurityBoundaryProbe/Scripts/build-variants.sh

helper_scratch="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-helper-final.XXXXXX")"
swift test --package-path Spikes/HelperIPCProbe --scratch-path "$helper_scratch" --no-parallel
rm -rf "$helper_scratch"

(
  set -euo pipefail
  contract_root="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-helper-ipc.XXXXXX")"
  products="$contract_root/products"
  main="$products/DailyPlannerHelperIPCMain.app"
  installer="$products/DailyPlannerHelperIPCInstaller.app"
  helper="$installer/Contents/Library/LoginItems/DailyPlannerHelperIPCService.app"
  worker="$helper/Contents/MacOS/helper-ipc-codex-worker"
  trap 'zsh Spikes/HelperIPCProbe/Scripts/cleanup-probe-state.sh --root "$contract_root" --main "$main" --installer "$installer" --helper "$helper" --worker "$worker"' EXIT INT TERM HUP
  zsh Spikes/HelperIPCProbe/Scripts/build-signed-products.sh --root "$contract_root" --products "$products"
  zsh Spikes/HelperIPCProbe/Tests/Integration/run-signed-contract.sh --root "$contract_root" --main "$main" --installer "$installer" --helper "$helper" --worker "$worker"
)
zsh Spikes/HelperIPCProbe/Scripts/run-signed-e2e.sh
```

Expected: all offline suites and signed-contract checks pass; the last command reproduces the exact observed helper gate status. Do not run Google `--live-readonly`, the interactive bookmark runner, or the lock-state helper as part of this task.

- [ ] **Step 4: Run final secret, path, entitlement, and cleanup checks**

```bash
! rg -n 'iCloud~md~obsidian|Mobile Documents|Daily Planner — Brief' Spikes docs/architecture/evidence
! rg -n '/Users/|/private/|/Volumes/|Bearer |sk-[A-Za-z0-9_-]+|refresh_token|authorization_code' docs/architecture/evidence/helper-ipc.json
test "$(git grep -l 'com.apple.security.temporary-exception\|com.apple.security.application-groups\|mach-lookup' -- Spikes/HelperIPCProbe || true)" = ""
! security find-generic-password -s com.example.dailyplanner.helper-ipc-probe.main -a ipc-signing-key-v1 >/dev/null 2>&1
! security find-generic-password -s com.example.dailyplanner.helper-ipc-probe.main -a helper-public-key-v1 >/dev/null 2>&1
! security find-generic-password -s com.example.dailyplanner.helper-ipc-probe.helper -a ipc-signing-key-v1 >/dev/null 2>&1
! security find-generic-password -s com.example.dailyplanner.helper-ipc-probe.helper -a main-public-key-v1 >/dev/null 2>&1
! security find-generic-password -s com.example.dailyplanner.helper-ipc-probe.helper -a runtime-config-v1 >/dev/null 2>&1
base="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
test "$(find "$base" -maxdepth 1 -type d -name 'daily-planner-helper-ipc.*' | wc -l | tr -d ' ')" = 0
git diff --check
```

Expected: every command exits 0; no helper Keychain item or private root remains.

- [ ] **Step 5: Perform the required plan self-review against the binding handoff**

Check and record in the implementation report:

1. Synthetic-only scope is enforced at the request enum, worker prompt, and evidence scan.
2. The main’s exact three entitlements are asserted from its signed product; no entitlement widening exists in tracked files.
3. Main, installer, helper, and worker have distinct code identifiers and valid signatures.
4. Installation/registration is separate from the sandboxed main; the main cannot launch Codex or pass an arbitrary path/prompt.
5. Discovery is loopback-only and authentication is mutual; wrong-key/replay/version failures are tested.
6. Success, direct cancellation, timeout, helper crash, runner-sourced Codex/worker cleanup, helper relaunch, unregister, five-item Keychain deletion, and private-root deletion all have direct observations.
7. Output/evidence types contain no arbitrary diagnostic strings; raw stderr and private paths are discarded before evidence generation.
8. The handoff changes only according to `helper-ipc.json` and does not authorize M1 while Google/bookmark/lock gates remain unresolved.
9. Every manifest revision references only targets whose source files exist; every RED fails for the intended absent type/behavior and every GREEN can compile then.
10. All cross-target models have public initializers/strict decoders and every named test fixture/factory is defined in its task.

- [ ] **Step 6: Commit the evidence-linked handoff**

```bash
git add README.md docs/architecture/M0.5-Feasibility-Handoff.md docs/architecture/evidence/security-boundary.json
git commit -m "docs: update helper IPC feasibility gate"
```

## Implementation Review Gate

Before calling the implementation complete, review the final diff and answer each question with a file/test/evidence reference:

- Can the sandboxed main do anything other than browse loopback, authenticate, and send one finite operation enum?
- Can any IPC field inject a prompt, executable path, shell fragment, arbitrary Codable class, or raw diagnostic string?
- Does the helper authenticate the main before accepting even `ping`, cancellation, or crash-proof operations?
- Does the main authenticate the helper before trusting any status?
- Does helper death close the worker control pipe, cancel App Server, terminate Codex, and remove its cwd without relying on the dead helper?
- Does `SMAppService` status and cleanup remain observable without parsing localized text?
- Are all signing/entitlement claims checked against the copied installed artifacts, not only staging bundles?
- Does every negative scenario leave the helper gate `FAIL` or `BLOCKED_BY_USER_ACTION` rather than upgrading it by inference?
- Are all commands serial, reproducible, exact-targeted, and safe if interrupted twice?

The plan is complete when these tasks and checks are written. The feasibility proof remains unproven until an executor runs the signed end-to-end command and commits the sanitized observed evidence.
