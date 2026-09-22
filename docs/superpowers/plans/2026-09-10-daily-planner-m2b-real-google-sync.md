# Daily Planner M2B Real Google Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the synthetic dashboard with an explicit manual, read-only Google sync that displays the primary calendar's next seven days, incomplete tasks from every list, and the last 30 days of Gmail with safe on-demand message detail.

**Architecture:** Provider-neutral contracts live in `DailyPlannerDomain`; exact GET-only Google clients live in `DailyPlannerGoogle`; pagination, classification, cursor recovery, and all-or-nothing orchestration live in `DailyPlannerApplication`; encrypted atomic storage lives in `DailyPlannerPersistence`; and `DailyPlannerUI` only renders finite workflow state. Standard `DailyPlannerApp` composition injects those real implementations while all tests use synthetic boundary fakes.

**Tech Stack:** Swift 6, macOS 15, SwiftPM, Foundation `URLSession`, CryptoKit AES-GCM, Security Keychain, Swift Concurrency, SwiftUI, XCTest, shell acceptance verifiers.

**Spec:** `docs/superpowers/specs/2026-09-10-daily-planner-m2b-real-google-sync-design.md`

## Global Constraints

- Keep the existing five approved scopes exactly: `openid`, `email`, `https://www.googleapis.com/auth/gmail.readonly`, `https://www.googleapis.com/auth/calendar.readonly`, and `https://www.googleapis.com/auth/tasks.readonly`.
- Provider traffic is GET-only under the exact Gmail, Calendar, and Tasks route families in the spec; retain only the reviewed OAuth token/revoke POST forms.
- No provider read occurs at app launch, view appearance, settings appearance, or on a timer. Only **Sync now**, **Load saved dashboard**, and an explicitly selected email detail may activate their named capability.
- Calendar covers `[startOfToday, startOfToday + 7 local days)`, at most 500 instances and 10 pages, using exactly one provider-declared primary calendar.
- Gmail covers the last 30 days, newest first, at most 200 messages and 10 pages. Sender, subject, and snippet are each capped at 512 Unicode scalars; displayed decoded body is capped at 512 KiB before sanitization.
- Tasks cover at most 50 lists, 100 incomplete tasks per list, 500 incomplete tasks total, and 10 pages per list; incremental polling overlaps the last committed poll time by exactly five minutes.
- Attachment metadata is allowed; attachment bytes are never requested.
- Unknown, ambiguous, unsupported, or decoding-uncertain content classifies as `Private`. Private bodies/descriptions/notes remain memory-only.
- Eligible `Ordinary` records use per-record AES-GCM envelopes, a dedicated 32-byte content key, authenticated metadata, atomic replacement, and 90-day retention.
- A manual sync advances the snapshot and all cursors only after Gmail, Calendar, and Tasks candidates all succeed. Cancellation or any partial failure preserves the previous commit.
- Diagnostics contain finite reason codes, booleans, bounded counts, and coarse timestamps only—never provider content, identities, opaque IDs/cursors, secrets, paths, or raw errors.
- Every production behavior starts with a focused failing test. Every authoritative SwiftPM run uses a newly created `/tmp` scratch path and `--no-parallel`.
- After each task commit, a fresh subagent performs spec review and a second fresh subagent performs code-quality/security review; the task is not accepted until all Important/Critical findings are closed.
- Preserve the user-owned `HANDOFF.md` working-tree edit. Do not stage, rewrite, or revert it.

## File map

| File | Responsibility |
|---|---|
| `DailyPlanner/Sources/DailyPlannerDomain/GoogleDashboardModels.swift` | Bounded provider-neutral records, snapshot, cursors, cap disclosures, and email body values |
| `DailyPlanner/Sources/DailyPlannerDomain/GoogleReadPorts.swift` | Access-token, read-client, cache, classifier, sanitizer, and clock capability contracts |
| `DailyPlanner/Sources/DailyPlannerGoogle/GoogleAccessTokenProvider.swift` | Reusable refresh-token exchange and one in-memory access token per manual operation |
| `DailyPlanner/Sources/DailyPlannerGoogle/GoogleRequestBuilder.swift` | Canonical GET construction with one bearer header and deterministic query encoding |
| `DailyPlanner/Sources/DailyPlannerGoogle/GmailReadClient.swift` | Strict Gmail list/message/history decoding |
| `DailyPlanner/Sources/DailyPlannerGoogle/GoogleCalendarReadClient.swift` | Strict primary-calendar and event decoding |
| `DailyPlanner/Sources/DailyPlannerGoogle/GoogleTasksReadClient.swift` | Strict task-list and task decoding |
| `DailyPlanner/Sources/DailyPlannerApplication/GoogleContentPrivacyClassifier.swift` | Deterministic fail-closed local classification |
| `DailyPlanner/Sources/DailyPlannerApplication/EmailBodySanitizer.swift` | Bounded plain text and inert HTML sanitization |
| `DailyPlanner/Sources/DailyPlannerPersistence/GoogleSnapshotKeychain.swift` | Dedicated content-key acquisition and personal-signing fallback |
| `DailyPlanner/Sources/DailyPlannerPersistence/EncryptedGoogleSnapshotCache.swift` | Authenticated per-record envelopes and atomic committed cache state |
| `DailyPlanner/Sources/DailyPlannerApplication/GmailPartitionSync.swift` | Bounded initial/history pagination and Gmail cursor recovery |
| `DailyPlanner/Sources/DailyPlannerApplication/CalendarPartitionSync.swift` | Primary-only bounded event pagination and 410 recovery |
| `DailyPlanner/Sources/DailyPlannerApplication/TasksPartitionSync.swift` | All-list pagination, overlap, de-duplication, and deletion reconciliation |
| `DailyPlanner/Sources/DailyPlannerApplication/GoogleDashboardSyncWorkflow.swift` | Exclusive manual operation, concurrent candidates, atomic commit, stale/error states, and detail loading |
| `DailyPlanner/Sources/DailyPlannerUI/GoogleDashboardColumns.swift` | Schedule, task, and email list presentation |
| `DailyPlanner/Sources/DailyPlannerUI/EmailDetailView.swift` | Selected safe body and attachment-metadata presentation |
| `DailyPlanner/Tests/verify-m2b.sh` | Offline read-only, privacy, build, signature, launch, and process-lifecycle verifier |

---

### Task 1: Domain records, limits, cursors, and capability ports

**Files:**
- Create: `DailyPlanner/Sources/DailyPlannerDomain/GoogleDashboardModels.swift`
- Create: `DailyPlanner/Sources/DailyPlannerDomain/GoogleReadPorts.swift`
- Create: `DailyPlanner/Tests/DailyPlannerDomainTests/GoogleDashboardModelsTests.swift`

**Interfaces:**
- Consumes: `GoogleIdentityBinding`, `CalendarID`, and `PlannerClock` from `DailyPlannerDomain`.
- Produces: `GoogleAccessToken`, `GmailMessageID`, `GmailThreadID`, `GmailHistoryID`, `GmailPageToken`, `CalendarSyncToken`, `CalendarPageToken`, `GoogleTaskListID`, `GoogleTaskID`, `GoogleTasksPageToken`, `GoogleCalendarEventID`, `GmailMessageReference`, `GmailMessageSummary`, `GmailMessageRecord`, `GmailMessagePage`, `GmailHistoryPage`, `EmailAttachmentMetadata`, `GoogleCalendarRecord`, `GoogleEventTime`, `GoogleEventStatus`, `CalendarEventRecord`, `CalendarEventPage`, `GoogleTaskList`, `GoogleTaskRecord`, `GoogleTaskListPage`, `GoogleTasksPage`, `GoogleResultCaps`, `GoogleDashboardSnapshot`, `GoogleSyncCursors`, `GoogleCommittedCacheState`, `GoogleSyncLimits`, `SourcePrivacyClass`, `GoogleContentClassificationInput`, `SanitizedEmailBody`, and the six capability protocols below.

- [ ] **Step 1: Write failing value-bound and public-consumer tests**

```swift
func testM2BLimitsAreExact() {
    XCTAssertEqual(GoogleSyncLimits.gmailDays, 30)
    XCTAssertEqual(GoogleSyncLimits.gmailMessages, 200)
    XCTAssertEqual(GoogleSyncLimits.gmailPages, 10)
    XCTAssertEqual(GoogleSyncLimits.calendarDays, 7)
    XCTAssertEqual(GoogleSyncLimits.calendarEvents, 500)
    XCTAssertEqual(GoogleSyncLimits.calendarPages, 10)
    XCTAssertEqual(GoogleSyncLimits.taskLists, 50)
    XCTAssertEqual(GoogleSyncLimits.tasksPerList, 100)
    XCTAssertEqual(GoogleSyncLimits.tasksTotal, 500)
    XCTAssertEqual(GoogleSyncLimits.taskPagesPerList, 10)
    XCTAssertEqual(GoogleSyncLimits.taskOverlap, 300)
    XCTAssertEqual(GoogleSyncLimits.displayScalars, 512)
    XCTAssertEqual(GoogleSyncLimits.decodedBodyBytes, 512 * 1_024)
}

func testAccessTokenNeverReflectsItsSecret() throws {
    let token = try GoogleAccessToken(validating: "synthetic-secret-token")
    XCTAssertEqual(String(describing: token), "GoogleAccessToken(redacted)")
    XCTAssertFalse(String(reflecting: token).contains("synthetic-secret-token"))
}
```

Also compile a normal-import consumer that constructs every public record and fake protocol implementation; this prevents synthesized internal initializers from crossing package boundaries.

- [ ] **Step 2: Run RED with an isolated scratch database**

```zsh
scratch=$(mktemp -d /tmp/daily-planner-m2b-task1-red.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$scratch" \
  --filter GoogleDashboardModelsTests --no-parallel
```

Expected: FAIL because `GoogleSyncLimits`, records, and ports do not exist.

- [ ] **Step 3: Add the domain contracts with explicit public initializers**

```swift
public enum GoogleSyncLimits {
    public static let gmailDays = 30
    public static let gmailMessages = 200
    public static let gmailPages = 10
    public static let calendarDays = 7
    public static let calendarEvents = 500
    public static let calendarPages = 10
    public static let taskLists = 50
    public static let tasksPerList = 100
    public static let tasksTotal = 500
    public static let taskPagesPerList = 10
    public static let taskOverlap: TimeInterval = 5 * 60
    public static let displayScalars = 512
    public static let decodedBodyBytes = 512 * 1_024
    public static let retention: TimeInterval = 90 * 24 * 60 * 60
}

public enum SourcePrivacyClass: String, Codable, Equatable, Sendable {
    case ordinary, `private`
}

public enum EmailBodyKind: String, Codable, Equatable, Sendable {
    case plainText, html, unsupported
}

public struct SanitizedEmailBody: Equatable, Sendable {
    public let kind: EmailBodyKind
    public let value: String
    public init(kind: EmailBodyKind, value: String) {
        self.kind = kind
        self.value = value
    }
}

public enum GoogleContentClassificationInput: Equatable, Sendable {
    case email(subject: String, sender: String, body: String?, bodyKind: EmailBodyKind)
    case event(title: String, description: String?, location: String?)
    case task(title: String, notes: String?)
    case unknown
}

public struct GoogleSyncCursors: Codable, Equatable, Sendable {
    public let gmailHistoryID: GmailHistoryID?
    public let calendarSyncToken: CalendarSyncToken?
    public let taskPollTime: Date?
    public init(
        gmailHistoryID: GmailHistoryID? = nil,
        calendarSyncToken: CalendarSyncToken? = nil,
        taskPollTime: Date? = nil
    ) {
        self.gmailHistoryID = gmailHistoryID
        self.calendarSyncToken = calendarSyncToken
        self.taskPollTime = taskPollTime
    }
}

public struct GoogleCommittedCacheState: Codable, Equatable, Sendable {
    public let snapshot: GoogleDashboardSnapshot
    public let cursors: GoogleSyncCursors
    public init(snapshot: GoogleDashboardSnapshot, cursors: GoogleSyncCursors) {
        self.snapshot = snapshot
        self.cursors = cursors
    }
}
```

