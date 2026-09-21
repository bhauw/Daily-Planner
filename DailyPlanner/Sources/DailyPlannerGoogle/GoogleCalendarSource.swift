import Foundation
import DailyPlannerDomain

/// Adapts the live Google read clients to the planner's own source protocols, so the planning
/// workflows — and therefore the web UI — can run on real calendar data instead of
/// `M1SyntheticCalendarSource`.
///
/// This is the seam M2A never had: M2A proved the OAuth connection and the raw reads, but nothing
/// turned a `CalendarEventRecord` into a `PlannerEvent`. Everything above this type is unchanged;
/// swapping this in for the synthetic source is what makes the app show a real day.
///
/// Read-only by construction: it holds only read clients, so there is no write path to call.
public struct GoogleCalendarSource:
    CalendarCatalogReading,
    PlanningCalendarReading,
    ExcludedReferenceViewing,
    ColorCatalogReading,
    Sendable
{
    private let calendarClient: any GoogleCalendarReading
    private let colorsClient: any GoogleColorsReading
    private let tokens: any GoogleAccessTokenProviding
    /// The user's persisted colour → category mapping. A colour the user has not mapped falls
    /// back to `.other` rather than guessing, so a wrong category is never invented.
    private let colorMapping: [String: PlannerCategory]

    public init(
        calendarClient: any GoogleCalendarReading,
        colorsClient: any GoogleColorsReading,
        tokens: any GoogleAccessTokenProviding,
        colorMapping: [String: PlannerCategory]
    ) {
        self.calendarClient = calendarClient
        self.colorsClient = colorsClient
        self.tokens = tokens
        self.colorMapping = colorMapping
    }

    // MARK: - CalendarCatalogReading

    public func calendars() async throws -> [CalendarDescriptor] {
        let token = try await tokens.accessToken()
        return try await calendarClient.calendars(accessToken: token).map {
            CalendarDescriptor(id: $0.id, displayName: $0.displayName)
        }
    }

    // MARK: - PlanningCalendarReading

    public func planningEvents(
        calendarIDs: Set<CalendarID>,
        interval: DateInterval
    ) async throws -> [PlannerEvent] {
        guard !calendarIDs.isEmpty else { return [] }
        let token = try await tokens.accessToken()
        let colorByCalendar = try await calendarColorIndex(accessToken: token)

        var out: [PlannerEvent] = []
        // Sorted so the result is deterministic regardless of Set iteration order.
        for id in calendarIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
            let records = try await allEvents(
                calendarID: id, interval: interval, accessToken: token
            )
            out.append(
                contentsOf: records.compactMap {
                    plannerEvent(from: $0, calendarColorID: colorByCalendar[id])
                }
            )
            if out.count >= GoogleSyncLimits.calendarEvents { break }
        }
        return out.sorted { $0.start < $1.start }
    }

    // MARK: - ExcludedReferenceViewing

    /// An excluded reference calendar is *viewable* but contributes nothing to planning. That rule
    /// is enforced by the caller routing such a calendar here instead of to `planningEvents`; this
    /// type never merges the two.
    public func referenceEvents(
        calendarID: CalendarID,
        interval: DateInterval
    ) async throws -> [PlannerEvent] {
        let token = try await tokens.accessToken()
        let colorByCalendar = try await calendarColorIndex(accessToken: token)
        let records = try await allEvents(
            calendarID: calendarID, interval: interval, accessToken: token
        )
        return records
            .compactMap { plannerEvent(from: $0, calendarColorID: colorByCalendar[calendarID]) }
            .sorted { $0.start < $1.start }
    }

    // MARK: - ColorCatalogReading

    /// The colours actually in use on the connected account's calendars, so Settings can offer
    /// exactly those to map. Colour data is non-content metadata and safe to display; a calendar
    /// title is not, so the label here is derived from the opaque colour id and never from a
    /// calendar name. Google's palette carries no human colour name, so the swatch itself
    /// (background/foreground) is what the UI should render to identify a colour.
    public func colorsInUse() async throws -> [ColorCatalogEntry] {
        let token = try await tokens.accessToken()
        let palette = try await colorsClient.palette(accessToken: token)
        let records = try await calendarClient.calendars(accessToken: token)

        var seen: [String] = []
        for record in records {
            guard let id = record.colorId, !id.isEmpty, !seen.contains(id) else { continue }
            seen.append(id)
        }

        return seen.compactMap { colorID in
            guard let entry = palette.entry(forColorID: colorID) else { return nil }
            return ColorCatalogEntry(
                colorID: colorID,
                background: entry.background,
                foreground: entry.foreground,
                label: "Colour \(colorID)"
            )
        }
    }

    // MARK: - Internals

    /// calendarID → its own `colorId`, so an event with no colour of its own can inherit one.
    private func calendarColorIndex(
        accessToken: GoogleAccessToken
    ) async throws -> [CalendarID: String] {
        var index: [CalendarID: String] = [:]
        for record in try await calendarClient.calendars(accessToken: accessToken) {
            guard let id = record.colorId, !id.isEmpty else { continue }
            index[record.id] = id
        }
        return index
    }

    /// Pages through a calendar's events, bounded by `GoogleSyncLimits` so a pathological account
    /// cannot spin here forever.
    private func allEvents(
        calendarID: CalendarID,
        interval: DateInterval,
        accessToken: GoogleAccessToken
    ) async throws -> [CalendarEventRecord] {
        var out: [CalendarEventRecord] = []
        var pageToken: CalendarPageToken?
        for _ in 0..<GoogleSyncLimits.calendarPages {
            try Task.checkCancellation()
            let page = try await calendarClient.events(
                calendarID: calendarID,
                interval: interval,
                syncToken: nil,
                pageToken: pageToken,
                accessToken: accessToken
            )
            out.append(contentsOf: page.events)
            guard let next = page.nextPageToken, out.count < GoogleSyncLimits.calendarEvents else {
                break
            }
            pageToken = next
        }
        return out
    }

    /// Maps one Google event onto the planner's model. Returns nil for anything that must not
    /// reach the planner: a cancelled event, or one with no usable time range.
    private func plannerEvent(
        from record: CalendarEventRecord,
        calendarColorID: String?
    ) -> PlannerEvent? {
        guard record.status != .cancelled else { return nil }
        guard let start = record.start, let end = record.end else { return nil }
        guard let startDate = Self.instant(from: start),
              let endDate = Self.instant(from: end),
              endDate >= startDate else { return nil }

        let category = GoogleColorCategory.category(
            forEventColorID: record.colorId,
            calendarColorID: calendarColorID,
            mapping: colorMapping,
            fallback: .other
        )

        // The event id is deliberately opaque so it cannot be logged by accident.
        // Unwrapping it here is the sanctioned path and is safe: this value becomes the
        // PlannerEvent's stable identity for the loopback UI (a React key, a drag target)
        // and never leaves 127.0.0.1. It is an identifier, not calendar content.
        let identity = record.id.withUnsafeRawValue { $0 }

        return PlannerEvent(
            id: identity,
            calendarID: record.calendarID,
            title: record.title,
            category: category,
            kind: Self.kind(for: record),
            start: startDate,
            end: endDate,
            due: nil
        )
    }

    /// An all-day item reads as a deadline on the dayline rather than a block that swallows the
    /// whole day; a timed item is an ordinary event.
    private static func kind(for record: CalendarEventRecord) -> PlannerItemKind {
        if case .date = record.start { return .deadline }
        return .event
    }

    private static let zone = TimeZone(identifier: "America/Vancouver") ?? .gmt

    /// Resolves a Google event time to an instant. An all-day value carries only date components,
    /// so it is anchored at the start of that day in the planner's zone. Google's all-day `end`
    /// is already exclusive (an event "on the 14th" ends on the 15th), so the start of the end
    /// date is the correct end instant and needs no adjustment here.
    private static func instant(from time: GoogleEventTime) -> Date? {
        switch time {
        case let .dateTime(instant, _):
            return instant
        case let .date(components):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            var components = components
            components.timeZone = zone
            return calendar.date(from: components)
        }
    }
}
