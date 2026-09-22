# Daily Planner M1 Read-Only Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a locally signed native macOS Daily Planner shell that remembers one explicitly selected Obsidian-vault permission, stores calendar roles in encrypted private settings, renders a deterministic synthetic read-only daily preview, and proves that Excluded-reference calendars cannot influence planning.

**Architecture:** A SwiftPM workspace separates Foundation-only domain policy, application workflows, encrypted persistence, macOS adapters, SwiftUI presentation, and the executable app. M1 contains only a synthetic calendar implementation and an opaque bookmark-selection adapter: it has no live Google or Codex client, no vault-content adapter, and no external-write route. The signed app remains unsandboxed for the approved personal local-v1 distribution, while application boundaries fail closed and expose only finite statuses.

**Tech Stack:** Xcode 26.6, Swift 6.3, Swift Package Manager, macOS 15+, SwiftUI, AppKit, Foundation, CryptoKit, Security, XCTest, zsh, ad-hoc local code signing.

**Spec:** `docs/superpowers/specs/2026-08-30-daily-planner-local-v1-distribution-design.md`

## Global Constraints

- M1 is one local, non-App-Store, unsandboxed native macOS app. It has no helper, broker, server, installer, updater, launch daemon, or App Sandbox entitlement.
- M1 performs no live Google request, OAuth flow, Codex launch, model submission, provider mutation, notification delivery, or vault-content read/write.
- The only real-vault operation M1 may offer is an explicit user folder selection followed immediately by opaque security-scoped bookmark creation. M1 never resolves that bookmark, starts security-scoped access, enumerates the directory, inspects `.obsidian/`, coordinates files, or reads/writes vault content.
- Automated tests select generated temporary directories only. No personal vault, email, calendar, task, address, credential, or source content is a fixture.
- Real/runtime calendar identifiers, role assignments, role-audit entries, and the opaque bookmark are encrypted private local settings. They never enter Git, logs, notifications, accessibility labels, crash text, or sanitized evidence. Opaque `synthetic-*` identifiers are required and permitted in tracked source/tests.
- A missing or new calendar-role assignment resolves to `Excluded reference`. A corrupt or unreadable whole settings envelope fails closed before any planning read and exposes only a finite settings-unavailable state.
- `Excluded reference` events contribute zero to conflict checks, free/busy, availability, workload, fatigue, priority, digests, summary eligibility, proposal context, assistant context, or action candidates. Manual reference viewing is a separate memory-only workflow.
- `Planning` events may influence the deterministic preview only after an explicit role assignment and a validated refresh.
- Priority order is School, Career, Finance, Personal, Other. Advertisement fixtures are ignored. Stable ties sort by due/start time and then opaque synthetic identifier.
- Scheduling preview uses `America/Vancouver` and exactly 06:00, 12:00, and 21:00 local scan slots. Midnight summary logic returns eligibility metadata only and never writes a note.
- The SwiftUI shell keeps the approved balanced three-column direction: priority queue left, daily schedule center, assistant/status right. A persistent banner says the app is an offline M1 preview with no external writes.
- M1 Keychain items use the data-protection Keychain, no access group, `kSecAttrSynchronizable=false`, and `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Locked scheduling stays disabled pending its separate user-gated proof and reviewed configuration change.
- Diagnostics are finite enum codes and bounded counts. They never carry paths, bookmark bytes, calendar identifiers, titles, raw errors, stderr, prompts, tokens, or authorization URLs.
- Swift builds and tests run serially with private scratch directories. Every task follows RED → GREEN → REFACTOR and commits only its listed files.

## Locked File and Module Map

| Unit | Responsibility | Imports |
|---|---|---|
| `DailyPlannerDomain` | Calendar roles/models, planning ports, priority/influence policy, scan-slot and midnight-eligibility calculations, private-settings schema | `Foundation` only |
| `DailyPlannerApplication` | Vault onboarding, role changes, planning refresh, manual reference view, finite app states | `DailyPlannerDomain` |
| `DailyPlannerPersistence` | AES-GCM envelope, exact Keychain key record, atomic encrypted settings file | `DailyPlannerDomain`, `CryptoKit`, `Security`, `Foundation` |
| `DailyPlannerPlatform` | `NSOpenPanel` bookmark creation and synthetic read-only calendar source | Domain/Application, `AppKit` |
| `DailyPlannerUI` | App model, layout policy, three columns, onboarding/settings sheet, offline banner | Domain/Application, `SwiftUI` |
| `DailyPlannerApp` | `@main` executable and the only concrete dependency composition | UI/Platform/Application/Persistence |

---

### Task 1: Signed native app and package foundation

**Files:**
- Create: `DailyPlanner/Package.swift`
- Create: `DailyPlanner/Sources/DailyPlannerUI/M1RootView.swift`
- Create: `DailyPlanner/Sources/DailyPlannerApp/main.swift`
- Create: `DailyPlanner/Resources/Info.plist`
- Create: `DailyPlanner/Scripts/build-app.sh`
- Create: `DailyPlanner/Tests/verify-signed-app.sh`

**Interfaces:**
- Consumes: installed Xcode/Swift toolchain proven by M0.5.
- Produces: `DailyPlanner/.build/app/Daily Planner.app`, bundle identifier `com.example.dailyplanner`, and library target `DailyPlannerUI` for later UI composition.

- [ ] **Step 1: Write the failing signed-app verifier**

```zsh
#!/bin/zsh
set -euo pipefail

planner_root="${0:A:h:h}"
app="$planner_root/.build/app/Daily Planner.app"
binary="$app/Contents/MacOS/DailyPlanner"

test -x "$binary"
xattr -cr "$app"
xattr -c "$app"
codesign --verify --deep --strict "$app"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" \
  | rg -xq 'com.example.dailyplanner'

if codesign -d --entitlements :- "$app" 2>&1 \
  | rg -q 'com[.]apple[.]security[.]app-sandbox'; then
  exit 1
fi
```

- [ ] **Step 2: Run the verifier and observe RED**

Run:

```zsh
zsh DailyPlanner/Tests/verify-signed-app.sh
```

Expected: nonzero exit because `Daily Planner.app` does not exist.

- [ ] **Step 3: Add the minimal package and offline SwiftUI shell**

`DailyPlanner/Package.swift` starts with only the independently buildable UI and app targets:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DailyPlanner",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DailyPlannerUI", targets: ["DailyPlannerUI"]),
        .executable(name: "DailyPlannerApp", targets: ["DailyPlannerApp"]),
    ],
    targets: [
        .target(name: "DailyPlannerUI"),
        .executableTarget(name: "DailyPlannerApp", dependencies: ["DailyPlannerUI"]),
    ]
)
```

`M1RootView` must render real native columns, not a screenshot or web view:

```swift
import SwiftUI

public struct M1RootView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            Text("Offline M1 preview · no external writes")
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(.orange.opacity(0.16))
                .accessibilityIdentifier("m1-safety-banner")
            HStack(spacing: 0) {
                Text("Priority queue").frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                Text("Daily schedule").frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                Text("Assistant unavailable in M1").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1100, minHeight: 680)
    }
}
```

The executable is a normal SwiftUI `@main` app with one window titled `Daily Planner`.

```swift
import DailyPlannerUI
import SwiftUI

@main
struct DailyPlannerApp: App {
    var body: some Scene {
        WindowGroup("Daily Planner") { M1RootView() }
            .defaultSize(width: 1280, height: 780)
    }
}
```

`Resources/Info.plist` is exact and contains no entitlement claim:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>DailyPlanner</string>
  <key>CFBundleIdentifier</key><string>com.example.dailyplanner</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Daily Planner</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
```

- [ ] **Step 4: Assemble and sign the app with private build scratch**

`build-app.sh` must:

```zsh
#!/bin/zsh
set -euo pipefail

planner_root="${0:A:h:h}"
private_scratch="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-m1-build.XXXXXX")"
app="$planner_root/.build/app/Daily Planner.app"
trap 'rm -rf "$private_scratch"' EXIT

swift build \
  --package-path "$planner_root" \
  --scratch-path "$private_scratch/swift" \
  --configuration debug \
  --product DailyPlannerApp

binary_path="$(swift build --package-path "$planner_root" --scratch-path "$private_scratch/swift" --configuration debug --show-bin-path)/DailyPlannerApp"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$binary_path" "$app/Contents/MacOS/DailyPlanner"
cp "$planner_root/Resources/Info.plist" "$app/Contents/Info.plist"
xattr -cr "$app"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
```

The cleanup target is the exact `mktemp` directory and the app target is the exact package-local bundle; do not use a broad path or unresolved environment variable.

- [ ] **Step 5: Run GREEN verification and one owned launch cycle**

Run serially:

```zsh
zsh DailyPlanner/Scripts/build-app.sh
zsh DailyPlanner/Tests/verify-signed-app.sh
"DailyPlanner/.build/app/Daily Planner.app/Contents/MacOS/DailyPlanner" >/dev/null 2>&1 &
planner_pid=$!
sleep 1
kill "$planner_pid"
wait "$planner_pid" 2>/dev/null || true
zsh DailyPlanner/Tests/verify-signed-app.sh
```

Expected: both verifiers exit 0; only the owned PID is terminated; the app shows the orange offline banner and three native columns during the launch cycle.

- [ ] **Step 6: Commit the signed foundation**

```zsh
git add DailyPlanner/Package.swift DailyPlanner/Sources/DailyPlannerUI/M1RootView.swift \
  DailyPlanner/Sources/DailyPlannerApp/main.swift DailyPlanner/Resources/Info.plist \
  DailyPlanner/Scripts/build-app.sh DailyPlanner/Tests/verify-signed-app.sh
git commit -m "feat: scaffold signed Daily Planner shell"
```

---

### Task 2: Calendar-role domain and structural eligibility boundary

**Files:**
- Modify: `DailyPlanner/Package.swift`
- Create: `DailyPlanner/Sources/DailyPlannerDomain/CalendarModels.swift`
- Create: `DailyPlanner/Sources/DailyPlannerDomain/CalendarRolePolicy.swift`
- Create: `DailyPlanner/Sources/DailyPlannerDomain/PlanningPorts.swift`
- Create: `DailyPlanner/Tests/DailyPlannerDomainTests/CalendarRolePolicyTests.swift`

**Interfaces:**
- Consumes: Foundation only.
- Produces: `CalendarID`, `CalendarRole`, `CalendarDescriptor`, `PlannerEvent`, `CalendarRolePolicy`, `CalendarCatalogReading`, `PlanningCalendarReading`, and `ExcludedReferenceViewing`.

- [ ] **Step 1: Write role-policy tests before adding the domain target**

```swift
import XCTest
@testable import DailyPlannerDomain

final class CalendarRolePolicyTests: XCTestCase {
    func testMissingNewAndUnreadableAssignmentsFailClosedToExcludedReference() {
        let id = CalendarID(rawValue: "synthetic-new-calendar")
        XCTAssertEqual(CalendarRolePolicy.role(for: id, assignments: [:]), .excludedReference)
        XCTAssertEqual(CalendarRolePolicy.role(for: id, assignments: nil), .excludedReference)
    }

