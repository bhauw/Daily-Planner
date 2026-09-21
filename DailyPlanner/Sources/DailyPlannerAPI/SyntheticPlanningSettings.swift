import Foundation
import DailyPlannerDomain

/// A read-only, in-memory settings source for the synthetic round.
///
/// The API never resolves the encrypted production settings (that is the packaging task's
/// domain, and the Keychain rejects the item until the app has a stable code identity). Instead
/// it serves a fixed, opaque set of role assignments so `/api/preview` and `/api/calendars`
/// return deterministic synthetic data. It holds **no** vault bookmark and writes nothing.
struct SyntheticPlanningSettings: PrivateSettingsStore {
    private let settings: PrivateSettings

    /// Assigns the synthetic school calendar the `planning` role so the workflow yields a
    /// non-empty preview; every other calendar stays `excludedReference` by policy default.
    init(planningCalendarIDs: [CalendarID]) {
        var roles: [CalendarID: CalendarRole] = [:]
        for id in planningCalendarIDs {
            roles[id] = .planning
        }
        settings = PrivateSettings(
            vaultBookmark: nil,
            calendarRoles: roles,
            calendarRoleAudit: []
        )
    }

    func load() throws -> PrivateSettings { settings }

    // No write path this round. `replace` is required by the protocol but the API never calls
    // it; it is a no-op so nothing can mutate persisted state through the loopback surface.
    func replace(_ settings: PrivateSettings) throws {}

    var vaultSelected: Bool { settings.vaultBookmark != nil }
}

/// A `PlannerClock` pinned to a fixed instant, so tests get deterministic timestamps without
/// depending on wall-clock time. Production wiring uses `SystemClock` instead.
struct FixedClock: PlannerClock {
    let now: Date
    init(_ now: Date) { self.now = now }
}