Define each opaque ID as a `Codable`, `Hashable`, `Sendable` struct with a nonempty, control-character-free public validating initializer and no descriptive exposure of its raw value. Define record fields exactly as follows:

```swift
public struct GmailMessageSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: GmailMessageID
    public let threadID: GmailThreadID
    public let sender: String
    public let subject: String
    public let receivedAt: Date
    public let labels: [String]
    public let snippet: String
    public let historyID: GmailHistoryID
    public let privacyClass: SourcePrivacyClass
}

public struct GmailMessageRecord: Codable, Equatable, Sendable {
    public let summary: GmailMessageSummary
    public let bodyKind: EmailBodyKind
    public let decodedBody: String?
    public let attachments: [EmailAttachmentMetadata]
}

public struct GmailMessageReference: Codable, Equatable, Sendable {
    public let id: GmailMessageID
    public let threadID: GmailThreadID
    public init(id: GmailMessageID, threadID: GmailThreadID) {
        self.id = id
        self.threadID = threadID
    }
}

public struct GmailMessagePage: Equatable, Sendable {
    public let messages: [GmailMessageReference]
    public let nextPageToken: GmailPageToken?
    public init(messages: [GmailMessageReference], nextPageToken: GmailPageToken?) {
        self.messages = messages
        self.nextPageToken = nextPageToken
    }
}

public enum GmailMessageFormat: String, Equatable, Sendable {
    case metadata, full
}

public struct EmailAttachmentMetadata: Codable, Equatable, Sendable {
    public let filename: String
    public let mimeType: String
    public let size: Int
    public init(filename: String, mimeType: String, size: Int) {
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
    }
}

public struct GmailHistoryPage: Equatable, Sendable {
    public let changedMessageIDs: [GmailMessageID]
    public let deletedMessageIDs: [GmailMessageID]
    public let nextPageToken: GmailPageToken?
    public let newestHistoryID: GmailHistoryID
    public init(
        changedMessageIDs: [GmailMessageID],
        deletedMessageIDs: [GmailMessageID],
        nextPageToken: GmailPageToken?,
        newestHistoryID: GmailHistoryID
    ) {
        self.changedMessageIDs = changedMessageIDs
        self.deletedMessageIDs = deletedMessageIDs
        self.nextPageToken = nextPageToken
        self.newestHistoryID = newestHistoryID
    }
}

public struct GoogleCalendarRecord: Codable, Equatable, Sendable {
    public let id: CalendarID
    public let displayName: String
    public let isPrimary: Bool
    public init(id: CalendarID, displayName: String, isPrimary: Bool) {
        self.id = id
        self.displayName = displayName
        self.isPrimary = isPrimary
    }
}

public enum GoogleEventTime: Codable, Equatable, Sendable {
    case date(DateComponents)
    case dateTime(Date, timeZoneIdentifier: String)
}

public enum GoogleEventStatus: String, Codable, Equatable, Sendable {
    case confirmed, tentative, cancelled
}

public struct CalendarEventPage: Equatable, Sendable {
    public let events: [CalendarEventRecord]
    public let nextPageToken: CalendarPageToken?
    public let nextSyncToken: CalendarSyncToken?
    public init(
        events: [CalendarEventRecord],
        nextPageToken: CalendarPageToken?,
        nextSyncToken: CalendarSyncToken?
    ) {
        self.events = events
        self.nextPageToken = nextPageToken
        self.nextSyncToken = nextSyncToken
    }
}

public struct GoogleTaskList: Codable, Equatable, Sendable, Identifiable {
    public let id: GoogleTaskListID
    public let title: String
    public init(id: GoogleTaskListID, title: String) {
        self.id = id
        self.title = title
    }
}

public struct GoogleTaskListPage: Equatable, Sendable {
    public let lists: [GoogleTaskList]
    public let nextPageToken: GoogleTasksPageToken?
    public init(lists: [GoogleTaskList], nextPageToken: GoogleTasksPageToken?) {
        self.lists = lists
        self.nextPageToken = nextPageToken
    }
}

public struct GoogleTasksPage: Equatable, Sendable {
    public let tasks: [GoogleTaskRecord]
    public let nextPageToken: GoogleTasksPageToken?
    public init(tasks: [GoogleTaskRecord], nextPageToken: GoogleTasksPageToken?) {
        self.tasks = tasks
        self.nextPageToken = nextPageToken
    }
}

public struct GoogleResultCaps: Codable, Equatable, Sendable {
    public let calendar: Bool
    public let tasks: Bool
    public let gmail: Bool
    public init(calendar: Bool, tasks: Bool, gmail: Bool) {
        self.calendar = calendar
        self.tasks = tasks
        self.gmail = gmail
    }
}

public struct GoogleDashboardSnapshot: Codable, Equatable, Sendable {
    public let calendarEvents: [CalendarEventRecord]
    public let tasks: [GoogleTaskRecord]
    public let emails: [GmailMessageSummary]
    public let syncedAt: Date
    public let caps: GoogleResultCaps
    public init(
        calendarEvents: [CalendarEventRecord],
        tasks: [GoogleTaskRecord],
        emails: [GmailMessageSummary],
        syncedAt: Date,
        caps: GoogleResultCaps
    ) {
        self.calendarEvents = calendarEvents
        self.tasks = tasks
        self.emails = emails
        self.syncedAt = syncedAt
        self.caps = caps
    }
}

public struct CalendarEventRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: GoogleCalendarEventID
    public let calendarID: CalendarID
    public let title: String
    public let description: String?
    public let location: String?
    public let start: GoogleEventTime
    public let end: GoogleEventTime
    public let status: GoogleEventStatus
    public let updatedAt: Date
    public let privacyClass: SourcePrivacyClass
}

public struct GoogleTaskRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: GoogleTaskID
    public let listID: GoogleTaskListID
    public let listTitle: String
    public let title: String
    public let notes: String?
    public let dueDate: DateComponents?
    public let updatedAt: Date
    public let isCompleted: Bool
    public let isDeleted: Bool
    public let privacyClass: SourcePrivacyClass
}
```

Every opaque identifier follows the `GoogleAccessToken` pattern with a private raw value, strict nonempty/control-free validation, redacted description, and a narrowly named `withUnsafeRawValue` closure for provider URL construction. `GoogleDashboardSnapshot` contains `[CalendarEventRecord]`, `[GoogleTaskRecord]`, `[GmailMessageSummary]`, `syncedAt`, and a `GoogleResultCaps` value. Page values contain items plus `nextPageToken`; Gmail history also contains changed/deleted IDs and newest history ID; the Calendar final page may contain `nextSyncToken`.

Use explicit token arguments so `GoogleDashboardSyncWorkflow` can obtain exactly one access token and share it across all three readers:

```swift
public struct GoogleAccessToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let rawValue: String

    public init(validating rawValue: String) throws {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 8_192,
              rawValue.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else {
            throw GoogleAccessTokenError.invalidValue
        }
        self.rawValue = rawValue
    }

    public func withUnsafeRawValue<T>(_ body: (String) throws -> T) rethrows -> T {
        try body(rawValue)
    }

    public var description: String { "GoogleAccessToken(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection()) }
}

public enum GoogleAccessTokenError: Error, Equatable, Sendable {
    case invalidValue
}

public protocol GoogleAccessTokenProviding: Sendable {
    func accessToken() async throws -> GoogleAccessToken
}

public protocol GmailReading: Sendable {
    func messages(receivedAfter: Date, pageToken: GmailPageToken?, accessToken: GoogleAccessToken) async throws -> GmailMessagePage
    func message(id: GmailMessageID, format: GmailMessageFormat, accessToken: GoogleAccessToken) async throws -> GmailMessageRecord
    func changes(after historyID: GmailHistoryID, pageToken: GmailPageToken?, accessToken: GoogleAccessToken) async throws -> GmailHistoryPage
}

public protocol GoogleCalendarReading: Sendable {
    func primaryCalendar(accessToken: GoogleAccessToken) async throws -> GoogleCalendarRecord
    func events(calendarID: CalendarID, interval: DateInterval, syncToken: CalendarSyncToken?, pageToken: CalendarPageToken?, accessToken: GoogleAccessToken) async throws -> CalendarEventPage
}

public protocol GoogleTasksReading: Sendable {
    func taskLists(pageToken: GoogleTasksPageToken?, accessToken: GoogleAccessToken) async throws -> GoogleTaskListPage
    func tasks(listID: GoogleTaskListID, updatedSince: Date?, pageToken: GoogleTasksPageToken?, accessToken: GoogleAccessToken) async throws -> GoogleTasksPage
}

public protocol GoogleSnapshotCaching: Sendable {
    func loadState(for binding: GoogleIdentityBinding) async throws -> GoogleCommittedCacheState?
    func replaceState(_ state: GoogleCommittedCacheState, for binding: GoogleIdentityBinding) async throws
    func purge(for binding: GoogleIdentityBinding) async throws
}

public protocol GoogleContentClassifying: Sendable {
    func classify(_ input: GoogleContentClassificationInput) -> SourcePrivacyClass
}

public protocol EmailBodySanitizing: Sendable {
    func sanitize(kind: EmailBodyKind, decodedBody: String) throws -> SanitizedEmailBody
}
```

- [ ] **Step 4: Run focused GREEN and full regression tests in separate scratch paths**

```zsh
focused=$(mktemp -d /tmp/daily-planner-m2b-task1-green.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$focused" \
  --filter GoogleDashboardModelsTests --no-parallel
full=$(mktemp -d /tmp/daily-planner-m2b-task1-full.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$full" --no-parallel
git diff --check
```

Expected: focused suite and full package PASS; diff check exits 0.

- [ ] **Step 5: Commit only Task 1 files and pass both independent review gates**

```zsh
git add DailyPlanner/Sources/DailyPlannerDomain/GoogleDashboardModels.swift \
  DailyPlanner/Sources/DailyPlannerDomain/GoogleReadPorts.swift \
  DailyPlanner/Tests/DailyPlannerDomainTests/GoogleDashboardModelsTests.swift
git commit -m "feat: add Google dashboard domain contracts"
```

### Task 2: Reusable access-token refresh boundary

**Files:**
- Create: `DailyPlanner/Sources/DailyPlannerGoogle/GoogleAccessTokenProvider.swift`
- Modify: `DailyPlanner/Sources/DailyPlannerGoogle/GoogleReadOnlyConnectionController.swift`
- Create: `DailyPlanner/Tests/DailyPlannerGoogleTests/GoogleAccessTokenProviderTests.swift`
- Modify: `DailyPlanner/Tests/DailyPlannerGoogleTests/GoogleReadOnlyConnectionControllerTests.swift`

**Interfaces:**
- Consumes: `GoogleAccessTokenProviding`, `GoogleAccessToken`, `GoogleOAuthCredentialStoring`, `GoogleHTTPTransport`, `ApprovedGoogleScopes.readOnly`.
- Produces: `GoogleOAuthTokenService.refresh(clientConfiguration:refreshToken:) async throws -> GoogleAccessToken` and `StoredGoogleAccessTokenProvider.accessToken() async throws -> GoogleAccessToken`.

- [ ] **Step 1: Write failing tests for exact refresh form, alias handling, rotation safety, and redaction**