    func testPlanningIDsContainOnlyExplicitPlanningAssignments() {
        let planning = CalendarDescriptor(id: .init(rawValue: "synthetic-planning"), displayName: "School Demo")
        let reference = CalendarDescriptor(id: .init(rawValue: "synthetic-reference"), displayName: "Reference Demo")
        let ids = CalendarRolePolicy.planningCalendarIDs(
            catalog: [planning, reference],
            assignments: [planning.id: .planning, reference.id: .excludedReference]
        )
        XCTAssertEqual(ids, Set([planning.id]))
    }
}
```

- [ ] **Step 2: Run the focused tests and observe RED**

```zsh
domain_scratch="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-domain-red.XXXXXX")"
swift test --package-path DailyPlanner --scratch-path "$domain_scratch" --no-parallel \
  --filter CalendarRolePolicyTests
rm -rf "$domain_scratch"
```

Expected: compile failure because the domain module and types do not exist.

- [ ] **Step 3: Add the Foundation-only types and ports**

```swift
import Foundation

public struct CalendarID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum CalendarRole: String, Codable, Hashable, Sendable {
    case planning
    case excludedReference
}

public enum PlannerCategory: Int, Codable, CaseIterable, Hashable, Sendable {
    case school = 0
    case career = 1
    case finance = 2
    case personal = 3
    case other = 4
}

public enum PlannerItemKind: String, Codable, Hashable, Sendable {
    case event, deadline, task, extracurricular, advertisement
}

public struct CalendarDescriptor: Hashable, Sendable {
    public let id: CalendarID
    public let displayName: String

    public init(id: CalendarID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct PlannerEvent: Hashable, Sendable {
    public let id: String
    public let calendarID: CalendarID
    public let title: String
    public let category: PlannerCategory
    public let kind: PlannerItemKind
    public let start: Date
    public let end: Date
    public let due: Date?

    public init(
        id: String,
        calendarID: CalendarID,
        title: String,
        category: PlannerCategory,
        kind: PlannerItemKind,
        start: Date,
        end: Date,
        due: Date?
    ) {
        self.id = id
        self.calendarID = calendarID
        self.title = title
        self.category = category
        self.kind = kind
        self.start = start
        self.end = end
        self.due = due
    }
}
```

Keep calendar display names and event titles memory-only in M1. The three read ports are separate by construction:

```swift
public protocol CalendarCatalogReading: Sendable {
    func calendars() async throws -> [CalendarDescriptor]
}

public protocol PlanningCalendarReading: Sendable {
    func planningEvents(calendarIDs: Set<CalendarID>, interval: DateInterval) async throws -> [PlannerEvent]
}

public protocol ExcludedReferenceViewing: Sendable {
    func referenceEvents(calendarID: CalendarID, interval: DateInterval) async throws -> [PlannerEvent]
}

public protocol PlannerClock: Sendable {
    var now: Date { get }
}
```

Add these exact package entries in the existing `products` and `targets` arrays:

```swift
.library(name: "DailyPlannerDomain", targets: ["DailyPlannerDomain"]),

.target(name: "DailyPlannerDomain"),
.testTarget(name: "DailyPlannerDomainTests", dependencies: ["DailyPlannerDomain"]),
```

- [ ] **Step 4: Implement fail-closed role resolution**

```swift
public enum CalendarRolePolicy {
    public static func role(
        for id: CalendarID,
        assignments: [CalendarID: CalendarRole]?
    ) -> CalendarRole {
        assignments?[id] ?? .excludedReference
    }

    public static func planningCalendarIDs(
        catalog: [CalendarDescriptor],
        assignments: [CalendarID: CalendarRole]?
    ) -> Set<CalendarID> {
        Set(catalog.lazy.filter { role(for: $0.id, assignments: assignments) == .planning }.map(\.id))
    }
}
```

No title, event content, attendee, frequency, location, or model result appears in this API, so content cannot infer or mutate a role.

- [ ] **Step 5: Run GREEN tests and the package suite**

```zsh
domain_scratch="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-domain-green.XXXXXX")"
swift test --package-path DailyPlanner --scratch-path "$domain_scratch" --no-parallel
rm -rf "$domain_scratch"
```

Expected: all tests pass and `DailyPlannerDomain` imports only Foundation.

- [ ] **Step 6: Commit the eligibility boundary**

```zsh
git add DailyPlanner/Package.swift DailyPlanner/Sources/DailyPlannerDomain \
  DailyPlanner/Tests/DailyPlannerDomainTests/CalendarRolePolicyTests.swift
git commit -m "feat: add fail-closed calendar roles"
```

---

### Task 3: Deterministic priority, influence, and local schedule preview

**Files:**
- Create: `DailyPlanner/Sources/DailyPlannerDomain/PriorityEngine.swift`
- Create: `DailyPlanner/Sources/DailyPlannerDomain/PlanningPreview.swift`
- Create: `DailyPlanner/Sources/DailyPlannerDomain/LocalSchedulePolicy.swift`
- Create: `DailyPlanner/Tests/DailyPlannerDomainTests/PriorityEngineTests.swift`
- Create: `DailyPlanner/Tests/DailyPlannerDomainTests/PlanningInfluenceTests.swift`
- Create: `DailyPlanner/Tests/DailyPlannerDomainTests/LocalSchedulePolicyTests.swift`

**Interfaces:**
- Consumes: role-filtered `[PlannerEvent]` only.
- Produces: `PriorityEngine.ordered(_:)`, `PlanningPreview`, `PlanningInfluence`, `LocalSchedulePolicy.scanSlots(on:)`, `localDayInterval(containing:)`, and `MidnightSummaryEligibility`.

- [ ] **Step 1: Write failing school-first and advertisement-ignore tests**

```swift
func testSchoolAlwaysPrecedesCareerFinancePersonalAndOther() {
    let school = event("school", category: .school)
    let career = event("career", category: .career)
    let finance = event("finance", category: .finance)
    let personal = event("personal", category: .personal)
    let other = event("other", category: .other)
    let shuffled = [other, personal, finance, career, school]
    XCTAssertEqual(PriorityEngine().ordered(shuffled).map(\.category), [
        .school, .career, .finance, .personal, .other,
    ])
}

func testAdvertisementsNeverEnterTheQueue() {
    let school = event("school", category: .school)
    let advertisement = event("ad", category: .other, kind: .advertisement)
    let preview = PlanningPreview.build(
        eligibleEvents: [advertisement, school],
        now: Date(timeIntervalSince1970: 1_800_000_000)
    )
    XCTAssertEqual(preview.queue.map(\.id), [school.id])
    XCTAssertEqual(preview.schedule.map(\.id), [school.id])
    XCTAssertFalse(preview.allSourceIDs.contains(advertisement.id))
    XCTAssertFalse(preview.influence.contains(advertisement.id))
}

func testStableTieBreakUsesDueThenStartThenOpaqueID() {
    let earlierDue = event("due-first", category: .school, dueOffset: 60)
    let earlierID = event("a", category: .school, dueOffset: 120)
    let laterID = event("z", category: .school, dueOffset: 120)
    XCTAssertEqual(PriorityEngine().ordered([laterID, earlierDue, earlierID]).map(\.id), [
        earlierDue.id, earlierID.id, laterID.id,
    ])
}

private func event(
    _ id: String,
    category: PlannerCategory,
    kind: PlannerItemKind = .task,
    dueOffset: TimeInterval = 300
) -> PlannerEvent {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    return PlannerEvent(
        id: id,
        calendarID: .init(rawValue: "synthetic-calendar"),
        title: "Synthetic item",
        category: category,
        kind: kind,
        start: start,
        end: start.addingTimeInterval(1800),
        due: start.addingTimeInterval(dueOffset)
    )
}
```

- [ ] **Step 2: Write the failing influence-surface test**

Create one Planning event and one Excluded-reference event with unique synthetic canaries. Pass only the Planning event into `PlanningPreview.build` and assert that every influence set excludes the reference canary:

```swift
let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
let planning = event("planning-canary", category: .school)
let reference = event("reference-canary", category: .other)
let preview = PlanningPreview.build(eligibleEvents: [planning], now: fixedNow)
XCTAssertTrue(preview.influence.conflictSourceIDs.contains(planning.id))
XCTAssertTrue(preview.influence.freeBusySourceIDs.contains(planning.id))
XCTAssertTrue(preview.influence.workloadSourceIDs.contains(planning.id))
XCTAssertTrue(preview.influence.fatigueSourceIDs.contains(planning.id))
XCTAssertTrue(preview.influence.prioritySourceIDs.contains(planning.id))
XCTAssertTrue(preview.influence.digestSourceIDs.contains(planning.id))
XCTAssertTrue(preview.influence.summarySourceIDs.contains(planning.id))
XCTAssertFalse(preview.influence.conflictSourceIDs.contains(reference.id))
XCTAssertFalse(preview.influence.freeBusySourceIDs.contains(reference.id))
XCTAssertFalse(preview.influence.workloadSourceIDs.contains(reference.id))
XCTAssertFalse(preview.influence.fatigueSourceIDs.contains(reference.id))
XCTAssertFalse(preview.influence.prioritySourceIDs.contains(reference.id))
XCTAssertFalse(preview.influence.digestSourceIDs.contains(reference.id))
XCTAssertFalse(preview.influence.summarySourceIDs.contains(reference.id))
XCTAssertFalse(preview.influence.proposalContextSourceIDs.contains(reference.id))
XCTAssertFalse(preview.influence.assistantContextSourceIDs.contains(reference.id))
XCTAssertFalse(preview.influence.actionCandidateSourceIDs.contains(reference.id))
XCTAssertTrue(preview.influence.proposalContextSourceIDs.isEmpty)
XCTAssertTrue(preview.influence.assistantContextSourceIDs.isEmpty)
XCTAssertTrue(preview.influence.actionCandidateSourceIDs.isEmpty)
```

In M1, proposal, assistant, and action-candidate sets are empty for every event because those capabilities are absent.

- [ ] **Step 3: Write failing Vancouver schedule and midnight-eligibility tests**

```swift
func testScanSlotsAreSixNoonAndTwentyOneInVancouver() throws {
    let localSummerDay = localDate(year: 2026, month: 8, day: 30)
    let slots = try LocalSchedulePolicy.v1.scanSlots(on: localSummerDay)
    XCTAssertEqual(slots.map(localHour), [6, 12, 21])
}

func testSlotsRemainLocalAcrossSpringAndFallDSTDays() throws {
    let policy = LocalSchedulePolicy.v1
    let springTransitionDay = localDate(year: 2026, month: 3, day: 8)
    let fallTransitionDay = localDate(year: 2026, month: 11, day: 1)
    XCTAssertEqual(try policy.scanSlots(on: springTransitionDay).map(localHour), [6, 12, 21])
    XCTAssertEqual(try policy.scanSlots(on: fallTransitionDay).map(localHour), [6, 12, 21])
    XCTAssertEqual(policy.localDayInterval(containing: springTransitionDay).duration, 23 * 60 * 60)
    XCTAssertEqual(policy.localDayInterval(containing: fallTransitionDay).duration, 25 * 60 * 60)
}

func testMidnightSummaryIsEligibilityOnlyAndRequiresUsage() {
    let policy = LocalSchedulePolicy.v1
    XCTAssertEqual(policy.midnightEligibility(usageSincePreviousMidnight: false, eligibleSourceCount: 3), .ineligible(.noUsage))
    XCTAssertEqual(policy.midnightEligibility(usageSincePreviousMidnight: true, eligibleSourceCount: 0), .ineligible(.noEligibleSources))
    XCTAssertEqual(policy.midnightEligibility(usageSincePreviousMidnight: true, eligibleSourceCount: 3), .eligible(sourceCount: 3))
}

private func localDate(year: Int, month: Int, day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Vancouver")!
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}

private func localHour(_ date: Date) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Vancouver")!
    return calendar.component(.hour, from: date)
}
```

- [ ] **Step 4: Observe RED, then implement the minimal policies**

Run the three new test classes and confirm missing-type compile failures. Implement the stable comparator without a floating-point score:

```swift
public struct PriorityEngine: Sendable {
    public init() {}

