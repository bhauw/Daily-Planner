import Foundation
import XCTest
import DailyPlannerDomain
@testable import DailyPlannerAPI

/// Proves the *live* service path end to end: an injected source and the real settings protocol
/// actually reach `/api/preview`, `/api/calendars` and `/api/tasks`.
///
/// This is the test whose absence let the `__DP_TOKEN__` mismatch ship — every layer was unit
/// tested, but nothing asserted that data injected at the bottom came out of the API at the top.
final class PlannerAPIServiceLiveTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
    private let planningID = CalendarID(rawValue: "live-planning")
    private let excludedID = CalendarID(rawValue: "live-excluded")

    // MARK: - Fakes

    private struct FakeSource: CalendarCatalogReading, PlanningCalendarReading, Sendable {
        let descriptors: [CalendarDescriptor]
        let events: [CalendarID: [PlannerEvent]]

        func calendars() async throws -> [CalendarDescriptor] { descriptors }

        func planningEvents(
            calendarIDs: Set<CalendarID>, interval: DateInterval
        ) async throws -> [PlannerEvent] {
            calendarIDs
                .sorted { $0.rawValue < $1.rawValue }
                .flatMap { events[$0] ?? [] }
                .filter { interval.contains($0.start) }
        }
    }

    private struct FakeSettings: PrivateSettingsStore, Sendable {
        let settings: PrivateSettings
        func load() throws -> PrivateSettings { settings }
        func replace(_ settings: PrivateSettings) throws {}
    }

    private struct FakeTasks: PlannerTaskListReading, Sendable {
        let lists: [PlannerTaskList]
        func taskLists() async throws -> [PlannerTaskList] { lists }
    }

    private struct FixedTestClock: PlannerClock, Sendable {
        let now: Date
    }

    /// A clock the test can move. `@unchecked Sendable` is safe here: the test drives it from a
    /// single task and never mutates it concurrently.
    private final class ClockBox: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private struct AdvancingTestClock: PlannerClock, Sendable {
        let box: ClockBox
        var now: Date { box.now }
    }

    // MARK: - Helpers

    private func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func event(_ id: String, _ calendar: CalendarID, hour: Int) -> PlannerEvent {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = APIDateFormat.timeZone
        let start = cal.date(
            bySettingHour: hour, minute: 0, second: 0, of: cal.startOfDay(for: referenceDate)
        ) ?? referenceDate
        return PlannerEvent(
            id: id,
            calendarID: calendar,
            title: "Live \(id)",
            category: .school,
            kind: .event,
            start: start,
            end: start.addingTimeInterval(3600),
            due: nil
        )
    }

    private func liveService(
        vaultBookmark: Data? = nil,
        tasks: [PlannerTaskList]? = nil,
        clock: (any PlannerClock)? = nil
    ) -> PlannerAPIService {
        let source = FakeSource(
            descriptors: [
                CalendarDescriptor(id: planningID, displayName: "Live Planning"),
                CalendarDescriptor(id: excludedID, displayName: "Live Excluded"),
            ],
            events: [
                planningID: [event("a", planningID, hour: 9), event("b", planningID, hour: 13)],
                excludedID: [event("secret", excludedID, hour: 11)],
            ]
        )
        let settings = FakeSettings(
            settings: PrivateSettings(
                vaultBookmark: vaultBookmark,
                calendarRoles: [planningID: .planning],
                calendarRoleAudit: []
            )
        )
        return PlannerAPIService(
            source: source,
            settingsStore: settings,
            clock: clock ?? FixedTestClock(now: referenceDate),
            taskReader: tasks.map { FakeTasks(lists: $0) }
        )
    }

    // MARK: - Tests

    func testServedDayFollowsTheClockInsteadOfFreezingAtConstruction() async throws {
        // This is a daily driver that stays open. The day interval used to be computed once in
        // init, so an app left running past midnight kept serving the launch day — the Today
        // header still read "Tuesday, Sep 15" on the 16th until the app was quit and relaunched.
        let box = ClockBox(referenceDate)
        let service = liveService(clock: AdvancingTestClock(box: box))

        let firstDay = object(try await service.preview())["day"] as? String
        box.now = referenceDate.addingTimeInterval(24 * 60 * 60)
        let nextDay = object(try await service.preview())["day"] as? String

        XCTAssertNotNil(firstDay)
        XCTAssertNotNil(nextDay)
        XCTAssertNotEqual(firstDay, nextDay, "the served day must roll over with the clock")
    }

    func testPreviewServesTheInjectedLiveSourceNotSyntheticData() async throws {
        let json = object(try await liveService().preview())
        let schedule = json["schedule"] as? [[String: Any]] ?? []
        let titles = schedule.compactMap { $0["title"] as? String }

        XCTAssertFalse(titles.isEmpty, "the live source must reach /api/preview")
        XCTAssertTrue(
            titles.allSatisfy { $0.hasPrefix("Live ") },
            "synthetic content must not leak into the live path: \(titles)"
        )
    }

    func testAnExcludedCalendarContributesNothingToThePlan() async throws {
        let json = object(try await liveService().preview())
        let schedule = json["schedule"] as? [[String: Any]] ?? []
        let ids = schedule.compactMap { $0["id"] as? String }

        XCTAssertFalse(
            ids.contains("secret"),
            "an event on a calendar with no planning role must never reach the plan"
        )
    }

    func testCalendarsReportRolesFromTheRealSettingsStore() async throws {
        let json = object(try await liveService().calendars())
        let rows = json["calendars"] as? [[String: Any]] ?? []
        let byID = Dictionary(
            uniqueKeysWithValues: rows.compactMap { row -> (String, String)? in
                guard let id = row["id"] as? String, let role = row["role"] as? String else {
                    return nil
                }
                return (id, role)
            }
        )

        XCTAssertEqual(byID["live-planning"], "planning")
        XCTAssertEqual(
            byID["live-excluded"], "excluded",
            "fail-closed: a calendar with no assigned role is excluded"
        )
    }

    func testVaultSelectedReflectsTheRealStoreRatherThanAHardcodedFalse() {
        let without = object(liveService().settingsPayload())
        XCTAssertEqual(without["vaultSelected"] as? Bool, false)

        let with = object(liveService(vaultBookmark: Data([1, 2, 3])).settingsPayload())
        XCTAssertEqual(
            with["vaultSelected"] as? Bool, true,
            "the synthetic store always reported false; the live path must read the real value"
        )
    }

    /// The whole point of `source` is that it differs between the two initialisers. Asserting it
    /// on the synthetic path alone would pass even if the field were hardcoded to "sample" —
    /// which is the failure this is here to catch, since the generated contract fixture only
    /// ever exercises the synthetic service.
    func testLiveServiceReportsTheConnectedSourceRatherThanSample() {
        let live = object(liveService().settingsPayload())["source"] as? [String: Any]
        XCTAssertEqual(live?["kind"] as? String, "connected")
        XCTAssertEqual(live?["live"] as? Bool, true)
        XCTAssertEqual(live?["label"] as? String, "Your Google account")

        let synthetic = object(
            PlannerAPIService(referenceDate: referenceDate).settingsPayload()
        )["source"] as? [String: Any]
        XCTAssertEqual(
            synthetic?["kind"] as? String, "sample",
            "the silent fallback is the bug: fixtures must never claim to be the real account"
        )
        XCTAssertEqual(synthetic?["live"] as? Bool, false)
    }

    func testTasksServeTheLiveReaderAndCarryTheDoneFlag() async {
        let lists = [
            PlannerTaskList(
                name: "School",
                items: [
                    PlannerTaskItem(
                        id: "t1", title: "Live task", category: .school,
                        due: referenceDate, isCompleted: true
                    )
                ]
            )
        ]
        let json = object(await liveService(tasks: lists).tasks())
        let first = (json["lists"] as? [[String: Any]])?.first
        let item = (first?["items"] as? [[String: Any]])?.first

        XCTAssertEqual(first?["name"] as? String, "School")
        XCTAssertEqual(item?["title"] as? String, "Live task")
        XCTAssertEqual(
            item?["done"] as? Bool, true,
            "the web contract requires `done`; without it every task rendered as not-done"
        )
    }

    func testTasksFallBackToSyntheticWhenNoLiveReaderIsConnected() async {
        let json = object(await liveService(tasks: nil).tasks())
        let names = Set((json["lists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })

        XCTAssertEqual(
            names, ["School", "Career", "Extracurricular", "Personal", "Finance"],
            "with nothing connected the app still opens on synthetic content"
        )
    }

    func testEveryTaskDueIsADateWithNoTimeOfDay() async {
        let json = object(await liveService(tasks: nil).tasks())
        let lists = json["lists"] as? [[String: Any]] ?? []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = APIDateFormat.timeZone
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        for list in lists {
            for item in list["items"] as? [[String: Any]] ?? [] {
                guard let due = item["due"] as? String else { continue }
                let date = try? XCTUnwrap(formatter.date(from: due))
                guard let date else { continue }
                let parts = calendar.dateComponents([.hour, .minute], from: date)
                XCTAssertEqual(parts.hour, 0, "a task must not carry a time-of-day: \(due)")
                XCTAssertEqual(parts.minute, 0)
            }
        }
    }
}