```swift
func testProviderLoadsStoredCredentialsAndPostsExactRefreshForm() async throws {
    let harness = TokenProviderHarness.success(scope: ApprovedGoogleScopes.readOnly.joined(separator: " "))
    let token = try await harness.provider.accessToken()
    XCTAssertEqual(harness.transport.requests.count, 1)
    XCTAssertEqual(harness.transport.requests[0].url?.absoluteString, "https://oauth2.googleapis.com/token")
    XCTAssertEqual(harness.transport.requests[0].httpMethod, "POST")
    XCTAssertEqual(harness.transport.formFields["grant_type"], "refresh_token")
    XCTAssertEqual(String(describing: token), "GoogleAccessToken(redacted)")
}

func testProviderRejectsMissingCredentialWrongScopeNonBearerAndRawTransportError() async {
    for harness in TokenProviderHarness.failureCases {
        do {
            _ = try await harness.provider.accessToken()
            XCTFail("invalid token response was accepted")
        } catch let error as GoogleAccessTokenProviderError {
            XCTAssertTrue(GoogleAccessTokenProviderError.allCases.contains(error))
        } catch {
            XCTFail("raw error escaped the token provider")
        }
        XCTAssertFalse(harness.diagnostics.containsSecretMaterial)
    }
}
```

Include a scope test accepting Google's `https://www.googleapis.com/auth/userinfo.email` alias as canonical `email`, and a regression proving the connection controller still refreshes the just-issued token before confirmation without requiring it to be persisted first.

- [ ] **Step 2: Run RED**

```zsh
scratch=$(mktemp -d /tmp/daily-planner-m2b-task2-red.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$scratch" \
  --filter 'GoogleAccessTokenProviderTests|GoogleReadOnlyConnectionControllerTests' --no-parallel
```

Expected: FAIL because the provider and token service are absent.

- [ ] **Step 3: Extract one strict token service and adapt the controller**

```swift
public enum GoogleAccessTokenProviderError: Error, Equatable, CaseIterable, Sendable {
    case notConfigured, credentialUnavailable, offline, rejected, scopeMismatch, malformedResponse
}

public struct GoogleOAuthTokenService: Sendable {
    let transport: any GoogleHTTPTransport

    public func refresh(
        clientConfiguration: GoogleOAuthClientConfiguration,
        refreshToken: String
    ) async throws -> GoogleAccessToken {
        let request = Self.refreshRequest(
            clientConfiguration: clientConfiguration,
            refreshToken: refreshToken
        )
        let response = try await transport.send(request)
        guard response.statusCode == 200 else { throw GoogleAccessTokenProviderError.rejected }
        let decoded = try Self.decodeTokenResponse(response.data)
        try Self.validateApprovedScopes(decoded.scope)
        guard decoded.tokenType == "Bearer", decoded.expiresIn > 0 else {
            throw GoogleAccessTokenProviderError.malformedResponse
        }
        return try GoogleAccessToken(validating: decoded.accessToken)
    }
}

public struct StoredGoogleAccessTokenProvider: GoogleAccessTokenProviding, Sendable {
    let credentials: any GoogleOAuthCredentialStoring
    let tokenService: GoogleOAuthTokenService

    public func accessToken() async throws -> GoogleAccessToken {
        guard let configuration = try credentials.loadClientConfiguration(),
              let refreshToken = try credentials.loadRefreshToken() else {
            throw GoogleAccessTokenProviderError.notConfigured
        }
        return try await tokenService.refresh(
            clientConfiguration: configuration,
            refreshToken: refreshToken
        )
    }
}
```

Move token response validation out of `GoogleReadOnlyConnectionController`; keep authorization-code exchange there, then call the shared service for the pre-confirm refresh. Do not cache the access token beyond the caller's operation.

- [ ] **Step 4: Run focused and full GREEN**

```zsh
focused=$(mktemp -d /tmp/daily-planner-m2b-task2-green.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$focused" \
  --filter 'GoogleAccessTokenProviderTests|GoogleReadOnlyConnectionControllerTests' --no-parallel
full=$(mktemp -d /tmp/daily-planner-m2b-task2-full.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$full" --no-parallel
git diff --check
```

- [ ] **Step 5: Commit and pass both review gates**

```zsh
git add DailyPlanner/Sources/DailyPlannerGoogle/GoogleAccessTokenProvider.swift \
  DailyPlanner/Sources/DailyPlannerGoogle/GoogleReadOnlyConnectionController.swift \
  DailyPlanner/Tests/DailyPlannerGoogleTests/GoogleAccessTokenProviderTests.swift \
  DailyPlanner/Tests/DailyPlannerGoogleTests/GoogleReadOnlyConnectionControllerTests.swift
git commit -m "refactor: reuse strict Google token refresh"
```

### Task 3: Exact GET-only provider network policy

**Files:**
- Create: `DailyPlanner/Sources/DailyPlannerGoogle/GoogleRequestBuilder.swift`
- Modify: `DailyPlanner/Sources/DailyPlannerGoogle/GoogleNetworkPolicy.swift`
- Modify: `DailyPlanner/Tests/DailyPlannerGoogleTests/GoogleNetworkPolicyTests.swift`
- Modify: `DailyPlanner/Tests/DailyPlannerGoogleTests/GoogleHTTPTransportTests.swift`
- Create: `DailyPlanner/Tests/DailyPlannerGoogleTests/GoogleRequestBuilderTests.swift`

**Interfaces:**
- Consumes: `GoogleAccessToken` and the existing `GoogleHTTPTransport` preflight.
- Produces: `GoogleRequestBuilder.get(url:accessToken:) throws -> URLRequest`; policy support for exact Gmail profile/messages/history, Calendar calendar-list/events, and Tasks lists/tasks GET templates.

- [ ] **Step 1: Add exhaustive failing allowlist and inverse-canary tests**

```swift
func testPolicyAcceptsOnlyM2BReadRoutesWithBoundedQueryKeys() throws {
    let accepted = [
        providerGET("https://gmail.googleapis.com/gmail/v1/users/me/messages?q=newer_than%3A30d&maxResults=100"),
        providerGET("https://gmail.googleapis.com/gmail/v1/users/me/messages/opaque?format=metadata&metadataHeaders=From&metadataHeaders=Subject"),
        providerGET("https://gmail.googleapis.com/gmail/v1/users/me/history?startHistoryId=123&historyTypes=messageAdded&historyTypes=messageDeleted"),
        providerGET("https://www.googleapis.com/calendar/v3/users/me/calendarList?minAccessRole=reader&showDeleted=false"),
        providerGET("https://www.googleapis.com/calendar/v3/calendars/opaque/events?singleEvents=true&showDeleted=true&timeMin=2026-09-10T00%3A00%3A00Z&timeMax=2026-09-17T00%3A00%3A00Z"),
        providerGET("https://tasks.googleapis.com/tasks/v1/users/@me/lists?maxResults=100"),
        providerGET("https://tasks.googleapis.com/tasks/v1/lists/opaque/tasks?showCompleted=false&showDeleted=false&showHidden=false&maxResults=100"),
    ]
    try accepted.forEach { XCTAssertNoThrow(try GoogleNetworkPolicy.validate($0)) }
}

func testPolicyRejectsMutationsUploadsBatchUnknownQueriesDuplicateSingletonsAndEncodedPaths() {
    let rejected = [
        providerRequest("POST", "https://gmail.googleapis.com/gmail/v1/users/me/messages/send"),
        providerRequest("PATCH", "https://www.googleapis.com/calendar/v3/calendars/x/events/y"),
        providerRequest("DELETE", "https://tasks.googleapis.com/tasks/v1/lists/x/tasks/y"),
        providerGET("https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/x"),
        providerGET("https://www.googleapis.com/batch/calendar/v3"),
        providerGET("https://tasks.googleapis.com/tasks/v1/lists/x/tasks?maxResults=100&maxResults=100"),
        providerGET("https://gmail.googleapis.com/gmail/v1/users/me/messages/x/attachments/y"),
    ]
    rejected.forEach { XCTAssertThrowsError(try GoogleNetworkPolicy.validate($0)) }
}
```

Test every allowed query key, duplicate key rule, percent encoding, enum value, numeric bound, no fragments/user-info, one Authorization header, and zero attachment endpoints.

Add an M2B transport regression where an allowed GET receives a redirect to another allowed GET and assert the transport returns the original 3xx response without following it. This preserves the existing no-redirect boundary while route coverage expands.

- [ ] **Step 2: Run RED**

```zsh
scratch=$(mktemp -d /tmp/daily-planner-m2b-task3-red.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$scratch" \
  --filter 'GoogleNetworkPolicyTests|GoogleRequestBuilderTests|GoogleHTTPTransportTests' --no-parallel
```

- [ ] **Step 3: Implement route-template validation and canonical GET construction**

```swift
public enum GoogleRequestBuilder {
    public static func get(url: URL, accessToken: GoogleAccessToken) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let authorization = accessToken.withUnsafeRawValue { "Bearer \($0)" }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        try GoogleNetworkPolicy.validate(request)
        return request
    }
}
```

Implement a route enum that matches decoded path components, validates exact hosts and methods, and validates query items as a multimap. Allow repeated keys only for Gmail `metadataHeaders` and `historyTypes`; reject duplicate singleton keys, empty values, unknown keys, out-of-range limits, attachment paths, and all non-GET provider methods.

- [ ] **Step 4: Run focused and full GREEN**

```zsh
focused=$(mktemp -d /tmp/daily-planner-m2b-task3-green.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$focused" \
  --filter 'GoogleNetworkPolicyTests|GoogleRequestBuilderTests|GoogleHTTPTransportTests' --no-parallel
full=$(mktemp -d /tmp/daily-planner-m2b-task3-full.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$full" --no-parallel
git diff --check
```

- [ ] **Step 5: Commit and pass both review gates**

```zsh
git add DailyPlanner/Sources/DailyPlannerGoogle/GoogleRequestBuilder.swift \
  DailyPlanner/Sources/DailyPlannerGoogle/GoogleNetworkPolicy.swift \
  DailyPlanner/Tests/DailyPlannerGoogleTests/GoogleRequestBuilderTests.swift \
  DailyPlanner/Tests/DailyPlannerGoogleTests/GoogleNetworkPolicyTests.swift \
  DailyPlanner/Tests/DailyPlannerGoogleTests/GoogleHTTPTransportTests.swift
git commit -m "feat: allowlist bounded Google read routes"
```

### Task 4: Strict Gmail list, detail, and history client

**Files:**
- Modify: `DailyPlanner/Package.swift`
- Create: `DailyPlanner/Sources/DailyPlannerGoogle/GmailReadClient.swift`
- Create: `DailyPlanner/Tests/DailyPlannerGoogleTests/GmailReadClientTests.swift`
- Create: `DailyPlanner/Tests/DailyPlannerGoogleTests/Fixtures/gmail-list.json`
- Create: `DailyPlanner/Tests/DailyPlannerGoogleTests/Fixtures/gmail-message-multipart.json`
- Create: `DailyPlanner/Tests/DailyPlannerGoogleTests/Fixtures/gmail-history.json`

**Interfaces:**
- Consumes: `GmailReading`, Gmail domain records, `GoogleRequestBuilder`, and `GoogleHTTPTransport`.
- Produces: `GmailReadClient` implementing one provider page per call and `GmailReadClientError` with `.expiredHistory`, `.cancelled`, `.offline`, `.providerUnavailable`, `.malformedResponse`, and `.limitViolation`; private `GmailURL.messages(receivedAfter:pageToken:)`, `GmailURL.message(id:format:)`, `GmailURL.history(after:pageToken:)`, `GmailWireMessage`, `GmailWireDecoder.record(from:)`, `sendGET(_:accessToken:)`, and `decodePage(_:from:)` helpers in the same source file. `GmailHarness` lives in `GmailReadClientTests.swift`.