    public func ordered(_ events: [PlannerEvent]) -> [PlannerEvent] {
        events
            .filter { $0.kind != .advertisement }
            .sorted {
                if $0.category.rawValue != $1.category.rawValue {
                    return $0.category.rawValue < $1.category.rawValue
                }
                if $0.due != $1.due {
                    return ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture)
                }
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.id < $1.id
            }
    }
}
```

`LocalSchedulePolicy.v1` owns `TimeZone(identifier: "America/Vancouver")!` and derives calendar dates with `Calendar.date(bySettingHour:minute:second:of:)`; it never installs timers or performs I/O. `PlanningPreview.build` derives influence only from its `eligibleEvents` argument and returns no action type.

Use these exact public result contracts so every exclusion surface is visible to tests:

```swift
public struct PlanningInfluence: Equatable, Sendable {
    public let conflictSourceIDs: Set<String>
    public let freeBusySourceIDs: Set<String>
    public let workloadSourceIDs: Set<String>
    public let fatigueSourceIDs: Set<String>
    public let prioritySourceIDs: Set<String>
    public let digestSourceIDs: Set<String>
    public let summarySourceIDs: Set<String>
    public let proposalContextSourceIDs: Set<String>
    public let assistantContextSourceIDs: Set<String>
    public let actionCandidateSourceIDs: Set<String>

    public func contains(_ id: String) -> Bool {
        [conflictSourceIDs, freeBusySourceIDs, workloadSourceIDs, fatigueSourceIDs,
         prioritySourceIDs, digestSourceIDs, summarySourceIDs, proposalContextSourceIDs,
         assistantContextSourceIDs, actionCandidateSourceIDs].contains { $0.contains(id) }
    }
}

public struct PlanningPreview: Equatable, Sendable {
    public let queue: [PlannerEvent]
    public let schedule: [PlannerEvent]
    public let influence: PlanningInfluence
    public var allSourceIDs: Set<String> { Set(queue.map(\.id) + schedule.map(\.id)) }
    public static let empty = PlanningPreview.build(
        eligibleEvents: [],
        now: Date(timeIntervalSince1970: 0)
    )

    public static func build(eligibleEvents: [PlannerEvent], now: Date) -> PlanningPreview {
        let ordered = PriorityEngine().ordered(eligibleEvents)
        let ids = Set(ordered.map(\.id))
        return PlanningPreview(
            queue: ordered,
            schedule: ordered.sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.id < $1.id
            },
            influence: PlanningInfluence(
                conflictSourceIDs: ids,
                freeBusySourceIDs: ids,
                workloadSourceIDs: ids,
                fatigueSourceIDs: ids,
                prioritySourceIDs: ids,
                digestSourceIDs: ids,
                summarySourceIDs: ids,
                proposalContextSourceIDs: [],
                assistantContextSourceIDs: [],
                actionCandidateSourceIDs: []
            )
        )
    }
}

public enum MidnightSummaryIneligibleReason: Equatable, Sendable { case noUsage, noEligibleSources }
public enum MidnightSummaryEligibility: Equatable, Sendable {
    case eligible(sourceCount: Int)
    case ineligible(MidnightSummaryIneligibleReason)
}

public enum LocalScheduleError: Equatable, Error, Sendable {
    case invalidLocalDay
}

public struct LocalSchedulePolicy: Sendable {
    public static let v1 = LocalSchedulePolicy(timeZone: TimeZone(identifier: "America/Vancouver")!)
    public let timeZone: TimeZone

    public func scanSlots(on localDay: Date) throws -> [Date]
    public func localDayInterval(containing date: Date) -> DateInterval
    public func midnightEligibility(
        usageSincePreviousMidnight: Bool,
        eligibleSourceCount: Int
    ) -> MidnightSummaryEligibility
}
```

`midnightEligibility` checks `usageSincePreviousMidnight` first, then requires `eligibleSourceCount > 0`. `scanSlots` throws the finite `LocalScheduleError.invalidLocalDay` if any local component cannot be constructed. `localDayInterval` uses the same Vancouver calendar, `startOfDay(for:)`, and `date(byAdding: .day, value: 1, to:)`; its unreachable calendar-add failure falls back to a one-second empty-safe interval rather than forcing a crash. DST tests make the normal 23/25-hour behavior observable.

- [ ] **Step 5: Run all domain tests GREEN**

```zsh
policy_scratch="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-policy-green.XXXXXX")"
swift test --package-path DailyPlanner --scratch-path "$policy_scratch" --no-parallel \
  --filter DailyPlannerDomainTests
rm -rf "$policy_scratch"
```

Expected: priority permutation, exclusion truth table, DST, and midnight eligibility tests all pass.

- [ ] **Step 6: Commit deterministic planning policy**

```zsh
git add DailyPlanner/Sources/DailyPlannerDomain DailyPlanner/Tests/DailyPlannerDomainTests
git commit -m "feat: add deterministic planning preview"
```

---

### Task 4: Encrypted private settings and exact Keychain key

**Files:**
- Modify: `DailyPlanner/Package.swift`
- Create: `DailyPlanner/Sources/DailyPlannerDomain/PrivateSettings.swift`
- Create: `DailyPlanner/Sources/DailyPlannerDomain/PrivateSettingsStore.swift`
- Create: `DailyPlanner/Sources/DailyPlannerPersistence/EncryptedEnvelope.swift`
- Create: `DailyPlanner/Sources/DailyPlannerPersistence/SettingsKeychain.swift`
- Create: `DailyPlanner/Sources/DailyPlannerPersistence/EncryptedPrivateSettingsStore.swift`
- Create: `DailyPlanner/Tests/DailyPlannerPersistenceTests/EncryptedPrivateSettingsStoreTests.swift`
- Create: `DailyPlanner/Tests/DailyPlannerPersistenceTests/SettingsKeychainTests.swift`

**Interfaces:**
- Consumes: `CalendarID`, `CalendarRole`, exact app-private storage URL, and 32-byte key material.
- Produces: `PrivateSettings`, `CalendarRoleAuditEntry`, `PrivateSettingsStore`, `SettingsKeyMaterialProviding`, and an authenticated AES-GCM file containing no plaintext private values.

- [ ] **Step 1: Write failing encrypted round-trip, tamper, and plaintext-absence tests**

```swift
func testEncryptedStoreRoundTripsWithoutPlaintextIdentifiersOrBookmark() throws {
    let key = Data(repeating: 0x2A, count: 32)
    let store = makeStore(key: key)
    let calendarID = CalendarID(rawValue: "synthetic-private-calendar")
    let settings = PrivateSettings(
        vaultBookmark: Data("synthetic-bookmark-canary".utf8),
        calendarRoles: [calendarID: .planning],
        calendarRoleAudit: [CalendarRoleAuditEntry(
            calendarID: calendarID,
            oldRole: .excludedReference,
            newRole: .planning,
            actor: .localUser,
            changedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )]
    )

    try store.replace(settings)
    XCTAssertEqual(try store.load(), settings)
    let bytes = try Data(contentsOf: envelopeURL)
    XCTAssertNil(bytes.range(of: Data("synthetic-bookmark-canary".utf8)))
    XCTAssertNil(bytes.range(of: Data("synthetic-private-calendar".utf8)))
    XCTAssertNil(bytes.range(of: Data("localUser".utf8)))
}

func testTamperedEnvelopeFailsClosedWithoutReturningPartialSettings() throws {
    let store = makeStore(key: Data(repeating: 0x2A, count: 32))
    let settings = PrivateSettings(
        vaultBookmark: nil,
        calendarRoles: [.init(rawValue: "synthetic-private-calendar"): .planning],
        calendarRoleAudit: []
    )
    try store.replace(settings)
    try flipOneCiphertextByte(at: envelopeURL)
    XCTAssertThrowsError(try store.load()) { error in
        XCTAssertEqual(error as? PrivateSettingsStoreError, .authenticationFailed)
    }
}

func testMissingFileReturnsEmptyExcludedByDefaultSettingsWithoutCreatingAKey() throws {
    let keyProvider = RecordingKeyProvider(existing: nil)
    let store = EncryptedPrivateSettingsStore(storageURL: envelopeURL, keyProvider: keyProvider)
    XCTAssertEqual(try store.load(), .empty)
    XCTAssertEqual(keyProvider.readCount, 0)
}
```

The test class owns a generated `temporaryRoot`, sets `envelopeURL = temporaryRoot.appending(path: "settings.envelope")`, and removes exactly that root in `tearDown`. It defines `makeStore(key:) -> EncryptedPrivateSettingsStore`; that helper constructs the real store with `RecordingKeyProvider(existing: key)`. `flipOneCiphertextByte(at:)` decodes `EncryptedEnvelope`, flips the middle byte of `sealedBox`, and atomically rewrites the envelope. These helpers remain in the test target.

```swift
final class RecordingKeyProvider: SettingsKeyMaterialProviding, @unchecked Sendable {
    init(existing: Data?)
    func existingKeyMaterial() throws -> Data?
    func keyMaterialForWrite() throws -> Data
    var readCount: Int { get }
    var writeCount: Int { get }
}
```

The key-provider fake uses `NSLock`; `keyMaterialForWrite` returns the configured 32-byte value or throws `.keyUnavailable` when it is nil.

- [ ] **Step 2: Write failing exact Keychain-query tests against a recording backend**

Assert every match query contains the fixed base identity:

```swift
[
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "DailyPlanner.PrivateSettings.v1",
    kSecAttrAccount as String: "envelope-key",
    kSecUseDataProtectionKeychain as String: true,
    kSecAttrSynchronizable as String: false,
]
```

The add attributes also contain `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; read adds only return-data/match-limit keys; update supplies only the new 32-byte value; delete uses only the base identity. No operation has an access group, a label containing a path, or dynamic account/service input.

Use this exact internal Security seam and finite test snapshot. Production forwards directly to the four `SecItem*` functions; unit tests inject the recording caller and never touch the real Keychain:

```swift
protocol KeychainCalling: Sendable {
    func copyMatching(
        _ query: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus
    func add(
        _ attributes: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

enum KeychainSnapshotValue: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case integer(Int)
    case dataLength(Int)
}

struct KeychainQuerySnapshot: Equatable, Sendable {
    let values: [String: KeychainSnapshotValue]
}

enum RecordedKeychainCall: Equatable, Sendable {
    case copy(KeychainQuerySnapshot)
    case add(KeychainQuerySnapshot)
    case update(match: KeychainQuerySnapshot, attributes: KeychainQuerySnapshot)
    case delete(KeychainQuerySnapshot)
}

final class RecordingKeychainCaller: KeychainCalling, @unchecked Sendable {
    init(
        copyStatus: OSStatus = errSecItemNotFound,
        copyData: Data? = nil,
        mutationStatus: OSStatus = errSecSuccess
    )

    func recordedCalls() -> [RecordedKeychainCall]
    func copyMatching(
        _ query: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus
    func add(
        _ attributes: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}
```

`RecordingKeychainCaller` protects its call array with `NSLock`, snapshots only the finite String/Bool/Int/Data values above, records Data length rather than bytes, and preconditions on an unexpected value type. When `copyStatus == errSecSuccess`, it retains `copyData` as `CFData` into the supplied result pointer. Its tests compare the exact operation sequence and query snapshots, including a 32-byte update, so there is no stringified or lossy query assertion.

- [ ] **Step 3: Observe RED and add the private-settings schema**

```swift
public enum CalendarRoleChangeActor: String, Codable, Hashable, Sendable {
    case localUser
}

public struct CalendarRoleAuditEntry: Codable, Equatable, Sendable {
    public let calendarID: CalendarID
    public let oldRole: CalendarRole
    public let newRole: CalendarRole
    public let actor: CalendarRoleChangeActor
    public let changedAt: Date

    public init(
        calendarID: CalendarID,
        oldRole: CalendarRole,
        newRole: CalendarRole,
        actor: CalendarRoleChangeActor,
        changedAt: Date
    ) {
        self.calendarID = calendarID
        self.oldRole = oldRole
        self.newRole = newRole
        self.actor = actor
        self.changedAt = changedAt
    }
}

public struct PrivateSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion = currentSchemaVersion
    public var vaultBookmark: Data?
    public var calendarRoles: [CalendarID: CalendarRole]
    public var calendarRoleAudit: [CalendarRoleAuditEntry]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        vaultBookmark: Data?,
        calendarRoles: [CalendarID: CalendarRole],
        calendarRoleAudit: [CalendarRoleAuditEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.vaultBookmark = vaultBookmark
        self.calendarRoles = calendarRoles
        self.calendarRoleAudit = calendarRoleAudit
    }

    public static let empty = PrivateSettings(
        vaultBookmark: nil,
        calendarRoles: [:],
        calendarRoleAudit: []
    )
}

public protocol PrivateSettingsReading: Sendable {
    func load() throws -> PrivateSettings
}

public protocol PrivateSettingsWriting: Sendable {
    func replace(_ settings: PrivateSettings) throws
}

public protocol PrivateSettingsStore: PrivateSettingsReading, PrivateSettingsWriting {}

public enum PrivateSettingsStoreError: Equatable, Error, Sendable {
    case keyUnavailable
    case readFailed
    case authenticationFailed
    case unsupportedSchema
    case writeFailed
}

public protocol SettingsKeyMaterialProviding: Sendable {
    func existingKeyMaterial() throws -> Data?
    func keyMaterialForWrite() throws -> Data
}

public enum SettingsKeychainError: Equatable, Error, Sendable {
    case unavailable
    case invalidLength
    case randomGenerationFailed
}
```

Add the persistence product and targets to `Package.swift`:

```swift
.library(name: "DailyPlannerPersistence", targets: ["DailyPlannerPersistence"]),

.target(name: "DailyPlannerPersistence", dependencies: ["DailyPlannerDomain"]),
.testTarget(
    name: "DailyPlannerPersistenceTests",
    dependencies: ["DailyPlannerDomain", "DailyPlannerPersistence"]
),
```

- [ ] **Step 4: Implement authenticated encryption and atomic replacement**

```swift
public struct EncryptedEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let algorithm: String
    public let keyVersion: Int
    public let sealedBox: Data
}
```

`EncryptedPrivateSettingsStore.replace` JSON-encodes `PrivateSettings`, seals it with `AES.GCM.seal`, encodes only `EncryptedEnvelope(schemaVersion: 1, algorithm: "AES.GCM.256", keyVersion: 1, sealedBox: combined)`, and writes with `.atomic`. `load` returns `.empty` when the exact file is absent; otherwise it obtains the exact key, authenticates before decoding, requires schema/version/algorithm equality, and maps every failure to a finite `PrivateSettingsStoreError` without retaining the underlying error text.

Its testable initializer is exact:

```swift
public init(storageURL: URL, keyProvider: any SettingsKeyMaterialProviding)
```

Production storage is exactly `Application Support/DailyPlanner/private-settings-v1.envelope`; creation targets only `Application Support/DailyPlanner`. Tests inject a temporary exact URL.

Expose a nonthrowing `EncryptedPrivateSettingsStore.production()` factory that calculates only that exact URL and constructs `SettingsKeychain`; it does not create the directory, file, or key until `replace` is called. `load` on a missing file returns `.empty` before consulting Keychain.

- [ ] **Step 5: Implement the exact data-protection Keychain adapter**

`SettingsKeychain` generates 32 bytes with `SecRandomCopyBytes` only when `replace` first needs a key. It uses the fixed service/account and the attributes above. It never prints `OSStatus`, key bytes, queries, or paths. Missing, denied, duplicate, corrupt-length, and deletion outcomes map to finite cases.

`public init()` is the only production initializer and fixes the service/account internally. The test target uses `internal init(caller: any KeychainCalling)` and `internal func deleteKeyMaterial() throws`, not alternate service/account strings. `deleteKeyMaterial` is used by the future reset workflow and exact-query tests; it is not added to `SettingsKeyMaterialProviding` and is not invoked by M1 UI.

- [ ] **Step 6: Run persistence GREEN tests and the full suite**

```zsh
persistence_scratch="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-persistence-green.XXXXXX")"
swift test --package-path DailyPlanner --scratch-path "$persistence_scratch" --no-parallel
rm -rf "$persistence_scratch"
```

Expected: encryption, tamper, no-plaintext, missing-file, and exact-query tests pass with no real Keychain items created by unit tests.

- [ ] **Step 7: Commit encrypted settings**

```zsh
git add DailyPlanner/Package.swift DailyPlanner/Sources/DailyPlannerDomain/PrivateSettings.swift \
  DailyPlanner/Sources/DailyPlannerDomain/PrivateSettingsStore.swift \
  DailyPlanner/Sources/DailyPlannerPersistence DailyPlanner/Tests/DailyPlannerPersistenceTests
git commit -m "feat: encrypt private planner settings"
```

---

### Task 5: Explicit vault-root onboarding without vault access

**Files:**
- Modify: `DailyPlanner/Package.swift`
- Create: `DailyPlanner/Sources/DailyPlannerApplication/VaultOnboardingWorkflow.swift`
- Create: `DailyPlanner/Sources/DailyPlannerPlatform/MacVaultFolderPicker.swift`
- Create: `DailyPlanner/Tests/DailyPlannerApplicationTests/VaultOnboardingWorkflowTests.swift`
- Create: `DailyPlanner/Tests/DailyPlannerApplicationTests/TestSupport.swift`
- Create: `DailyPlanner/Tests/DailyPlannerPlatformTests/MacVaultFolderPickerTests.swift`

**Interfaces:**
- Consumes: explicit user intent, `VaultFolderSelecting`, and `PrivateSettingsStore`.
- Produces: encrypted persistence of one opaque bookmark plus finite `VaultOnboardingState`; no URL/path or vault-content operation crosses the workflow boundary.

- [ ] **Step 1: Write failing workflow tests**

```swift
@MainActor
func testSelectionRunsOnlyAfterExplicitUserIntentAndPersistsOnlyBookmark() async {
    let picker = RecordingFolderPicker(result: .success(Data("opaque-bookmark".utf8)))
    let store = RecordingSettingsStore(initial: .empty)
    let workflow = VaultOnboardingWorkflow(picker: picker, settingsStore: store)

    XCTAssertEqual(picker.callCount, 0)
    XCTAssertEqual(store.replaceCount, 0)

    let result = await workflow.chooseVaultRoot()
    XCTAssertEqual(result, .selected)
    XCTAssertEqual(picker.callCount, 1)
    XCTAssertEqual(store.lastReplacement?.vaultBookmark, Data("opaque-bookmark".utf8))
}

@MainActor
func testCancellationLeavesExistingSettingsUnchanged() async {
    let store = RecordingSettingsStore(initial: .empty)
    let picker = RecordingFolderPicker(result: .success(nil))
    let workflow = VaultOnboardingWorkflow(picker: picker, settingsStore: store)
    let result = await workflow.chooseVaultRoot()
    XCTAssertEqual(result, .cancelled)
    XCTAssertEqual(store.replaceCount, 0)
}

@MainActor
func testPickerFailureReturnsFiniteStateWithoutRawErrorOrPath() async {
    let store = RecordingSettingsStore(initial: .empty)
    let picker = RecordingFolderPicker(result: .failure(.injected))
    let workflow = VaultOnboardingWorkflow(picker: picker, settingsStore: store)
    let result = await workflow.chooseVaultRoot()
    XCTAssertEqual(result, .failed(.selectionUnavailable))
    XCTAssertEqual(store.replaceCount, 0)
}
```

- [ ] **Step 2: Observe RED and define the narrow picker port**

```swift
public protocol VaultFolderSelecting: Sendable {
    @MainActor func selectRootBookmark() async throws -> Data?
}

public enum VaultOnboardingState: Equatable, Sendable {
    case notSelected
    case selected
    case cancelled
    case failed(VaultOnboardingFailure)
}

public enum VaultOnboardingFailure: Equatable, Sendable {
    case selectionUnavailable
    case settingsUnavailable
}

public struct VaultOnboardingWorkflow: Sendable {
    private let picker: any VaultFolderSelecting
    private let settingsStore: any PrivateSettingsStore

    public init(
        picker: any VaultFolderSelecting,
        settingsStore: any PrivateSettingsStore
    ) {
        self.picker = picker
        self.settingsStore = settingsStore
    }

    @MainActor
    public func chooseVaultRoot() async -> VaultOnboardingState
}
```

`nil` means user cancellation. No URL, display path, filename, or error string leaves the platform adapter.

Add these products and targets to `Package.swift`:

```swift
.library(name: "DailyPlannerApplication", targets: ["DailyPlannerApplication"]),
.library(name: "DailyPlannerPlatform", targets: ["DailyPlannerPlatform"]),

.target(name: "DailyPlannerApplication", dependencies: ["DailyPlannerDomain"]),
.target(
    name: "DailyPlannerPlatform",
    dependencies: ["DailyPlannerDomain", "DailyPlannerApplication"]
),
.testTarget(
    name: "DailyPlannerApplicationTests",
    dependencies: ["DailyPlannerDomain", "DailyPlannerApplication"]
),
.testTarget(
    name: "DailyPlannerPlatformTests",
    dependencies: ["DailyPlannerDomain", "DailyPlannerApplication", "DailyPlannerPlatform"]
),
```

- [ ] **Step 3: Implement the application workflow**

`chooseVaultRoot` calls the picker exactly once, loads settings, replaces only `vaultBookmark`, and persists the full encrypted record. It performs no eager validation, bookmark resolution, directory read, or summary creation. Store/picker errors become finite failure enums.

`TestSupport.swift` contains these exact reusable seams. The settings fake guards all mutable state with `NSLock`; the picker is main-actor isolated because its production port is main-actor isolated:

```swift
enum TestStoreMode: Sendable { case working, failLoad, failReplace }
enum TestFixtureError: Error, Sendable { case injected }

final class RecordingSettingsStore: PrivateSettingsStore, @unchecked Sendable {
    init(initial: PrivateSettings, mode: TestStoreMode = .working)
    func load() throws -> PrivateSettings
    func replace(_ settings: PrivateSettings) throws
    var replaceCount: Int { get }
    var lastReplacement: PrivateSettings? { get }
}

@MainActor
final class RecordingFolderPicker: VaultFolderSelecting, @unchecked Sendable {
    init(result: Result<Data?, TestFixtureError>)
    private(set) var callCount: Int
    func selectRootBookmark() async throws -> Data?
}
```