- [ ] **Step 1: Write failing request/decoder tests using only synthetic fixtures**

```swift
func testMessagesBuildsBoundedThirtyDayQueryAndDecodesOpaqueIDs() async throws {
    let harness = GmailHarness(response: fixture("gmail-list"))
    let page = try await harness.client.messages(
        receivedAfter: Date(timeIntervalSince1970: 1_788_112_800),
        pageToken: nil,
        accessToken: harness.token
    )
    XCTAssertEqual(page.messages.count, 2)
    XCTAssertEqual(harness.request.httpMethod, "GET")
    XCTAssertEqual(harness.query["maxResults"], ["100"])
    XCTAssertEqual(harness.query["q"], ["after:1788112800"])
}

func testFullMessageDecodesPreferredPlainPartBoundsFieldsAndNeverRequestsAttachment() async throws {
    let harness = GmailHarness(response: fixture("gmail-message-multipart"))
    let record = try await harness.client.message(id: harness.messageID, format: .full, accessToken: harness.token)
    XCTAssertEqual(record.bodyKind, .plainText)
    XCTAssertEqual(record.attachments.map(\.filename), ["statement.pdf"])
    XCTAssertFalse(harness.request.url!.path.contains("attachments"))
}

func testHistoryMaps404ToExpiredHistoryAndRejectsMissingHistoryIDInvalidBase64AndOversizedBody() async {
    let cases = GmailHarness.invalidCases
    for harness in cases {
        do {
            _ = try await harness.operation()
            XCTFail("invalid Gmail response was accepted")
        } catch let error as GmailReadClientError {
            XCTAssertTrue([.expiredHistory, .malformedResponse, .limitViolation].contains(error))
        } catch {
            XCTFail("raw error escaped the Gmail client")
        }
    }
}
```

Cover absent/duplicate From or Subject headers, invalid internal date, invalid base64url, nested MIME depth, decoded body over 512 KiB, fields over 512 scalars, malformed page tokens, non-2xx responses, and cancellation.

- [ ] **Step 2: Run RED**

```zsh
scratch=$(mktemp -d /tmp/daily-planner-m2b-task4-red.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$scratch" \
  --filter GmailReadClientTests --no-parallel
```

- [ ] **Step 3: Implement one-page requests and strict bounded decoding**

First add the shared synthetic fixtures directory to the existing Google test target:

```swift
.testTarget(
    name: "DailyPlannerGoogleTests",
    dependencies: ["DailyPlannerDomain", "DailyPlannerPersistence", "DailyPlannerGoogle"],
    resources: [.process("Fixtures")]
),
```

```swift
public struct GmailReadClient: GmailReading, Sendable {
    public let transport: any GoogleHTTPTransport

    public func messages(
        receivedAfter: Date,
        pageToken: GmailPageToken?,
        accessToken: GoogleAccessToken
    ) async throws -> GmailMessagePage {
        let url = try GmailURL.messages(receivedAfter: receivedAfter, pageToken: pageToken)
        return try await decodePage(GmailMessagePage.self, from: sendGET(url, accessToken: accessToken))
    }

    public func message(
        id: GmailMessageID,
        format: GmailMessageFormat,
        accessToken: GoogleAccessToken
    ) async throws -> GmailMessageRecord {
        let url = try GmailURL.message(id: id, format: format)
        let wire = try await decodePage(GmailWireMessage.self, from: sendGET(url, accessToken: accessToken))
        return try GmailWireDecoder.record(from: wire)
    }

    public func changes(
        after historyID: GmailHistoryID,
        pageToken: GmailPageToken?,
        accessToken: GoogleAccessToken
    ) async throws -> GmailHistoryPage {
        let url = try GmailURL.history(after: historyID, pageToken: pageToken)
        let response = try await sendGET(url, accessToken: accessToken)
        guard response.statusCode != 404 else { throw GmailReadClientError.expiredHistory }
        return try decodePage(GmailHistoryPage.self, from: response)
    }
}
```

Decode base64url locally with explicit padding, prefer `text/plain`, otherwise retain bounded `text/html` as untrusted input, record attachment filename/MIME/size only, and never parse or call an attachment ID.

- [ ] **Step 4: Run focused and full GREEN**

```zsh
focused=$(mktemp -d /tmp/daily-planner-m2b-task4-green.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$focused" \
  --filter GmailReadClientTests --no-parallel
full=$(mktemp -d /tmp/daily-planner-m2b-task4-full.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$full" --no-parallel
git diff --check
```

- [ ] **Step 5: Commit and pass both review gates**

```zsh
git add DailyPlanner/Sources/DailyPlannerGoogle/GmailReadClient.swift \
  DailyPlanner/Package.swift \
  DailyPlanner/Tests/DailyPlannerGoogleTests/GmailReadClientTests.swift \
  DailyPlanner/Tests/DailyPlannerGoogleTests/Fixtures/gmail-list.json \
  DailyPlanner/Tests/DailyPlannerGoogleTests/Fixtures/gmail-message-multipart.json \
  DailyPlanner/Tests/DailyPlannerGoogleTests/Fixtures/gmail-history.json
git commit -m "feat: add strict Gmail read client"
```

### Task 5: Primary-calendar event client

**Files:**
- Create: `DailyPlanner/Sources/DailyPlannerGoogle/GoogleCalendarReadClient.swift`
- Create: `DailyPlanner/Tests/DailyPlannerGoogleTests/GoogleCalendarReadClientTests.swift`
- Create: `DailyPlanner/Tests/DailyPlannerGoogleTests/Fixtures/calendar-list.json`
- Create: `DailyPlanner/Tests/DailyPlannerGoogleTests/Fixtures/calendar-events.json`

**Interfaces:**
- Consumes: `GoogleCalendarReading`, Calendar domain records, `GoogleRequestBuilder`, and `GoogleHTTPTransport`.
- Produces: `GoogleCalendarReadClient`; `GoogleCalendarReadClientError` including `.missingPrimary`, `.duplicatePrimary`, `.expiredSyncToken`, and finite transport/decode cases; private `readCalendarListPages(accessToken:maximumPages:)`, `CalendarURL.events(calendarID:interval:syncToken:pageToken:)`, and `CalendarWireDecoder.page(from:)` helpers in the same source file. `CalendarHarness` lives in `GoogleCalendarReadClientTests.swift`.

- [ ] **Step 1: Write failing tests for primary selection, time semantics, and recovery status**

```swift
func testPrimaryCalendarRequiresExactlyOneProviderPrimaryRecord() async throws {
    let one = CalendarHarness(calendarList: fixture("calendar-list"))
    let primary = try await one.client.primaryCalendar(accessToken: one.token)
    XCTAssertTrue(primary.isPrimary)
    XCTAssertEqual(one.query["minAccessRole"], ["reader"])

    for invalid in [CalendarHarness(noPrimary: true), CalendarHarness(duplicatePrimary: true)] {
        do {
            _ = try await invalid.client.primaryCalendar(accessToken: invalid.token)
            XCTFail("invalid primary-calendar set was accepted")
        } catch let error as GoogleCalendarReadClientError {
            XCTAssertTrue([.missingPrimary, .duplicatePrimary].contains(error))
        }
    }
}

func testEventsPreserveAllDayDatesTimedInstantsTimeZonesCancellationAndFinalSyncToken() async throws {
    let harness = CalendarHarness(events: fixture("calendar-events"))
    let page = try await harness.client.events(
        calendarID: harness.calendarID,
        interval: harness.interval,
        syncToken: nil,
        pageToken: nil,
        accessToken: harness.token
    )
    XCTAssertEqual(page.events.count, 3)
    XCTAssertEqual(page.nextSyncToken, try CalendarSyncToken(validating: "opaque-sync"))
    XCTAssertEqual(page.events[0].start, .date(DateComponents(year: 2026, month: 9, day: 10)))
}
```

Add cases for HTTP 410, multiple/no primary, malformed access role, missing end, reversed interval, mixed date/dateTime, invalid RFC3339, recurring instances, deleted events, query stability across page tokens, and no display-name selection.

- [ ] **Step 2: Run RED**

```zsh
scratch=$(mktemp -d /tmp/daily-planner-m2b-task5-red.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$scratch" \
  --filter GoogleCalendarReadClientTests --no-parallel
```

- [ ] **Step 3: Implement strict primary and event reads**

```swift
public struct GoogleCalendarReadClient: GoogleCalendarReading, Sendable {
    public let transport: any GoogleHTTPTransport

    public func primaryCalendar(accessToken: GoogleAccessToken) async throws -> GoogleCalendarRecord {
        let pages = try await readCalendarListPages(accessToken: accessToken, maximumPages: 10)
        let primaries = pages.flatMap(\.calendars).filter(\.isPrimary)
        guard primaries.count == 1 else {
            throw primaries.isEmpty
                ? GoogleCalendarReadClientError.missingPrimary
                : GoogleCalendarReadClientError.duplicatePrimary
        }
        return primaries[0]
    }

    public func events(
        calendarID: CalendarID,
        interval: DateInterval,
        syncToken: CalendarSyncToken?,
        pageToken: CalendarPageToken?,
        accessToken: GoogleAccessToken
    ) async throws -> CalendarEventPage {
        let url = try CalendarURL.events(
            calendarID: calendarID,
            interval: interval,
            syncToken: syncToken,
            pageToken: pageToken
        )
        let response = try await transport.send(GoogleRequestBuilder.get(url: url, accessToken: accessToken))
        guard response.statusCode != 410 else { throw GoogleCalendarReadClientError.expiredSyncToken }
        return try CalendarWireDecoder.page(from: response)
    }
}
```

Percent-encode the opaque calendar ID as one path segment, preserve date-only versus instant semantics, and do not infer recurrence instances.

- [ ] **Step 4: Run focused and full GREEN**

```zsh
focused=$(mktemp -d /tmp/daily-planner-m2b-task5-green.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$focused" \
  --filter GoogleCalendarReadClientTests --no-parallel
full=$(mktemp -d /tmp/daily-planner-m2b-task5-full.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$full" --no-parallel
git diff --check
```

- [ ] **Step 5: Commit and pass both review gates**

```zsh
git add DailyPlanner/Sources/DailyPlannerGoogle/GoogleCalendarReadClient.swift \
  DailyPlanner/Tests/DailyPlannerGoogleTests/GoogleCalendarReadClientTests.swift \
  DailyPlanner/Tests/DailyPlannerGoogleTests/Fixtures/calendar-list.json \
  DailyPlanner/Tests/DailyPlannerGoogleTests/Fixtures/calendar-events.json
git commit -m "feat: add primary Google Calendar reader"
```

### Task 6: All-list Google Tasks client

**Files:**
- Create: `DailyPlanner/Sources/DailyPlannerGoogle/GoogleTasksReadClient.swift`
- Create: `DailyPlanner/Tests/DailyPlannerGoogleTests/GoogleTasksReadClientTests.swift`
- Create: `DailyPlanner/Tests/DailyPlannerGoogleTests/Fixtures/task-lists.json`
- Create: `DailyPlanner/Tests/DailyPlannerGoogleTests/Fixtures/tasks.json`

**Interfaces:**
- Consumes: `GoogleTasksReading`, Tasks domain records, `GoogleRequestBuilder`, and `GoogleHTTPTransport`.
- Produces: `GoogleTasksReadClient` and finite `GoogleTasksReadClientError` cases; private `TasksURL.lists(pageToken:)`, `TasksURL.tasks(listID:updatedSince:pageToken:)`, `TasksWireDecoder.listPage(from:)`, and `TasksWireDecoder.taskPage(from:listID:)` helpers in the same source file. `TasksHarness` lives in `GoogleTasksReadClientTests.swift`.