Implement `chooseVaultRoot` as two explicit error boundaries: picker throw → `.failed(.selectionUnavailable)`; `nil` → `.cancelled`; settings load/replace throw → `.failed(.settingsUnavailable)`; successful replacement → `.selected`. Do not use a single catch that can misclassify storage failure as picker failure.

- [ ] **Step 4: Implement the macOS folder picker**

```swift
public struct MacVaultFolderPicker: VaultFolderSelecting, Sendable {
    private let selectURL: @MainActor @Sendable () -> URL?

    public init() {
        self.selectURL = {
            let panel = NSOpenPanel()
            panel.title = "Choose your Obsidian vault root"
            panel.message = "Choose the folder that contains your Obsidian vault. Daily Planner will remember permission but will not read or write it in M1."
            panel.prompt = "Choose Vault Root"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = false
            panel.resolvesAliases = false
            panel.showsHiddenFiles = false
            return panel.runModal() == .OK ? panel.url : nil
        }
    }

    init(selectURL: @escaping @MainActor @Sendable () -> URL?) {
        self.selectURL = selectURL
    }

    @MainActor
    public func selectRootBookmark() async throws -> Data? {
        guard let url = selectURL() else { return nil }
        return try url.bookmarkData(options: [.withSecurityScope])
    }
}
```

The production picker closure contains the complete panel configuration shown above. The file contains no `startAccessingSecurityScopedResource`, `resolvingBookmarkData`, `contentsOfDirectory`, `Data(contentsOf:)`, `NSFileCoordinator`, or write call. Do not inspect `.obsidian/`; the explanatory copy tells the user which root to choose.

- [ ] **Step 5: Test the platform adapter only with a generated directory**

Use the internal `selectURL` initializer for deterministic cancel/selected outcomes. The selected fixture URL is a newly generated empty temporary directory. Record its attributes before and after bookmark creation, assert bookmark bytes are nonempty and attributes are unchanged, then remove that exact fixture directory. The focused code review confirms the adapter has no content-read or write API; do not invent a filesystem counter that the production boundary cannot observe.

- [ ] **Step 6: Run GREEN tests and commit**

```zsh
vault_scratch="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-vault-green.XXXXXX")"
swift test --package-path DailyPlanner --scratch-path "$vault_scratch" --no-parallel \
  --filter VaultOnboardingWorkflowTests
swift test --package-path DailyPlanner --scratch-path "$vault_scratch" --no-parallel \
  --filter MacVaultFolderPickerTests
rm -rf "$vault_scratch"
git add DailyPlanner/Package.swift DailyPlanner/Sources/DailyPlannerApplication \
  DailyPlanner/Sources/DailyPlannerPlatform/MacVaultFolderPicker.swift \
  DailyPlanner/Tests/DailyPlannerApplicationTests/VaultOnboardingWorkflowTests.swift \
  DailyPlanner/Tests/DailyPlannerPlatformTests/MacVaultFolderPickerTests.swift
git commit -m "feat: add vault permission onboarding"
```

---

### Task 6: Synthetic read-only calendars and planning workflows

**Files:**
- Create: `DailyPlanner/Sources/DailyPlannerApplication/CalendarRoleWorkflow.swift`
- Create: `DailyPlanner/Sources/DailyPlannerApplication/PlanningPreviewWorkflow.swift`
- Create: `DailyPlanner/Sources/DailyPlannerApplication/ReferenceCalendarWorkflow.swift`
- Create: `DailyPlanner/Sources/DailyPlannerPlatform/M1SyntheticCalendarSource.swift`
- Create: `DailyPlanner/Sources/DailyPlannerPlatform/SystemClock.swift`
- Create: `DailyPlanner/Tests/DailyPlannerApplicationTests/CalendarRoleWorkflowTests.swift`
- Create: `DailyPlanner/Tests/DailyPlannerApplicationTests/PlanningPreviewWorkflowTests.swift`
- Create: `DailyPlanner/Tests/DailyPlannerApplicationTests/ReferenceCalendarWorkflowTests.swift`
- Modify: `DailyPlanner/Tests/DailyPlannerApplicationTests/TestSupport.swift`
- Create: `DailyPlanner/Tests/DailyPlannerPlatformTests/M1SyntheticCalendarSourceTests.swift`

**Interfaces:**
- Consumes: encrypted settings, synthetic calendar catalog/events, role policy, priority/schedule policy.
- Produces: `CalendarRoleWorkflow.setRole`, `PlanningPreviewWorkflow.refresh`, `ReferenceCalendarWorkflow.view`, `SystemClock.now`, and a deterministic offline catalog with no network or credential dependency.

Use these exact public workflow signatures:

```swift
public struct CalendarRoleWorkflow: Sendable {
    public init(
        settingsStore: any PrivateSettingsStore,
        catalogReader: any CalendarCatalogReading
    )
    public func rows() async throws -> [CalendarRoleRow]
    public func role(for calendarID: CalendarID) throws -> CalendarRole
    public func setRole(
        _ role: CalendarRole,
        for calendarID: CalendarID,
        at changedAt: Date
    ) throws -> CalendarRoleChangeResult
}

public struct CalendarRoleRow: Equatable, Sendable {
    public let calendarID: CalendarID
    public let displayName: String
    public let role: CalendarRole

    public init(calendarID: CalendarID, displayName: String, role: CalendarRole)
}

public struct PlanningPreviewWorkflow: Sendable {
    public init(
        catalogReader: any CalendarCatalogReading,
        planningReader: any PlanningCalendarReading,
        settingsReader: any PrivateSettingsReading,
        clock: any PlannerClock
    )
    public func refresh(interval: DateInterval) async throws -> PlanningPreview
}

public struct ReferenceCalendarWorkflow: Sendable {
    public init(
        referenceReader: any ExcludedReferenceViewing,
        settingsReader: any PrivateSettingsReading
    )
    public func view(
        calendarID: CalendarID,
        interval: DateInterval
    ) async throws -> ReferenceCalendarView
}
```

- [ ] **Step 1: Write the failing end-to-end exclusion test**

```swift
func testRefreshRequestsOnlyPlanningIDsAndExcludedCanaryInfluencesNothing() async throws {
    let source = RecordingCalendarSource(
        catalog: [planningCalendar, referenceCalendar],
        events: [planningEvent, referenceCanaryEvent]
    )
    let settings = PrivateSettings(
        vaultBookmark: nil,
        calendarRoles: [planningCalendar.id: .planning, referenceCalendar.id: .excludedReference],
        calendarRoleAudit: []
    )
    let store = RecordingSettingsStore(initial: settings)
    let workflow = PlanningPreviewWorkflow(
        catalogReader: source,
        planningReader: source,
        settingsReader: store,
        clock: FixedClock(now: fixedNow)
    )
    let preview = try await workflow.refresh(interval: interval)

    XCTAssertEqual(source.requestedPlanningIDs, Set([planningCalendar.id]))
    XCTAssertFalse(preview.allSourceIDs.contains(referenceCanaryEvent.id))
    XCTAssertFalse(preview.influence.contains(referenceCanaryEvent.id))
    XCTAssertFalse(preview.queue.map(\.id).contains(referenceCanaryEvent.id))
}

func testUnreadableSettingsFailsClosedBeforeAnyPlanningRead() async {
    let source = RecordingCalendarSource(catalog: [planningCalendar], events: [planningEvent])
    let store = RecordingSettingsStore(initial: .empty, mode: .failLoad)
    let workflow = PlanningPreviewWorkflow(
        catalogReader: source,
        planningReader: source,
        settingsReader: store,
        clock: FixedClock(now: fixedNow)
    )

    do {
        _ = try await workflow.refresh(interval: interval)
        XCTFail("Expected settingsUnavailable")
    } catch {
        XCTAssertEqual(error as? PlanningWorkflowError, .settingsUnavailable)
    }
    XCTAssertEqual(source.planningReadCallCount, 0)
}
```

The test files declare `planningCalendar`, `referenceCalendar`, `unknownCalendar`, `planningEvent`, `referenceCanaryEvent`, `interval`, and `fixedNow` as immutable synthetic fixture properties constructed directly from the Task 2 public initializers. `TestSupport.swift` adds these exact thread-safe fixtures:

```swift
struct FixedClock: PlannerClock, Sendable {
    let now: Date
}

final class RecordingCalendarSource:
    CalendarCatalogReading,
    PlanningCalendarReading,
    ExcludedReferenceViewing,
    @unchecked Sendable
{
    init(catalog: [CalendarDescriptor], events: [PlannerEvent])
    func calendars() async throws -> [CalendarDescriptor]
    func planningEvents(
        calendarIDs: Set<CalendarID>,
        interval: DateInterval
    ) async throws -> [PlannerEvent]
    func referenceEvents(
        calendarID: CalendarID,
        interval: DateInterval
    ) async throws -> [PlannerEvent]
    func replaceTitle(with title: String, for eventID: String)
    var requestedPlanningIDs: Set<CalendarID> { get }
    var planningReadCallCount: Int { get }
}
```

`RecordingCalendarSource` protects its arrays and counters with `NSLock`. Its planning method records the requested identifiers but deliberately returns its full configured event array; the production workflow must perform the defensive second filter. Its reference method returns only events for the requested calendar.

`PlanningInfluence.contains` checks every influence field, including conflict, free/busy, workload, fatigue, priority, digest, summary, proposal, assistant, and action-candidate sets.

For this test only, `RecordingCalendarSource` records `requestedPlanningIDs` but deliberately returns both fixture events. That proves the application workflow's defensive calendar-ID check catches an adapter regression instead of trusting the reader blindly.

- [ ] **Step 2: Write failing manual-view isolation and role-change tests**

```swift
func testManualReferenceViewDoesNotPersistOrRefreshPlanningState() async throws {
    let store = RecordingSettingsStore(initial: PrivateSettings(
        vaultBookmark: nil,
        calendarRoles: [referenceCalendar.id: .excludedReference],
        calendarRoleAudit: []
    ))
    let source = RecordingCalendarSource(
        catalog: [referenceCalendar],
        events: [referenceCanaryEvent]
    )
    let workflow = ReferenceCalendarWorkflow(referenceReader: source, settingsReader: store)
    let view = try await workflow.view(calendarID: referenceCalendar.id, interval: interval)
    XCTAssertEqual(view.events.map(\.id), [referenceCanaryEvent.id])
    XCTAssertEqual(store.replaceCount, 0)
    XCTAssertEqual(source.planningReadCallCount, 0)
}

func testRoleChangeAppendsEncryptedAuditAndInvalidatesPreview() throws {
    let store = RecordingSettingsStore(initial: PrivateSettings(
        vaultBookmark: nil,
        calendarRoles: [planningCalendar.id: .planning],
        calendarRoleAudit: []
    ))
    let source = RecordingCalendarSource(catalog: [planningCalendar], events: [planningEvent])
    let workflow = CalendarRoleWorkflow(settingsStore: store, catalogReader: source)
    let result = try workflow.setRole(.excludedReference, for: planningCalendar.id, at: fixedNow)
    XCTAssertEqual(result, .saved(requiresValidatedRefresh: true))
    XCTAssertEqual(store.lastReplacement?.calendarRoleAudit.last?.newRole, .excludedReference)
    XCTAssertEqual(store.lastReplacement?.calendarRoleAudit.last?.actor, .localUser)
}
```

Add these exact cases to the same files:

```swift
func testUnknownCalendarIsReportedAsExcludedReference() throws {
    let store = RecordingSettingsStore(initial: .empty)
    let source = RecordingCalendarSource(catalog: [], events: [])
    let workflow = CalendarRoleWorkflow(settingsStore: store, catalogReader: source)
    XCTAssertEqual(try workflow.role(for: unknownCalendar.id), .excludedReference)
}

func testSettingsRowsLoadCatalogInMemoryAndDefaultMissingRoleToExcluded() async throws {
    let store = RecordingSettingsStore(initial: .empty)
    let source = RecordingCalendarSource(catalog: [referenceCalendar], events: [])
    let workflow = CalendarRoleWorkflow(settingsStore: store, catalogReader: source)
    let rows = try await workflow.rows()
    XCTAssertEqual(rows, [CalendarRoleRow(
        calendarID: referenceCalendar.id,
        displayName: referenceCalendar.displayName,
        role: .excludedReference
    )])
    XCTAssertEqual(store.replaceCount, 0)
}

func testEventContentCannotChangeStoredRole() throws {
    let store = RecordingSettingsStore(initial: PrivateSettings(
        vaultBookmark: nil,
        calendarRoles: [referenceCalendar.id: .excludedReference],
        calendarRoleAudit: []
    ))
    let source = RecordingCalendarSource(catalog: [referenceCalendar], events: [referenceCanaryEvent])
    let workflow = CalendarRoleWorkflow(settingsStore: store, catalogReader: source)
    let before = try workflow.role(for: referenceCalendar.id)
    source.replaceTitle(with: "Synthetic planning-like title", for: referenceCanaryEvent.id)
    XCTAssertEqual(try workflow.role(for: referenceCalendar.id), before)
}

func testChangingToPlanningRequiresASeparateValidatedRefresh() throws {
    let store = RecordingSettingsStore(initial: PrivateSettings(
        vaultBookmark: nil,
        calendarRoles: [referenceCalendar.id: .excludedReference],
        calendarRoleAudit: []
    ))
    let source = RecordingCalendarSource(catalog: [referenceCalendar], events: [referenceCanaryEvent])
    let workflow = CalendarRoleWorkflow(settingsStore: store, catalogReader: source)
    let existingPreview = PlanningPreview.build(eligibleEvents: [], now: fixedNow)
    XCTAssertEqual(
        try workflow.setRole(.planning, for: referenceCalendar.id, at: fixedNow),
        .saved(requiresValidatedRefresh: true)
    )
    XCTAssertFalse(existingPreview.allSourceIDs.contains(referenceCanaryEvent.id))
}
```

- [ ] **Step 3: Observe RED and implement workflow ordering**

`PlanningPreviewWorkflow.refresh` must execute this exact sequence:

```swift
let catalog = try await catalogReader.calendars()
let settings = try settingsReader.load()
let planningIDs = CalendarRolePolicy.planningCalendarIDs(
    catalog: catalog,
    assignments: settings.calendarRoles
)
let returnedEvents = try await planningReader.planningEvents(
    calendarIDs: planningIDs,
    interval: interval
)
let eligibleEvents = returnedEvents.filter { planningIDs.contains($0.calendarID) }
return PlanningPreview.build(eligibleEvents: eligibleEvents, now: clock.now)
```

Its initializer accepts `settingsReader: any PrivateSettingsReading`. The production reader is queried with Planning identifiers only, and the workflow defensively rejects any returned event whose `calendarID` is outside that set before any aggregation. It never intentionally requests a raw mixed-role stream. This call ordering plus the defensive check is the structural privacy boundary.

- [ ] **Step 4: Implement role changes and reference viewing**

`CalendarRoleWorkflow.rows` loads the memory-only catalog and encrypted assignments, maps missing assignments to Excluded reference, and returns rows sorted by display name then opaque identifier. Rows are never persisted or logged. `setRole` loads encrypted settings, treats a missing old role as Excluded reference, changes exactly one assignment, appends one `.localUser` audit entry, and atomically replaces settings. `ReferenceCalendarWorkflow.view` first proves the current role is Excluded reference, invokes only `ExcludedReferenceViewing`, returns a memory-only `ReferenceCalendarView`, and never receives a settings-write or planning-refresh dependency. Its initializer accepts `settingsReader: any PrivateSettingsReading`, not `PrivateSettingsStore`.

Use these finite public results:

```swift
public enum CalendarRoleChangeResult: Equatable, Sendable {
    case unchanged
    case saved(requiresValidatedRefresh: Bool)
}

public struct ReferenceCalendarView: Equatable, Sendable {
    public let events: [PlannerEvent]
    public init(events: [PlannerEvent]) { self.events = events }
}

public enum PlanningWorkflowError: Equatable, Error, Sendable {
    case settingsUnavailable
    case catalogUnavailable
    case planningReadUnavailable
    case referenceViewUnavailable
    case calendarIsNotExcludedReference
}
```

Every caught adapter/store error maps to one of these cases; the underlying description is discarded.

- [ ] **Step 5: Add the only M1 calendar implementation**

`M1SyntheticCalendarSource` conforms to all three read ports and returns a fixed in-memory catalog with opaque identifiers such as `synthetic-school-demo` and `synthetic-reference-demo`. Its exact production/test initializer is `public init(referenceDate: Date)`, and it places its synthetic items within the Vancouver local day containing that date. Titles are visibly synthetic. It contains no `URLSession`, OAuth, Google framework, credential, process, filesystem, or mutation method.

`SystemClock` is the only production `PlannerClock`:

```swift
public struct SystemClock: PlannerClock, Sendable {
    public init() {}
    public var now: Date { Date() }
}
```

- [ ] **Step 6: Run GREEN workflow tests and the complete suite**

```zsh
workflow_scratch="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-workflow-green.XXXXXX")"
swift test --package-path DailyPlanner --scratch-path "$workflow_scratch" --no-parallel
rm -rf "$workflow_scratch"
```

Expected: the exclusion canary is absent from every planning output, manual reference view is memory-only, role audit is persisted through the encrypted store seam, and the synthetic source is deterministic.

- [ ] **Step 7: Commit read-only workflows**

```zsh
git add DailyPlanner/Sources/DailyPlannerApplication DailyPlanner/Sources/DailyPlannerPlatform/M1SyntheticCalendarSource.swift \
  DailyPlanner/Sources/DailyPlannerPlatform/SystemClock.swift \
  DailyPlanner/Tests/DailyPlannerApplicationTests DailyPlanner/Tests/DailyPlannerPlatformTests
git commit -m "feat: add isolated read-only planning workflows"
```

---

### Task 7: Balanced three-column UI, settings, and M1 composition

**Files:**
- Modify: `DailyPlanner/Package.swift`
- Modify: `DailyPlanner/Sources/DailyPlannerUI/M1RootView.swift`
- Modify: `DailyPlanner/Sources/DailyPlannerApp/main.swift`
- Create: `DailyPlanner/Sources/DailyPlannerUI/PlannerAppModel.swift`
- Create: `DailyPlanner/Sources/DailyPlannerUI/ThreeColumnLayoutPolicy.swift`
- Create: `DailyPlanner/Sources/DailyPlannerUI/PlannerPalette.swift`
- Create: `DailyPlanner/Sources/DailyPlannerUI/PriorityQueueColumn.swift`
- Create: `DailyPlanner/Sources/DailyPlannerUI/SchedulePreviewColumn.swift`
- Create: `DailyPlanner/Sources/DailyPlannerUI/AssistantStatusColumn.swift`
- Create: `DailyPlanner/Sources/DailyPlannerUI/PlannerSettingsView.swift`
- Create: `DailyPlanner/Sources/DailyPlannerApp/AppComposition.swift`
- Create: `DailyPlanner/Tests/DailyPlannerUITests/PlannerAppModelTests.swift`
- Create: `DailyPlanner/Tests/DailyPlannerUITests/ThreeColumnLayoutPolicyTests.swift`
- Create: `DailyPlanner/Tests/DailyPlannerUITests/M1RootViewAccessibilityTests.swift`

**Interfaces:**
- Consumes: the four M1 workflows, synthetic catalog, encrypted settings, and no live dependency.
- Produces: one balanced three-column window, a settings sheet for real-vault permission and calendar roles, a persistent offline/no-write banner, synthetic daily preview, and non-interactive assistant status.

- [ ] **Step 1: Write failing model-state and layout tests**

```swift
@MainActor
func testInitialStateIsOfflineNoWriteWithAssistantUnavailable() {
    let model = PlannerModelHarness.make().model
    XCTAssertEqual(model.safetyBanner, "Offline M1 preview · no external writes")
    XCTAssertEqual(model.assistantState, .unavailable(.notIncludedInM1))
    XCTAssertFalse(model.canExecuteExternalAction)
}

func testBalancedWidthsAtDefaultWindowSize() {
    let widths = ThreeColumnLayoutPolicy.widths(total: 1280)
    XCTAssertEqual(widths.left, widths.right, accuracy: 0.5)
    XCTAssertGreaterThan(widths.center, widths.left)
    XCTAssertEqual(widths.left + widths.center + widths.right, 1280, accuracy: 0.5)
}
```

Add these exact model/layout cases:

```swift
func testMinimumWindowWidthKeepsPositiveCenterColumn() {
    let widths = ThreeColumnLayoutPolicy.widths(total: 1100)
    XCTAssertGreaterThanOrEqual(widths.left, 260)
    XCTAssertGreaterThan(widths.center, 0)
    XCTAssertEqual(widths.left, widths.right, accuracy: 0.5)
}

@MainActor
func testNoExplicitPlanningRoleProducesEmptyPreview() async {
    let model = PlannerModelHarness.make(assignments: [:]).model
    await model.refresh()
    XCTAssertTrue(model.preview.queue.isEmpty)
}

@MainActor
func testRoleChangeInvalidatesPreviewUntilRefresh() async {
    let harness = PlannerModelHarness.make(planningSchool: true)
    let model = harness.model
    await model.refresh()
    await model.setRole(.excludedReference, for: harness.schoolCalendarID)
    XCTAssertEqual(model.previewState, .requiresRefresh)
    XCTAssertEqual(model.preview, .empty)
}

@MainActor
func testVaultSelectionShowsPermissionWithoutPath() async {
    let model = PlannerModelHarness.make(folderPickerResult: Data("opaque".utf8)).model
    await model.chooseVaultRoot()
    XCTAssertEqual(model.vaultPermissionLabel, "Permission remembered")
    XCTAssertFalse(model.vaultPermissionLabel.contains("/"))
}
```

```swift
@MainActor
func testOpeningSettingsDoesNotStartOnboardingOrRefresh() {
    let harness = PlannerModelHarness.make()
    let model = harness.model
    model.showSettings()
    XCTAssertTrue(model.isSettingsPresented)
    XCTAssertEqual(harness.picker.callCount, 0)
    XCTAssertEqual(harness.source.planningReadCallCount, 0)
}

@MainActor
func testExplicitSettingsLoadPublishesMemoryOnlyRoleRows() async {
    let harness = PlannerModelHarness.make()
    await harness.model.loadCalendarRoles()
    XCTAssertEqual(harness.model.calendarRoleRows.map(\.calendarID), [harness.schoolCalendarID])
    XCTAssertEqual(harness.model.calendarRoleRows.map(\.role), [.excludedReference])
    XCTAssertEqual(harness.store.replaceCount, 0)
}
```

Add an automated hosted-view accessibility test, not a screenshot-only assertion:

```swift
@MainActor
func testHostedRootAndSettingsExposeSafeKeyboardReachableStructureAtMinimumSize() async {
    let harness = PlannerModelHarness.make(planningSchool: true)
    await harness.model.refresh()
    await harness.model.loadCalendarRoles()

    let root = host(
        M1RootView(model: harness.model),
        width: 1100,
        height: 680
    )
    defer { root.close() }
    let rootNodes = HostedAccessibilitySnapshot.capture(from: root)
    XCTAssertTrue(rootNodes.identifiers.isSuperset(of: [
        "m1-safety-banner", "priority-queue-column", "schedule-preview-column",
        "assistant-status-column", "planner-settings-button",
    ]))

    let settings = host(
        PlannerSettingsView(model: harness.model),
        width: 720,
        height: 560
    )
    defer { settings.close() }
    let settingsNodes = HostedAccessibilitySnapshot.capture(from: settings)
    XCTAssertTrue(settingsNodes.identifiers.contains("choose-vault-root-button"))
    XCTAssertTrue(settingsNodes.identifiers.contains("calendar-role-picker"))
    XCTAssertTrue(settingsNodes.enabledControlIdentifiers.contains("choose-vault-root-button"))
    XCTAssertTrue(settingsNodes.enabledControlIdentifiers.contains("calendar-role-picker"))
    XCTAssertTrue((rootNodes.labels + settingsNodes.labels).contains { $0.contains("School") })

    let exposedText = (rootNodes.exposedText + settingsNodes.exposedText).joined(separator: " ")
    for forbidden in [
        harness.schoolCalendarID.rawValue,
        "synthetic-event-title-canary",
        "/synthetic/private/canary",
        "opaque-bookmark-canary",
    ] {
        XCTAssertFalse(exposedText.contains(forbidden))
    }
}
```

The same test file declares these exact helpers:

```swift
@MainActor
final class HostedViewFixture {
    let window: NSWindow
    let hostingView: NSView
    func close()
}

struct HostedAccessibilitySnapshot: Sendable {
    let identifiers: Set<String>
    let labels: [String]
    let exposedText: [String]
    let enabledControlIdentifiers: Set<String>

    @MainActor
    static func capture(from fixture: HostedViewFixture) -> HostedAccessibilitySnapshot
}

@MainActor
func host<Content: View>(
    _ content: Content,
    width: CGFloat,
    height: CGFloat
) -> HostedViewFixture
```

`host` creates an `NSWindow` and `NSHostingView`, sets the exact frame, makes the window key, lays out, pumps the main run loop once, and returns an owned fixture whose idempotent `close` orders the window out. `HostedAccessibilitySnapshot` recursively walks both `NSView` and `NSAccessibilityElement` children using their AppKit accessibility APIs; it captures identifiers, labels, values, roles, and enabled state only. `enabledControlIdentifiers` includes enabled `.button`, `.popUpButton`, `.checkBox`, and `.radioButton` roles, which are keyboard-focusable native controls. The root/settings row implementation must expose category text plus a symbol name, so the `School` assertion proves color is not the sole category signal. The synthetic event-title canary may render visually in the demo row, but structural accessibility identifiers/labels/values use bounded category/kind/time text and never raw title, path, bookmark, or calendar ID.

Update the existing package targets to these exact dependencies and add the UI test target:

```swift
.target(
    name: "DailyPlannerUI",
    dependencies: ["DailyPlannerDomain", "DailyPlannerApplication"]
),
.executableTarget(
    name: "DailyPlannerApp",
    dependencies: [
        "DailyPlannerDomain", "DailyPlannerApplication", "DailyPlannerPersistence",
        "DailyPlannerPlatform", "DailyPlannerUI",
    ]
),
.testTarget(
    name: "DailyPlannerUITests",
    dependencies: ["DailyPlannerDomain", "DailyPlannerApplication", "DailyPlannerUI"]
),
```

- [ ] **Step 2: Observe RED and implement the UI model**

`PlannerAppModel` is `@MainActor`, owns published presentation state, and calls only application workflows. It exposes no raw bookmark, filesystem URL, adapter error, or action executor. Opaque calendar IDs exist only inside memory-only role rows and role-change calls; they are never rendered, logged, or included in accessibility values. `refresh` maps failures to finite `PlannerAppFailure` values and never logs underlying errors. Every successful role change immediately replaces the visible preview with `.empty` and marks it `.requiresRefresh`, so an item from a newly excluded calendar cannot remain on screen or in presentation state.

```swift
public enum AssistantUnavailableReason: Equatable, Sendable { case notIncludedInM1 }
public enum AssistantState: Equatable, Sendable {
    case unavailable(AssistantUnavailableReason)
}
public enum PlannerAppFailure: Equatable, Sendable {
    case settingsUnavailable
    case catalogUnavailable
    case selectionUnavailable
    case refreshUnavailable
    case referenceViewUnavailable
}
public enum PlannerPreviewState: Equatable, Sendable {
    case empty
    case ready
    case requiresRefresh
}

@MainActor
public final class PlannerAppModel: ObservableObject {
    @Published public private(set) var preview: PlanningPreview
    @Published public private(set) var previewState: PlannerPreviewState
    @Published public private(set) var assistantState: AssistantState
    @Published public private(set) var calendarRoleRows: [CalendarRoleRow]
    @Published public private(set) var vaultPermissionLabel: String
    @Published public private(set) var isSettingsPresented: Bool
    @Published public private(set) var failure: PlannerAppFailure?

    public let safetyBanner: String
    public var canExecuteExternalAction: Bool { false }

    public init(
        vaultOnboarding: VaultOnboardingWorkflow,
        roles: CalendarRoleWorkflow,
        planning: PlanningPreviewWorkflow,
        referenceView: ReferenceCalendarWorkflow,
        previewInterval: DateInterval
    )

    public func showSettings()
    public func loadCalendarRoles() async
    public func chooseVaultRoot() async
    public func refresh() async
    public func setRole(_ role: CalendarRole, for calendarID: CalendarID) async
}
```

`canExecuteExternalAction` is always false because `PlannerAppModel` has no action or execution dependency. A state transition can change it only by changing the public initializer and its tests in a separately approved milestone. `loadCalendarRoles` calls `CalendarRoleWorkflow.rows`, stores the rows in memory only, and maps catalog/settings failures to finite `PlannerAppFailure` cases. `PlannerSettingsView` renders only `calendarRoleRows`; each picker passes the row's opaque ID back to `setRole`, but the ID never becomes visible or accessible text.

`PlannerAppModelTests.swift` defines this exact main-actor harness, using Task 5–6 recording fakes and immutable synthetic fixtures; no free global such as `schoolID`, `recordingPicker`, or `recordingPlanningReader` is used:

```swift
@MainActor
final class PlannerModelHarness {
    let model: PlannerAppModel
    let picker: RecordingFolderPicker
    let store: RecordingSettingsStore
    let source: RecordingCalendarSource
    let schoolCalendarID: CalendarID

    static func make(
        assignments: [CalendarID: CalendarRole] = [:],
        planningSchool: Bool = false,
        folderPickerResult: Data? = nil
    ) -> PlannerModelHarness
}
```

`make` creates one synthetic school calendar and event, merges `.planning` for that calendar only when `planningSchool` is true, constructs the four real workflows, and supplies a fixed Vancouver `previewInterval`. The harness is compiled into `DailyPlannerUITests`; copy the small lock-protected recording fakes into that test target because SwiftPM test targets cannot import another test target.

- [ ] **Step 3: Implement the balanced layout and accessible regions**

```swift
public enum ThreeColumnLayoutPolicy {
    public static func widths(total: CGFloat) -> (left: CGFloat, center: CGFloat, right: CGFloat) {
        let side = max(260, total * 0.27)
        return (side, total - (side * 2), side)
    }
}
```

`M1RootView` uses `GeometryReader`, a zero-spacing `HStack`, and dividers. Required identifiers and labels are:

| Region/control | Accessibility identifier | Accessible value |
|---|---|---|
| safety banner | `m1-safety-banner` | `Offline M1 preview, no external writes` |
| left queue | `priority-queue-column` | item count only |
| center schedule | `schedule-preview-column` | selected local day and item count |
| assistant | `assistant-status-column` | `Unavailable in M1` |
| settings | `planner-settings-button` | `Configure vault permission and calendar roles` |
| vault control | `choose-vault-root-button` | `Permission not selected` or `Permission remembered` |
| role picker | `calendar-role-picker` | `Planning` or `Excluded reference` |

No identifier/value contains a calendar identifier, event title, path, or bookmark.

`PlannerSettingsView` has exact `internal init(model: PlannerAppModel)`. Its `.task` calls `loadCalendarRoles` only after the settings view appears; opening the sheet still does not start vault onboarding, planning refresh, or any external operation. Every role row uses `displayName` as visible text, never `calendarID.rawValue`.

- [ ] **Step 4: Apply the approved category palette**

`PlannerPalette` uses semantic names and accessible icon/text fallbacks:

```swift
public static let school = Color.blue
public static let schoolDeadline = Color(red: 0.70, green: 0.62, blue: 0.92)
public static let extracurricular = Color.green
public static let career = Color.yellow
public static let personal = Color.magenta
```

Color is never the only indicator. Every queue/schedule row includes a category label and symbol.

- [ ] **Step 5: Compose only M1 dependencies**

```swift
@MainActor
public enum AppComposition {
    public static func makeM1RootModel() -> PlannerAppModel {
        let settingsStore = EncryptedPrivateSettingsStore.production()
        let clock = SystemClock()
        let now = clock.now
        let source = M1SyntheticCalendarSource(referenceDate: now)
        return PlannerAppModel(
            vaultOnboarding: VaultOnboardingWorkflow(
                picker: MacVaultFolderPicker(),
                settingsStore: settingsStore
            ),
            roles: CalendarRoleWorkflow(settingsStore: settingsStore, catalogReader: source),
            planning: PlanningPreviewWorkflow(
                catalogReader: source,
                planningReader: source,
                settingsReader: settingsStore,
                clock: clock
            ),
            referenceView: ReferenceCalendarWorkflow(
                referenceReader: source,
                settingsReader: settingsStore
            ),
            previewInterval: LocalSchedulePolicy.v1.localDayInterval(containing: now)
        )
    }
}
```

At this task, replace the temporary Task 1 root initializer with `public init(model: PlannerAppModel)` and store the model as `@StateObject`. Update the executable window to `M1RootView(model: AppComposition.makeM1RootModel())`. The root view observes this one model; it never constructs adapters or workflows.

There is no Google, OAuth, Codex, Process, network transport, vault reader/writer, notification sender, scheduler timer, action bundle, approval, or executor constructor.

- [ ] **Step 6: Run UI-model/layout GREEN tests and rebuild the signed app**

```zsh
ui_scratch="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-ui-green.XXXXXX")"
swift test --package-path DailyPlanner --scratch-path "$ui_scratch" --no-parallel \
  --filter DailyPlannerUITests
rm -rf "$ui_scratch"
zsh DailyPlanner/Scripts/build-app.sh
zsh DailyPlanner/Tests/verify-signed-app.sh
```

Run `M1RootViewAccessibilityTests` as the automated gate, then perform one visual check for details the hosted tree cannot judge: banner stays visible, columns are balanced, focus rings are visible, and no content overlaps at the minimum size.

- [ ] **Step 7: Commit the composed shell**