- [ ] **Step 1: Write failing list/task request and decoder tests**

```swift
func testTaskListsAndIncompleteTasksDecodeDateOnlyDueValues() async throws {
    let harness = TasksHarness(listResponse: fixture("task-lists"), taskResponse: fixture("tasks"))
    let lists = try await harness.client.taskLists(pageToken: nil, accessToken: harness.token)
    let page = try await harness.client.tasks(
        listID: lists.lists[0].id,
        updatedSince: nil,
        pageToken: nil,
        accessToken: harness.token
    )
    XCTAssertEqual(page.tasks.filter { !$0.isCompleted && !$0.isDeleted }.count, 2)
    XCTAssertEqual(page.tasks[0].dueDate, DateComponents(year: 2026, month: 9, day: 12))
    XCTAssertEqual(harness.taskQuery["showCompleted"], ["false"])
}

func testReconciliationRequestIncludesRemovalStatesAndUpdatedMinWithoutFabricatingTime() async throws {
    let harness = TasksHarness.reconciliation
    _ = try await harness.client.tasks(
        listID: harness.listID,
        updatedSince: harness.updatedSince,
        pageToken: nil,
        accessToken: harness.token
    )
    XCTAssertEqual(harness.taskQuery["showCompleted"], ["true"])
    XCTAssertEqual(harness.taskQuery["showDeleted"], ["true"])
    XCTAssertEqual(harness.taskQuery["showHidden"], ["true"])
}
```

Cover malformed IDs/page tokens, invalid updated timestamp, status/deleted conflicts, missing title, pagination query stability, numeric limits, cancellation, and non-2xx mapping.

- [ ] **Step 2: Run RED**

```zsh
scratch=$(mktemp -d /tmp/daily-planner-m2b-task6-red.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$scratch" \
  --filter GoogleTasksReadClientTests --no-parallel
```

- [ ] **Step 3: Implement page-level list and task reads**

```swift
public struct GoogleTasksReadClient: GoogleTasksReading, Sendable {
    public let transport: any GoogleHTTPTransport

    public func taskLists(
        pageToken: GoogleTasksPageToken?,
        accessToken: GoogleAccessToken
    ) async throws -> GoogleTaskListPage {
        let url = try TasksURL.lists(pageToken: pageToken)
        let response = try await transport.send(GoogleRequestBuilder.get(url: url, accessToken: accessToken))
        return try TasksWireDecoder.listPage(from: response)
    }

    public func tasks(
        listID: GoogleTaskListID,
        updatedSince: Date?,
        pageToken: GoogleTasksPageToken?,
        accessToken: GoogleAccessToken
    ) async throws -> GoogleTasksPage {
        let url = try TasksURL.tasks(listID: listID, updatedSince: updatedSince, pageToken: pageToken)
        let response = try await transport.send(GoogleRequestBuilder.get(url: url, accessToken: accessToken))
        return try TasksWireDecoder.taskPage(from: response, listID: listID)
    }
}
```

Parse Google's due timestamp into year/month/day only and discard the artificial midnight instant.

- [ ] **Step 4: Run focused and full GREEN**

```zsh
focused=$(mktemp -d /tmp/daily-planner-m2b-task6-green.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$focused" \
  --filter GoogleTasksReadClientTests --no-parallel
full=$(mktemp -d /tmp/daily-planner-m2b-task6-full.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$full" --no-parallel
git diff --check
```

- [ ] **Step 5: Commit and pass both review gates**

```zsh
git add DailyPlanner/Sources/DailyPlannerGoogle/GoogleTasksReadClient.swift \
  DailyPlanner/Tests/DailyPlannerGoogleTests/GoogleTasksReadClientTests.swift \
  DailyPlanner/Tests/DailyPlannerGoogleTests/Fixtures/task-lists.json \
  DailyPlanner/Tests/DailyPlannerGoogleTests/Fixtures/tasks.json
git commit -m "feat: add strict Google Tasks reader"
```

### Task 7: Conservative privacy classifier and inert email-body sanitizer

**Files:**
- Create: `DailyPlanner/Sources/DailyPlannerApplication/GoogleContentPrivacyClassifier.swift`
- Create: `DailyPlanner/Sources/DailyPlannerApplication/EmailBodySanitizer.swift`
- Create: `DailyPlanner/Tests/DailyPlannerApplicationTests/GoogleContentPrivacyClassifierTests.swift`
- Create: `DailyPlanner/Tests/DailyPlannerApplicationTests/EmailBodySanitizerTests.swift`

**Interfaces:**
- Consumes: `GoogleContentClassifying`, `GoogleContentClassificationInput`, `SourcePrivacyClass`, `EmailBodySanitizing`, and `SanitizedEmailBody`.
- Produces: `DeterministicGoogleContentPrivacyClassifier` and its private `SensitiveIndicator.matches(_:)`; `StrictEmailBodySanitizer` and its private `HTMLAllowlistSanitizer.sanitize(_:)`.

- [ ] **Step 1: Write failing fail-closed classification and sanitizer tests**

```swift
func testClassifierMarksSensitiveAndUncertainContentPrivate() {
    let classifier = DeterministicGoogleContentPrivacyClassifier()
    for text in ["routing number 000111", "password reset code", "diagnosis", "legal privilege"] {
        XCTAssertEqual(classifier.classify(.email(subject: text, sender: "sender@example.test", body: nil, bodyKind: .plainText)), .private)
    }
    XCTAssertEqual(classifier.classify(.email(subject: "Hello", sender: "sender@example.test", body: nil, bodyKind: .unsupported)), .private)
    XCTAssertEqual(classifier.classify(.task(title: "Buy groceries", notes: nil)), .ordinary)
}

func testHTMLSanitizerRemovesActiveAndRemoteContent() throws {
    let result = try StrictEmailBodySanitizer().sanitize(
        kind: .html,
        decodedBody: "<script>x()</script><form></form><img src='https://remote.test/x'><a href='https://example.test'>open</a><p>Hello</p>"
    )
    XCTAssertFalse(result.value.contains("script"))
    XCTAssertFalse(result.value.contains("form"))
    XCTAssertFalse(result.value.contains("https://"))
    XCTAssertTrue(result.value.contains("Hello"))
}
```

Add classifier cases for financial, credential/secret, health, legal, ambiguous MIME, invalid decoding, unsupported forms, mixed-case/Unicode normalization, false-positive boundaries, and unknown input. Add sanitizer cases for event handlers, CSS URLs/imports, iframes, SVG, data/file URLs, meta refresh, base tags, forms, links, malformed markup, and 512 KiB input enforcement.

- [ ] **Step 2: Run RED**

```zsh
scratch=$(mktemp -d /tmp/daily-planner-m2b-task7-red.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$scratch" \
  --filter 'GoogleContentPrivacyClassifierTests|EmailBodySanitizerTests' --no-parallel
```

- [ ] **Step 3: Implement deterministic matching and an allowlist sanitizer**

```swift
public struct DeterministicGoogleContentPrivacyClassifier: GoogleContentClassifying, Sendable {
    public init() {}
    public func classify(_ input: GoogleContentClassificationInput) -> SourcePrivacyClass {
        let text: String
        switch input {
        case .email(let subject, let sender, let body, let bodyKind):
            guard bodyKind != .unsupported else { return .private }
            text = [subject, sender, body ?? ""].joined(separator: "\n")
        case .event(let title, let description, let location):
            text = [title, description ?? "", location ?? ""].joined(separator: "\n")
        case .task(let title, let notes):
            text = [title, notes ?? ""].joined(separator: "\n")
        case .unknown:
            return .private
        }
        let normalized = text.precomposedStringWithCanonicalMapping.lowercased()
        return SensitiveIndicator.matches(normalized) ? .private : .ordinary
    }
}

public struct StrictEmailBodySanitizer: EmailBodySanitizing, Sendable {
    public init() {}
    public func sanitize(kind: EmailBodyKind, decodedBody: String) throws -> SanitizedEmailBody {
        guard decodedBody.utf8.count <= GoogleSyncLimits.decodedBodyBytes else {
            throw EmailBodySanitizerError.bodyTooLarge
        }
        switch kind {
        case .plainText: return SanitizedEmailBody(kind: .plainText, value: decodedBody)
        case .html: return SanitizedEmailBody(kind: .html, value: HTMLAllowlistSanitizer.sanitize(decodedBody))
        case .unsupported: throw EmailBodySanitizerError.unsupported
        }
    }
}
```

Allow only inert structural tags (`p`, `br`, `div`, `span`, `strong`, `em`, `ul`, `ol`, `li`, `blockquote`, `pre`, `code`) and text. Strip every attribute so rendered HTML cannot navigate, load, submit, script, or style remote content.

- [ ] **Step 4: Run focused and full GREEN**

```zsh
focused=$(mktemp -d /tmp/daily-planner-m2b-task7-green.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$focused" \
  --filter 'GoogleContentPrivacyClassifierTests|EmailBodySanitizerTests' --no-parallel
full=$(mktemp -d /tmp/daily-planner-m2b-task7-full.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$full" --no-parallel
git diff --check
```

- [ ] **Step 5: Commit and pass both review gates**

```zsh
git add DailyPlanner/Sources/DailyPlannerApplication/GoogleContentPrivacyClassifier.swift \
  DailyPlanner/Sources/DailyPlannerApplication/EmailBodySanitizer.swift \
  DailyPlanner/Tests/DailyPlannerApplicationTests/GoogleContentPrivacyClassifierTests.swift \
  DailyPlanner/Tests/DailyPlannerApplicationTests/EmailBodySanitizerTests.swift
git commit -m "feat: classify and sanitize Google content"
```

### Task 8: Encrypted transactional dashboard cache

**Files:**
- Create: `DailyPlanner/Sources/DailyPlannerPersistence/GoogleSnapshotKeychain.swift`
- Create: `DailyPlanner/Sources/DailyPlannerPersistence/EncryptedGoogleSnapshotCache.swift`
- Create: `DailyPlanner/Tests/DailyPlannerPersistenceTests/GoogleSnapshotKeychainTests.swift`
- Create: `DailyPlanner/Tests/DailyPlannerPersistenceTests/EncryptedGoogleSnapshotCacheTests.swift`

**Interfaces:**
- Consumes: `GoogleSnapshotCaching`, `GoogleCommittedCacheState`, `GoogleIdentityBinding`, `SourcePrivacyClass`, CryptoKit, Security.
- Produces: `GoogleSnapshotKeyMaterialProviding`, `GoogleSnapshotKeychain`, `EncryptedGoogleSnapshotCache.production()`, and finite `GoogleSnapshotCacheError` values. The cache source also defines private `CacheManifest`, `SnapshotFileAccessing`, `loadManifest()`, `decryptCommittedState(_:binding:now:)`, `redactingPrivatePayloads(_:)`, `sealState(_:binding:now:)`, `purgeFiles(for:)`, and `bindingDigest(_:)` helpers; `SnapshotCacheHarness` lives in its test file.

- [ ] **Step 1: Write failing encryption, privacy, tamper, retention, and atomicity tests**

```swift
func testOrdinaryRecordsRoundTripThroughPerRecordAESGCMWithoutPlaintext() async throws {
    let harness = SnapshotCacheHarness.generated()
    try await harness.cache.replaceState(harness.ordinaryState, for: harness.binding)
    XCTAssertEqual(try await harness.cache.loadState(for: harness.binding), harness.ordinaryState)
    let bytes = try Data(contentsOf: harness.storageURL)
    XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("synthetic ordinary subject"))
}

func testPrivateContentNeverAppearsInDurableBytes() async throws {
    let harness = SnapshotCacheHarness.generated()
    try await harness.cache.replaceState(harness.stateWithPrivateBodies, for: harness.binding)
    let bytes = try Data(contentsOf: harness.storageURL)
    for forbidden in ["private body", "private event description", "private task notes"] {
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(forbidden))
    }
}

func testFailedReplacementLeavesPriorCommittedStateAndCursorsIntact() async throws {
    let harness = SnapshotCacheHarness.generated()
    try await harness.cache.replaceState(harness.priorState, for: harness.binding)
    harness.files.failNextAtomicRename()
    do {
        try await harness.cache.replaceState(harness.nextState, for: harness.binding)
        XCTFail("injected atomic replacement failure was accepted")
    } catch let error as GoogleSnapshotCacheError {
        XCTAssertEqual(error, .writeFailed)
    }
    XCTAssertEqual(try await harness.cache.loadState(for: harness.binding), harness.priorState)
}
```

Cover distinct Keychain service/account from settings and OAuth, preferred/fallback reads and deletes, 32-byte random material, authenticated binding/source ID/version/schema/key/privacy/timestamps/retention metadata, tamper, unknown schema, lost key, mismatch purge, privacy upgrade, provider deletion, 90-day expiry, no recovery file, and concurrent replacement serialization.

- [ ] **Step 2: Run RED**

```zsh
scratch=$(mktemp -d /tmp/daily-planner-m2b-task8-red.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$scratch" \
  --filter 'GoogleSnapshotKeychainTests|EncryptedGoogleSnapshotCacheTests' --no-parallel
```

- [ ] **Step 3: Implement a dedicated key and atomic manifest swap**

```swift
public protocol GoogleSnapshotKeyMaterialProviding: Sendable {
    func existingKeyMaterial() throws -> Data?
    func keyMaterialForWrite() throws -> Data
    func deleteKeyMaterial() throws
}

public actor EncryptedGoogleSnapshotCache: GoogleSnapshotCaching {
    public func loadState(for binding: GoogleIdentityBinding) async throws -> GoogleCommittedCacheState? {
        guard let manifest = try loadManifest() else { return nil }
        guard manifest.bindingDigest == bindingDigest(binding.normalizedEmail) else {
            try purgeFiles(for: binding)
            throw GoogleSnapshotCacheError.bindingMismatch
        }
        return try decryptCommittedState(manifest, binding: binding, now: clock.now)
    }

    public func replaceState(
        _ state: GoogleCommittedCacheState,
        for binding: GoogleIdentityBinding
    ) async throws {
        let durable = redactingPrivatePayloads(state)
        let manifest = try sealState(durable, binding: binding, now: clock.now)
        let stagedURL = try files.writeStagedManifest(manifest)
        try files.synchronize(stagedURL)
        try files.replaceCommittedManifest(with: stagedURL)
    }

    public func purge(for binding: GoogleIdentityBinding) async throws {
        try purgeFiles(for: binding)
    }
}
```

Use service `DailyPlanner.GoogleSnapshot.v1`, account `content-key`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, and the same entitlement fallback logic as `SettingsKeychain` without sharing its identity or bytes.

- [ ] **Step 4: Run focused and full GREEN**

```zsh
focused=$(mktemp -d /tmp/daily-planner-m2b-task8-green.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$focused" \
  --filter 'GoogleSnapshotKeychainTests|EncryptedGoogleSnapshotCacheTests' --no-parallel
full=$(mktemp -d /tmp/daily-planner-m2b-task8-full.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$full" --no-parallel
git diff --check
```

- [ ] **Step 5: Commit and pass both review gates**

```zsh
git add DailyPlanner/Sources/DailyPlannerPersistence/GoogleSnapshotKeychain.swift \
  DailyPlanner/Sources/DailyPlannerPersistence/EncryptedGoogleSnapshotCache.swift \
  DailyPlanner/Tests/DailyPlannerPersistenceTests/GoogleSnapshotKeychainTests.swift \
  DailyPlanner/Tests/DailyPlannerPersistenceTests/EncryptedGoogleSnapshotCacheTests.swift
git commit -m "feat: cache Google snapshot with authenticated encryption"
```

### Task 9: Bounded provider partition synchronization engines

**Files:**
- Create: `DailyPlanner/Sources/DailyPlannerApplication/GmailPartitionSync.swift`
- Create: `DailyPlanner/Sources/DailyPlannerApplication/CalendarPartitionSync.swift`
- Create: `DailyPlanner/Sources/DailyPlannerApplication/TasksPartitionSync.swift`
- Create: `DailyPlanner/Tests/DailyPlannerApplicationTests/GmailPartitionSyncTests.swift`
- Create: `DailyPlanner/Tests/DailyPlannerApplicationTests/CalendarPartitionSyncTests.swift`
- Create: `DailyPlanner/Tests/DailyPlannerApplicationTests/TasksPartitionSyncTests.swift`

**Interfaces:**
- Consumes: page-level readers, one `GoogleAccessToken`, prior snapshot partitions/cursors, `GoogleContentClassifying`, `PlannerClock`, and `Calendar`.
- Produces: `GmailPartitionCandidate`, `CalendarPartitionCandidate`, `TasksPartitionCandidate`; `GmailPartitionSync.run(prior:cursor:accessToken:now:) async throws -> GmailPartitionCandidate`, `CalendarPartitionSync.run(prior:cursor:accessToken:now:calendar:) async throws -> CalendarPartitionCandidate`, and `TasksPartitionSync.run(prior:cursor:accessToken:operationStartedAt:) async throws -> TasksPartitionCandidate`. The three named harnesses live in their corresponding test files.

- [ ] **Step 1: Write failing Gmail pagination/history/recovery tests**

```swift
func testGmailInitialSyncStopsAtThirtyDaysTwoHundredMessagesOrTenPagesAndPublishesCap() async throws {
    let harness = GmailPartitionHarness.pages(count: 12, messagesPerPage: 25)
    let candidate = try await harness.sync.run(
        prior: nil,
        cursor: nil,
        accessToken: harness.token,
        now: harness.now
    )
    XCTAssertEqual(candidate.messages.count, 200)
    XCTAssertEqual(harness.reader.listCalls.count, 8)
    XCTAssertTrue(candidate.capReached)
}

func testExpiredHistoryPerformsExactlyOneBoundedFullResyncAndAdvancesOnlyCandidateCursor() async throws {
    let harness = GmailPartitionHarness.expiredHistory
    let candidate = try await harness.runIncremental()
    XCTAssertEqual(harness.reader.historyCalls.count, 1)
    XCTAssertEqual(harness.reader.listCalls.count, 1)
    XCTAssertNotEqual(candidate.historyID, harness.priorCursor)
}
```

Also prove all referenced message reads finish before candidate return, deletions reconcile, page cycles fail, a second expiration fails, partial pages do not return a candidate, and list sync fetches metadata rather than all full bodies.

- [ ] **Step 2: Write failing Calendar and Tasks engine tests**

```swift
func testCalendarUsesLocalSevenDayHalfOpenIntervalAndRecoversOnceFrom410() async throws {
    let harness = CalendarPartitionHarness.expiredToken(timeZone: TimeZone(identifier: "America/Vancouver")!)
    let candidate = try await harness.run()
    XCTAssertEqual(harness.reader.intervals[0], harness.expectedSevenLocalDays)
    XCTAssertEqual(harness.reader.primaryCalls, 1)
    XCTAssertEqual(harness.reader.fullResyncCalls, 1)
    XCTAssertFalse(candidate.events.contains { $0.status == .cancelled })
}

func testTasksEnumeratesEveryListUsesFiveMinuteOverlapAndNewestUpdatedWins() async throws {
    let harness = TasksPartitionHarness.incremental
    let candidate = try await harness.run()
    XCTAssertEqual(harness.reader.updatedSinceValues.first!, harness.priorPollTime.addingTimeInterval(-300))
    XCTAssertEqual(Set(harness.reader.listIDsRead), Set(harness.allListIDs))
    XCTAssertEqual(candidate.tasks.first?.title, "newest synthetic title")
}
```

Cover Calendar 500/10 caps, page cycles, deletion/cancellation, final-page token only, exactly-one primary, stable interval; Tasks 50-list/100-per-list/500-total/10-page caps, partial-list failure, completed/deleted removals, date-only due, deterministic order, and candidate poll time equal to operation start.

- [ ] **Step 3: Run RED**

```zsh
scratch=$(mktemp -d /tmp/daily-planner-m2b-task9-red.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$scratch" \
  --filter 'GmailPartitionSyncTests|CalendarPartitionSyncTests|TasksPartitionSyncTests' --no-parallel
```

- [ ] **Step 4: Implement ordered pagination and candidate-only cursor changes**

```swift
public struct GmailPartitionCandidate: Sendable {
    public let messages: [GmailMessageSummary]
    public let historyID: GmailHistoryID
    public let capReached: Bool
}

public struct CalendarPartitionCandidate: Sendable {
    public let events: [CalendarEventRecord]
    public let syncToken: CalendarSyncToken
    public let capReached: Bool
}

public struct TasksPartitionCandidate: Sendable {
    public let tasks: [GoogleTaskRecord]
    public let pollTime: Date
    public let capReached: Bool
}
```

Each `run` method owns its pagination loop, a visited-page-token set, the exact caps, one permitted invalid-cursor fallback, deterministic de-duplication, classification before returning records, and no durable writes.

- [ ] **Step 5: Run focused and full GREEN**

```zsh
focused=$(mktemp -d /tmp/daily-planner-m2b-task9-green.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$focused" \
  --filter 'GmailPartitionSyncTests|CalendarPartitionSyncTests|TasksPartitionSyncTests' --no-parallel
full=$(mktemp -d /tmp/daily-planner-m2b-task9-full.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$full" --no-parallel
git diff --check
```

- [ ] **Step 6: Commit and pass both review gates**

```zsh
git add DailyPlanner/Sources/DailyPlannerApplication/GmailPartitionSync.swift \
  DailyPlanner/Sources/DailyPlannerApplication/CalendarPartitionSync.swift \
  DailyPlanner/Sources/DailyPlannerApplication/TasksPartitionSync.swift \
  DailyPlanner/Tests/DailyPlannerApplicationTests/GmailPartitionSyncTests.swift \
  DailyPlanner/Tests/DailyPlannerApplicationTests/CalendarPartitionSyncTests.swift \
  DailyPlanner/Tests/DailyPlannerApplicationTests/TasksPartitionSyncTests.swift
git commit -m "feat: build bounded Google sync candidates"
```

### Task 10: Exclusive manual sync transaction and email-detail workflow

**Files:**
- Create: `DailyPlanner/Sources/DailyPlannerApplication/GoogleDashboardSyncWorkflow.swift`
- Create: `DailyPlanner/Tests/DailyPlannerApplicationTests/GoogleDashboardSyncWorkflowTests.swift`
- Modify: `DailyPlanner/Tests/DailyPlannerApplicationTests/TestSupport.swift`

**Interfaces:**
- Consumes: token provider, three partition engines, cache, settings binding, sanitizer, and clock.
- Produces: `GoogleDashboardSyncWorkflowState`, `GoogleDashboardSyncFailure`, `EmailDetailState`, and `GoogleDashboardSyncWorkflow` methods `currentState()`, `currentEmailDetail()`, `loadSavedDashboard()`, `syncNow()`, `cancel()`, `purgeConnectedAccount()`, and `loadEmailDetail(id:)`; private `currentBinding()`, `executeSync(operationID:previous:)`, `finiteLoadFailure(_:)`, `finiteSyncFailure(_:previous:)`, `finiteDetailFailure(id:error:)`, and a `GoogleDashboardSyncWorkflowState.snapshot` accessor in the same file. `DashboardSyncHarness` lives in its test file.