```zsh
git add DailyPlanner/Package.swift DailyPlanner/Sources/DailyPlannerUI \
  DailyPlanner/Sources/DailyPlannerApp/main.swift DailyPlanner/Sources/DailyPlannerApp/AppComposition.swift \
  DailyPlanner/Tests/DailyPlannerUITests
git commit -m "feat: compose Daily Planner M1 interface"
```

---

### Task 8: Integrated M1 safety acceptance and handoff

**Files:**
- Modify: `DailyPlanner/Package.swift`
- Create: `DailyPlanner/Tests/DailyPlannerAcceptanceTests/M1SafetyAcceptanceTests.swift`
- Create: `DailyPlanner/Tests/verify-m1.sh`
- Create: `docs/architecture/M1-Read-Only-Shell-Handoff.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: complete M1 package, app bundle, sanitized M0.5 evidence, and the approved local-v1 spec.
- Produces: one serial acceptance command and a gate table that distinguishes passed M1 behavior from blocked live capabilities.

- [ ] **Step 1: Write the failing integrated safety test**

The test composes generated-only dependencies and exercises onboarding, an explicit Planning role, refresh, Excluded manual view, schedule slots, and midnight eligibility:

```swift
@MainActor
func testM1EndToEndKeepsReferenceCanaryAndVaultContentsOutsidePlanning() async throws {
    let harness = try M1AcceptanceHarness.makeGenerated()
    defer { harness.cleanup() }

    let onboardingResult = await harness.chooseGeneratedVaultRoot()
    XCTAssertEqual(onboardingResult, .selected)
    try harness.assign(.planning, to: harness.schoolCalendarID)
    let preview = try await harness.refresh()
    let referenceView = try await harness.viewReferenceCalendar()

    XCTAssertTrue(preview.queue.contains { $0.category == .school })
    XCTAssertFalse(preview.allSourceIDs.contains(harness.referenceCanaryID))
    XCTAssertEqual(referenceView.events.map(\.id), [harness.referenceCanaryID])
    XCTAssertEqual(harness.folderPickerCallCount, 1)
    XCTAssertEqual(harness.settingsReplaceCount, 2)
    XCTAssertFalse(harness.persistedBytesContainPrivateCanaries)

    let finiteFailure = await harness.exerciseInjectedPathError()
    XCTAssertEqual(finiteFailure, .settingsUnavailable)
    XCTAssertFalse(String(describing: finiteFailure).contains(harness.pathShapedCanary))
}
```

The harness uses recording seams already defined in Tasks 4–6. It never adds a production write, network, process, or vault-content protocol merely to count calls. The expected two settings replacements are the opaque bookmark save and the explicit calendar-role change.

Use this exact acceptance-harness surface; its implementation stays entirely in `M1SafetyAcceptanceTests.swift`:

```swift
@MainActor
final class M1AcceptanceHarness {
    let schoolCalendarID: CalendarID
    let referenceCanaryID: String
    let pathShapedCanary: String

    static func makeGenerated() throws -> M1AcceptanceHarness
    func chooseGeneratedVaultRoot() async -> VaultOnboardingState
    func assign(_ role: CalendarRole, to calendarID: CalendarID) throws
    func refresh() async throws -> PlanningPreview
    func viewReferenceCalendar() async throws -> ReferenceCalendarView
    func exerciseInjectedPathError() async -> PlanningWorkflowError
    func cleanup()

    var folderPickerCallCount: Int { get }
    var settingsReplaceCount: Int { get }
    var persistedBytesContainPrivateCanaries: Bool { get }
}
```

`makeGenerated` creates one exact temporary root, encrypted-envelope URL, fixed 32-byte test key provider, generated-folder bookmark result, synthetic planning/reference source, fixed clock, fixed Vancouver interval, and the fixture-only path-shaped canary `/synthetic/private/canary`. Because SwiftPM test targets cannot import other test targets, the acceptance file contains private copies of the minimal lock-protected recording picker/store/key-provider seams with the same signatures. The harness stores every exact owned URL for `cleanup`; `cleanup` removes only that generated root and is idempotent. `persistedBytesContainPrivateCanaries` uses `Data.range(of:)` against the synthetic bookmark, calendar-ID, actor, and path-shaped canaries and returns true on any match. `exerciseInjectedPathError` makes a settings reader throw a test error that carries the path-shaped canary and proves the application boundary returns only `.settingsUnavailable`. The harness never instantiates `SettingsKeychain`, so acceptance creates no real Keychain item.

- [ ] **Step 2: Observe RED, add the minimal acceptance harness, then run GREEN**

Keep `M1AcceptanceHarness` in the acceptance test target. It uses a temporary encrypted settings URL, fixed test key material, generated folder-picker result, synthetic source, and fixed Vancouver clock. The production source tree receives no test-only cleanup method.

Add the test target to `Package.swift`:

```swift
.testTarget(
    name: "DailyPlannerAcceptanceTests",
    dependencies: [
        "DailyPlannerDomain", "DailyPlannerApplication", "DailyPlannerPersistence", "DailyPlannerPlatform"
    ]
),
```

```zsh
acceptance_scratch="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-acceptance-green.XXXXXX")"
swift test --package-path DailyPlanner --scratch-path "$acceptance_scratch" --no-parallel \
  --filter M1SafetyAcceptanceTests
rm -rf "$acceptance_scratch"
```

- [ ] **Step 3: Create the serial M1 verifier**

`verify-m1.sh` must use one private scratch directory and an exact cleanup trap:

```zsh
#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h:h}"
planner_root="$repo_root/DailyPlanner"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/daily-planner-m1-verify.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

swift test --package-path "$planner_root" --scratch-path "$scratch/swift" --no-parallel
zsh "$planner_root/Scripts/build-app.sh"
zsh "$planner_root/Tests/verify-signed-app.sh"
git -C "$repo_root" diff --check

assert_no_source_match() {
  local source_root="$1"
  local pattern="$2"
  if rg -l "$pattern" "$source_root"; then
    return 1
  fi
}

verify_source_hygiene() {
  local source_root="$1"
  local package_file="$2"
  local allowed_private_io="$source_root/DailyPlannerPersistence/EncryptedPrivateSettingsStore.swift"
  local allowed_bookmark_creator="$source_root/DailyPlannerPlatform/MacVaultFolderPicker.swift"
  local private_io_callers
  local bookmark_creators

  assert_no_source_match "$source_root" 'URLSession|URLRequest|import[[:space:]]+Network|NW(Connection|Listener)|CFNetwork|Process[[:space:]]*[(]|NSTask|NSFileCoordinator|startAccessingSecurityScopedResource|resolvingBookmarkData|FileHandle'
  assert_no_source_match "$source_root" 'gmail[.]googleapis[.]com|calendar/v3|tasks/v1|oauth2[.]googleapis[.]com|codex app-server'
  assert_no_source_match "$source_root" '(^|[^A-Za-z])(print|debugPrint|dump|NSLog|os_log|fatalError|preconditionFailure|assertionFailure)[[:space:]]*[(]|Logger[[:space:]]*[(]'

  private_io_callers="$(rg -l 'Data[[:space:]]*[(]contentsOf:|String[[:space:]]*[(]contentsOf:|[.]write[[:space:]]*[(]to:|createDirectory[[:space:]]*[(]|contentsOfDirectory|enumerator[[:space:]]*[(]|contents[[:space:]]*[(]atPath:' "$source_root" || true)"
  [[ -z "$private_io_callers" || "$private_io_callers" == "$allowed_private_io" ]]

  bookmark_creators="$(rg -l 'bookmarkData[[:space:]]*[(]' "$source_root" || true)"
  [[ "$bookmark_creators" == "$allowed_bookmark_creator" ]]

  ! rg -l '[.]package[[:space:]]*[(]' "$package_file"
  ! rg -il 'name:[[:space:]]*"[^"]*(Google|Codex|VaultAdapter|Helper|Broker|Updater|Executor)' "$package_file"
}

verify_source_hygiene "$planner_root/Sources" "$planner_root/Package.swift"

cp -R "$planner_root/Sources" "$scratch/hygiene-sources"
cp "$planner_root/Package.swift" "$scratch/hygiene-Package.swift"
print 'let syntheticForbiddenCanary = URLSession.shared' > "$scratch/hygiene-sources/ForbiddenCanary.swift"
if verify_source_hygiene "$scratch/hygiene-sources" "$scratch/hygiene-Package.swift" >/dev/null 2>&1; then
  exit 1
fi
```

Then launch the exact app binary, retain its PID, confirm it remains alive for at least one poll, terminate only that PID, wait/reap it, and re-run `verify-signed-app.sh`, following the bounded owned-process sequence in Task 1.

- [ ] **Step 4: Prove the verifier rejects prohibited production capabilities**

Run the inverse assertions through the verifier; do not use a positive `rg` command whose expected failure is interpreted manually:

```zsh
zsh DailyPlanner/Tests/verify-m1.sh
```

Expected: exit 0. The verifier copies sources into its exact scratch directory, adds one synthetic forbidden-token canary there, and asserts that the same hygiene function exits nonzero; the existing scratch trap removes the generated copy. It never modifies tracked source. The enforced checks allow app-private settings file I/O only in the exact encrypted-settings store and require `bookmarkData` to appear only in the exact folder picker. They reject live/network/process/vault-I/O APIs, dynamic diagnostics/logging/crash calls, external Swift packages, and prohibited capability target names.

- [ ] **Step 5: Write the evidence handoff and update README**

`M1-Read-Only-Shell-Handoff.md` records `PASS`, `FAIL`, or `BLOCKED_BY_USER_AUTH/ACTION` for:

- signed build and owned launch cycle;
- module dependency direction;
- encrypted-settings round trip/tamper/plaintext absence;
- explicit generated-root bookmark creation with zero vault-content reads/writes;
- default Excluded-reference role and complete exclusion truth table;
- separate memory-only manual reference view;
- School-first stable queue;
- Vancouver 06:00/12:00/21:00 plus DST and midnight-eligibility behavior;
- balanced/accessibility-reviewed three-column shell and offline banner;
- no live Google, Codex, provider write, or vault-content capability;
- live Google canary and locked-state Keychain observation as still blocked.

The README must preserve the now-current persisted-bookmark `PASS`, add the M1 handoff link, keep the local-v1 spec link and helper-as-v2-only label, and state that the real-vault permission selector stores an opaque bookmark but M1 does not read or write vault content.

- [ ] **Step 6: Run full fresh verification**

```zsh
zsh DailyPlanner/Tests/verify-m1.sh
```

Expected: all Swift tests pass serially, signed build and launch cycle pass, no hygiene command finds a prohibited production dependency, exact temporary/Keychain test artifacts are absent, and `git diff --check` is clean.

- [ ] **Step 7: Commit the M1 handoff**

```zsh
git add DailyPlanner/Package.swift DailyPlanner/Tests/DailyPlannerAcceptanceTests \
  DailyPlanner/Tests/verify-m1.sh docs/architecture/M1-Read-Only-Shell-Handoff.md README.md
git commit -m "docs: record Daily Planner M1 safety gates"
```

---

## M1 Completion Boundary

M1 is complete only when the signed `.app` launches with the offline banner and balanced three-column layout; encrypted settings tests and the full exclusion truth table pass; generated-folder onboarding stores only an opaque bookmark; and all vault-content, live Google, live Codex, provider-write, assistant-generation, notification, scheduler-timer, midnight-write, and action-execution capabilities remain absent.

After M1, the next independently reviewed milestone may promote the already-proven Google read-only OAuth/client code behind the same calendar-role filter. No live capability enters M1 by implication.