- [ ] **Step 1: Write failing explicit-action, transaction, concurrency, and stale-state tests**

```swift
func testConstructionDoesNotReadSettingsCacheCredentialsOrProviders() async {
    let harness = DashboardSyncHarness.generated()
    XCTAssertEqual(harness.calls, [])
    XCTAssertEqual(await harness.workflow.currentState(), .notLoaded)
}

func testSyncGetsOneTokenRunsThreeCandidatesAndCommitsOneCompleteState() async {
    let harness = DashboardSyncHarness.success()
    await harness.workflow.syncNow()
    XCTAssertEqual(harness.tokenProvider.calls, 1)
    XCTAssertEqual(harness.cache.replacements.count, 1)
    XCTAssertEqual(harness.cache.replacements[0].snapshot.syncedAt, harness.clock.now)
    XCTAssertTrue(harness.providers.overlappedTopLevelWork)
}

func testPartialFailureCancellationAndSecondSyncPreservePriorCommitAndCursors() async {
    for harness in DashboardSyncHarness.nonCommitCases {
        await harness.activate()
        XCTAssertEqual(harness.cache.committedState, harness.priorState)
        XCTAssertEqual(harness.cache.replaceAttempts, 0)
    }
}
```

Add cases for load-saved explicit activation, offline/5xx stale snapshot, rejected credential reconnect, Keychain unavailable, cache tamper/rebuild state, account mismatch purge/reconnect, explicit disconnect purge before credential deletion, operation coalescing, app-exit task cancellation, exact last-success timestamp, finite diagnostics, and empty/capped flags.

- [ ] **Step 2: Write failing email-detail tests**

```swift
func testSelectingOneEmailFetchesOnlyThatFullMessageAndSanitizesIt() async {
    let harness = DashboardSyncHarness.readyWithEmails()
    await harness.workflow.loadEmailDetail(id: harness.selectedID)
    XCTAssertEqual(harness.gmail.fullMessageIDs, [harness.selectedID])
    XCTAssertEqual(
        await harness.workflow.currentEmailDetail(),
        .ready(harness.selectedID, harness.sanitizedBody, harness.attachments)
    )
    XCTAssertEqual(harness.gmail.attachmentRequests, 0)
}

func testPrivateBodyRemainsMemoryOnlyAndIsClearedWhenSelectionChanges() async {
    let harness = DashboardSyncHarness.privateEmail()
    await harness.workflow.loadEmailDetail(id: harness.privateID)
    XCTAssertEqual(harness.cache.replaceAttempts, 0)
    await harness.workflow.loadEmailDetail(id: harness.otherID)
    XCTAssertFalse(harness.memory.contains(harness.privateBody))
}
```

- [ ] **Step 3: Run RED**

```zsh
scratch=$(mktemp -d /tmp/daily-planner-m2b-task10-red.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$scratch" \
  --filter GoogleDashboardSyncWorkflowTests --no-parallel
```

- [ ] **Step 4: Implement an actor-owned finite state machine**

```swift
public enum GoogleDashboardSyncWorkflowState: Equatable, Sendable {
    case notLoaded
    case loadingSaved
    case ready(GoogleDashboardSnapshot)
    case syncing(previous: GoogleDashboardSnapshot?)
    case stale(GoogleDashboardSnapshot, GoogleDashboardSyncFailure)
    case reconnectRequired
    case keychainUnavailable
    case cacheUnavailable
    case cancelled(previous: GoogleDashboardSnapshot?)
}

public enum GoogleDashboardSyncFailure: String, Equatable, Sendable {
    case offline, providerUnavailable, malformedResponse, limitViolation
    case credentialRejected, keychainUnavailable, cacheUnavailable, accountMismatch
}

public enum EmailDetailState: Equatable, Sendable {
    case none
    case loading(GmailMessageID)
    case ready(GmailMessageID, SanitizedEmailBody, [EmailAttachmentMetadata])
    case unavailable(GmailMessageID, GoogleDashboardSyncFailure)
}

public actor GoogleDashboardSyncWorkflow {
    public func currentState() -> GoogleDashboardSyncWorkflowState { state }
    public func currentEmailDetail() -> EmailDetailState { emailDetail }

    public func loadSavedDashboard() async {
        state = .loadingSaved
        do {
            let binding = try currentBinding()
            state = try await cache.loadState(for: binding).map { .ready($0.snapshot) } ?? .notLoaded
        } catch {
            state = finiteLoadFailure(error)
        }
    }

    public func syncNow() async {
        guard activeTask == nil else { return }
        let operationID = UUID()
        let previous = state.snapshot
        state = .syncing(previous: previous)
        activeOperationID = operationID
        activeTask = Task { await executeSync(operationID: operationID, previous: previous) }
        await activeTask?.value
    }

    public func cancel() { activeTask?.cancel() }

    public func purgeConnectedAccount() async {
        cancel()
        do {
            let binding = try currentBinding()
            try await cache.purge(for: binding)
            emailDetail = .none
            state = .notLoaded
        } catch {
            emailDetail = .none
            state = finiteLoadFailure(error)
        }
    }

    public func loadEmailDetail(id: GmailMessageID) async {
        emailDetail = .loading(id)
        do {
            let token = try await tokenProvider.accessToken()
            let record = try await gmailReader.message(id: id, format: .full, accessToken: token)
            let body = try sanitizer.sanitize(kind: record.bodyKind, decodedBody: record.decodedBody ?? "")
            emailDetail = .ready(id, body, record.attachments)
        } catch {
            emailDetail = finiteDetailFailure(id: id, error: error)
        }
    }

    private func executeSync(operationID: UUID, previous: GoogleDashboardSnapshot?) async {
        defer {
            if activeOperationID == operationID {
                activeTask = nil
                activeOperationID = nil
            }
        }
        do {
            let binding = try currentBinding()
            let prior = try await cache.loadState(for: binding)
            let token = try await tokenProvider.accessToken()
            let startedAt = clock.now
            async let gmailCandidate = gmail.run(
                prior: prior?.snapshot.emails,
                cursor: prior?.cursors.gmailHistoryID,
                accessToken: token,
                now: startedAt
            )
            async let calendarCandidate = calendarSync.run(
                prior: prior?.snapshot.calendarEvents,
                cursor: prior?.cursors.calendarSyncToken,
                accessToken: token,
                now: startedAt,
                calendar: localCalendar
            )
            async let tasksCandidate = tasks.run(
                prior: prior?.snapshot.tasks,
                cursor: prior?.cursors.taskPollTime,
                accessToken: token,
                operationStartedAt: startedAt
            )
            let (gmailResult, calendarResult, tasksResult) = try await (
                gmailCandidate, calendarCandidate, tasksCandidate
            )
            try Task.checkCancellation()
            let snapshot = GoogleDashboardSnapshot(
                calendarEvents: calendarResult.events,
                tasks: tasksResult.tasks,
                emails: gmailResult.messages,
                syncedAt: startedAt,
                caps: GoogleResultCaps(
                    calendar: calendarResult.capReached,
                    tasks: tasksResult.capReached,
                    gmail: gmailResult.capReached
                )
            )
            let committed = GoogleCommittedCacheState(
                snapshot: snapshot,
                cursors: GoogleSyncCursors(
                    gmailHistoryID: gmailResult.historyID,
                    calendarSyncToken: calendarResult.syncToken,
                    taskPollTime: tasksResult.pollTime
                )
            )
            try await cache.replaceState(committed, for: binding)
            guard activeOperationID == operationID else { return }
            state = .ready(committed.snapshot)
        } catch {
            guard activeOperationID == operationID else { return }
            state = finiteSyncFailure(error, previous: previous)
        }
    }
}
```

Map every dependency error to a finite public case; never store or interpolate raw errors. Use a unique operation ID so completion from a cancelled or superseded task cannot publish state.

- [ ] **Step 5: Run focused and full GREEN**

```zsh
focused=$(mktemp -d /tmp/daily-planner-m2b-task10-green.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$focused" \
  --filter GoogleDashboardSyncWorkflowTests --no-parallel
full=$(mktemp -d /tmp/daily-planner-m2b-task10-full.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$full" --no-parallel
git diff --check
```

- [ ] **Step 6: Commit and pass both review gates**

```zsh
git add DailyPlanner/Sources/DailyPlannerApplication/GoogleDashboardSyncWorkflow.swift \
  DailyPlanner/Tests/DailyPlannerApplicationTests/GoogleDashboardSyncWorkflowTests.swift \
  DailyPlanner/Tests/DailyPlannerApplicationTests/TestSupport.swift
git commit -m "feat: orchestrate atomic manual Google sync"
```

### Task 11: Production composition and real-data dashboard UI

**Files:**
- Modify: `DailyPlanner/Sources/DailyPlannerApp/AppComposition.swift`
- Modify: `DailyPlanner/Sources/DailyPlannerUI/PlannerAppModel.swift`
- Modify: `DailyPlanner/Sources/DailyPlannerUI/PlannerRootView.swift`
- Modify: `DailyPlanner/Sources/DailyPlannerUI/PlannerSettingsView.swift`
- Create: `DailyPlanner/Sources/DailyPlannerUI/GoogleDashboardColumns.swift`
- Create: `DailyPlanner/Sources/DailyPlannerUI/EmailDetailView.swift`
- Modify: `DailyPlanner/Tests/DailyPlannerUITests/PlannerAppModelTests.swift`
- Modify: `DailyPlanner/Tests/DailyPlannerUITests/PlannerRootViewAccessibilityTests.swift`
- Modify: `DailyPlanner/Tests/DailyPlannerAcceptanceTests/M1SafetyAcceptanceTests.swift`
- Modify: `DailyPlanner/Tests/DailyPlannerAcceptanceTests/M2AReadOnlyAcceptanceTests.swift`
- Create: `DailyPlanner/Tests/DailyPlannerAcceptanceTests/M2BRealGoogleCompositionTests.swift`

**Interfaces:**
- Consumes: `GoogleDashboardSyncWorkflow`, its finite state/detail state, concrete Google readers, encrypted cache, settings store, and existing Google connection workflow.
- Produces: `PlannerAppModel.syncNow()`, `cancelGoogleSync()`, `loadSavedDashboard()`, `selectEmail(_:)`, and disconnect coordination that calls `dashboard.purgeConnectedAccount()` before `googleConnection.disconnect()`; accessible three-column real dashboard and detail sheet.

- [ ] **Step 1: Write failing model tests proving explicit activation and finite presentation**

```swift
func testModelDoesNotLoadCacheOrSyncUntilNamedAction() async {
    let harness = PlannerModelHarness.makeM2B()
    XCTAssertEqual(harness.dashboard.calls, [])
    await harness.model.loadSavedDashboard()
    XCTAssertEqual(harness.dashboard.calls, [.loadSavedDashboard])
}

func testSyncCancelSelectionAndStatusMapToPublishedUIState() async {
    let harness = PlannerModelHarness.makeM2B(snapshot: .synthetic)
    await harness.model.syncNow()
    XCTAssertEqual(harness.model.lastSuccessfulSync, harness.snapshot.syncedAt)
    await harness.model.selectEmail(harness.emailID)
    XCTAssertEqual(harness.dashboard.detailIDs, [harness.emailID])
    harness.model.cancelGoogleSync()
    XCTAssertEqual(harness.dashboard.cancelCalls, 1)
}

func testDisconnectPurgesDashboardBeforeDeletingGoogleCredentials() async {
    let harness = PlannerModelHarness.makeM2B(snapshot: .synthetic)
    await harness.model.disconnectGoogle()
    XCTAssertEqual(harness.calls, [.dashboardPurge, .googleDisconnect])
    XCTAssertNil(harness.model.googleDashboardSnapshot)
}
```

- [ ] **Step 2: Write failing accessibility/layout/composition tests**

```swift
func testDashboardExposesSyncLoadCancelLastSuccessAndThreeDataRegions() throws {
    let view = PlannerRootView(model: PlannerModelHarness.makeM2B(snapshot: .synthetic).model)
    let tree = try AccessibilityTree.render(view)
    for identifier in [
        "google-sync-now-button", "google-load-saved-button", "google-sync-cancel-button",
        "google-last-sync-status", "google-schedule-column", "google-tasks-column", "google-email-column"
    ] { XCTAssertTrue(tree.identifiers.contains(identifier)) }
}

func testStandardProductionCompositionContainsNoSyntheticCalendarSource() {
    let source = try String(contentsOfFile: productionCompositionPath)
    XCTAssertFalse(source.contains("M1SyntheticCalendarSource"))
    XCTAssertTrue(source.contains("GmailReadClient"))
    XCTAssertTrue(source.contains("EncryptedGoogleSnapshotCache.production"))
}
```

Cover not-synced, loading, empty, syncing, stale, offline, reconnect, Keychain, cache-unavailable, cancelled, private-memory-only, and cap-reached copy; keyboard order; date-only task due rendering; all-day/timed Calendar rendering; email sender/subject/date/labels/snippet; safe detail; and the unchanged `Read-only · no actions executed` banner.

In `PlannerSettingsView`, replace the planning-calendar role picker with the fixed read-only statement `Schedule source: Google primary calendar`. Keep OAuth connection and vault controls. Preserve an explicit legacy/testing initializer for M1/M2A synthetic acceptance harnesses, but make the production `PlannerAppModel` initializer require the dashboard workflow and no calendar catalog/planning/reference source.

- [ ] **Step 3: Run RED**

```zsh
scratch=$(mktemp -d /tmp/daily-planner-m2b-task11-red.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$scratch" \
  --filter 'PlannerAppModelTests|PlannerRootViewAccessibilityTests|M2BRealGoogleCompositionTests' --no-parallel
```

- [ ] **Step 4: Wire production implementations without automatic work**

```swift
let tokenService = GoogleOAuthTokenService(transport: transport)
let tokenProvider = StoredGoogleAccessTokenProvider(credentials: credentials, tokenService: tokenService)
let classifier = DeterministicGoogleContentPrivacyClassifier()
let dashboard = GoogleDashboardSyncWorkflow(
    tokenProvider: tokenProvider,
    gmail: GmailPartitionSync(reader: GmailReadClient(transport: transport), classifier: classifier),
    calendar: CalendarPartitionSync(reader: GoogleCalendarReadClient(transport: transport), classifier: classifier),
    tasks: TasksPartitionSync(reader: GoogleTasksReadClient(transport: transport), classifier: classifier),
    cache: EncryptedGoogleSnapshotCache.production(),
    settings: settingsStore,
    sanitizer: StrictEmailBodySanitizer(),
    clock: clock
)
```

Pass `dashboard` into `PlannerAppModel`. Do not call `loadSavedDashboard` or `syncNow` from any initializer, `.task`, `onAppear`, timer, or settings lifecycle.

- [ ] **Step 5: Render the approved dashboard controls and data**

```swift
PlannerActionButton(
    title: model.isGoogleSyncing ? "Cancel" : "Sync now",
    identifier: model.isGoogleSyncing ? "google-sync-cancel-button" : "google-sync-now-button",
    accessibilityValue: model.googleSyncAccessibilityValue,
    systemImage: model.isGoogleSyncing ? "xmark" : "arrow.triangle.2.circlepath"
) {
    model.isGoogleSyncing ? model.cancelGoogleSync() : Task { await model.syncNow() }
}
```

Use the three columns for Schedule, Tasks, and Email. Selection opens `EmailDetailView`; plain text renders as `Text`, sanitized HTML renders through an inert local representation with navigation and resource loading disabled, and attachment rows show metadata only.

- [ ] **Step 6: Run focused and full GREEN**

```zsh
focused=$(mktemp -d /tmp/daily-planner-m2b-task11-green.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$focused" \
  --filter 'PlannerAppModelTests|PlannerRootViewAccessibilityTests|M2BRealGoogleCompositionTests' --no-parallel
full=$(mktemp -d /tmp/daily-planner-m2b-task11-full.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$full" --no-parallel
git diff --check
```

- [ ] **Step 7: Commit and pass both review gates**

```zsh
git add DailyPlanner/Sources/DailyPlannerApp/AppComposition.swift \
  DailyPlanner/Sources/DailyPlannerUI/PlannerAppModel.swift \
  DailyPlanner/Sources/DailyPlannerUI/PlannerRootView.swift \
  DailyPlanner/Sources/DailyPlannerUI/PlannerSettingsView.swift \
  DailyPlanner/Sources/DailyPlannerUI/GoogleDashboardColumns.swift \
  DailyPlanner/Sources/DailyPlannerUI/EmailDetailView.swift \
  DailyPlanner/Tests/DailyPlannerUITests/PlannerAppModelTests.swift \
  DailyPlanner/Tests/DailyPlannerUITests/PlannerRootViewAccessibilityTests.swift \
  DailyPlanner/Tests/DailyPlannerAcceptanceTests/M1SafetyAcceptanceTests.swift \
  DailyPlanner/Tests/DailyPlannerAcceptanceTests/M2AReadOnlyAcceptanceTests.swift \
  DailyPlanner/Tests/DailyPlannerAcceptanceTests/M2BRealGoogleCompositionTests.swift
git commit -m "feat: show real read-only Google dashboard"
```

### Task 12: Integrated read-only/privacy verifier and signed-app acceptance

**Files:**
- Create: `DailyPlanner/Tests/verify-m2b.sh`
- Modify: `DailyPlanner/Tests/verify-signed-app.sh`
- Create: `DailyPlanner/Tests/DailyPlannerAcceptanceTests/M2BReadOnlyPrivacyAcceptanceTests.swift`
- Create: `docs/superpowers/evidence/m2b-offline-acceptance.md`

**Interfaces:**
- Consumes: the complete M2B source, test suite, `swift build`, `codesign`, `otool`, `nm`, `plutil`, `open`, `pgrep`, and owned-process cleanup helpers already used by M2A verifiers.
- Produces: `DailyPlanner/Tests/verify-m2b.sh` and bounded offline evidence containing commands, commit, counts, finite states, and booleans only.

- [ ] **Step 1: Write failing integrated source/behavior acceptance tests**

```swift
func testNoGoogleMutationCapabilityOrWriteScopeIsLinked() throws {
    let sources = try ProductionSources.load()
    for forbidden in [
        "gmail.modify", "gmail.compose", "gmail.send", "calendar.events", "tasks.readwrite",
        "messages/send", "/attachments/", "watch", "batchUpdate", "events.insert", "tasks.insert"
    ] { XCTAssertFalse(sources.contains(forbidden), forbidden) }
}

func testExplicitSyncCommitsAllThreePartitionsAndPartialFailureCommitsNone() async throws {
    let success = M2BReadOnlyHarness.success()
    await success.sync()
    XCTAssertEqual(success.commits, 1)
    XCTAssertEqual(success.snapshot.partitionCounts, .init(calendar: 2, tasks: 3, gmail: 4))

    let partial = M2BReadOnlyHarness.failure(provider: .tasks)
    await partial.sync()
    XCTAssertEqual(partial.commits, 0)
    XCTAssertEqual(partial.cursors, partial.priorCursors)
}
```

Add integrated tests for zero automatic reads, private durable-content absence, attachment-byte zero, GET-only requests, cap disclosure, invalid-cursor bounded recovery, stale preservation, cancellation, account mismatch, and finite diagnostics.

- [ ] **Step 2: Run RED**

```zsh
scratch=$(mktemp -d /tmp/daily-planner-m2b-task12-red.XXXXXX)
swift test --package-path DailyPlanner --scratch-path "$scratch" \
  --filter M2BReadOnlyPrivacyAcceptanceTests --no-parallel
```

- [ ] **Step 3: Add an interruption-safe offline verifier**

```zsh
#!/bin/zsh
set -euo pipefail
repo_root=${0:A:h:h}
scratch=$(mktemp -d /tmp/daily-planner-m2b-verify.XXXXXX)
owned_pids=()
cleanup() {
  for pid in ${owned_pids[@]-}; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$scratch"
}
trap cleanup EXIT INT TERM HUP
swift test --package-path "$repo_root" --scratch-path "$scratch" --no-parallel
```

Extend the script with source scans for forbidden scopes/routes/methods and secret logging, package build, app bundle assembly using the existing signed-app helper, `codesign --verify --deep --strict --verbose=2`, exact bundle-ID/signature assertions, exact executable launch, accessibility marker checks, owned PID termination, and post-run process/scratch cleanup checks. The script must reject empty test selection and retain no provider data.

- [ ] **Step 4: Run the integrated verifier from a clean M2B diff**

```zsh
chmod +x DailyPlanner/Tests/verify-m2b.sh
DailyPlanner/Tests/verify-m2b.sh
git diff --check
```

Expected: all tests pass; mutation/privacy/source scans pass; signed app verifies and launches; only the verifier-owned process is terminated; no scratch path remains.

- [ ] **Step 5: Record bounded offline evidence**

```markdown
reviewed_commit=$(git rev-parse HEAD)
test_count=$(awk '/Executed [0-9]+ tests/ {count=$2} END {print count+0}' "$verification_log")
{
  print '# M2B offline acceptance evidence'
  print ''
  print "- Commit: $reviewed_commit"
  print "- Full tests: passed, $test_count executed, zero failures"
  print '- Provider methods: GET-only = true'
  print '- Attachment byte requests: zero'
  print '- Automatic provider reads before explicit action: zero'
  print '- Private durable-content canary matches: zero'
  print '- Atomic partial-failure commits: zero'
  print '- Signed bundle verification: passed'
  print '- Owned process cleanup: passed'
  print '- Live account access performed: false'
} > docs/superpowers/evidence/m2b-offline-acceptance.md
```

Generate this file directly from the verifier output; include no identity, provider ID, cursor, content, secret, path, or raw error.

- [ ] **Step 6: Commit, pass both task reviews, then run whole-branch review**

```zsh
git add DailyPlanner/Tests/verify-m2b.sh \
  DailyPlanner/Tests/verify-signed-app.sh \
  DailyPlanner/Tests/DailyPlannerAcceptanceTests/M2BReadOnlyPrivacyAcceptanceTests.swift \
  docs/superpowers/evidence/m2b-offline-acceptance.md
git commit -m "test: verify M2B read-only privacy boundaries"
```

Give the full range from `3dd64d6` through Task 12 to a fresh whole-branch security/code reviewer. Close every Important/Critical finding with TDD and rerun `verify-m2b.sh`. Only after whole-branch acceptance may the user explicitly authorize a signed-app live canary; record only scopes, finite state, booleans, and bounded counts from that run.

## Completion gate

M2B is complete only when all twelve task commits have passed their two independent task reviews, the full isolated test suite and `verify-m2b.sh` pass at the reviewed head, `git diff --check` is clean, the standard production composition contains no `M1SyntheticCalendarSource`, the whole-branch reviewer accepts the result, and the user-authorized signed app displays real Calendar, Tasks, and Gmail data. `HANDOFF.md` remains untouched unless the user separately requests a new handoff.
