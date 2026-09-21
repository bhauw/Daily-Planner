import Foundation
import DailyPlannerDomain

public struct M1SyntheticCalendarSource:
    CalendarCatalogReading,
    PlanningCalendarReading,
    ExcludedReferenceViewing,
    ColorCatalogReading,
    Sendable
{
    private let catalog: [CalendarDescriptor]
    private let events: [PlannerEvent]

    public init(referenceDate: Date) {
        let planningID = CalendarID(rawValue: "synthetic-school-demo")
        let referenceID = CalendarID(rawValue: "synthetic-reference-demo")
        catalog = [
            CalendarDescriptor(id: planningID, displayName: "Synthetic School Calendar"),
            CalendarDescriptor(id: referenceID, displayName: "Synthetic Reference Calendar"),
        ]

        var vancouverCalendar = Calendar(identifier: .gregorian)
        vancouverCalendar.timeZone = TimeZone(identifier: "America/Vancouver")
            ?? TimeZone(secondsFromGMT: 0)!
        let dayStart = vancouverCalendar.startOfDay(for: referenceDate)

        func localTime(hour: Int, minute: Int = 0) -> Date {
            vancouverCalendar.date(
                bySettingHour: hour,
                minute: minute,
                second: 0,
                of: dayStart
            ) ?? dayStart
        }

        events = [
            PlannerEvent(
                id: "synthetic-school-task",
                calendarID: planningID,
                title: "Synthetic school task",
                category: .school,
                kind: .task,
                start: localTime(hour: 9),
                end: localTime(hour: 10),
                due: localTime(hour: 16)
            ),
            PlannerEvent(
                id: "synthetic-school-deadline",
                calendarID: planningID,
                title: "Synthetic school deadline",
                category: .school,
                kind: .deadline,
                start: localTime(hour: 13),
                end: localTime(hour: 14),
                due: localTime(hour: 15)
            ),
            PlannerEvent(
                id: "synthetic-reference-event",
                calendarID: referenceID,
                title: "Synthetic reference event",
                category: .personal,
                kind: .event,
                start: localTime(hour: 18),
                end: localTime(hour: 19),
                due: nil
            ),
        ]
    }

    public func calendars() async throws -> [CalendarDescriptor] {
        catalog
    }

    /// Synthetic mode has no live Google account, so no real colours are in use. Real swatches
    /// appear only once the live Google colour catalog is wired in (milestone M-W2); the Settings
    /// editor shows a clear "connect Google" state until then rather than inventing colours.
    public func colorsInUse() async throws -> [ColorCatalogEntry] {
        []
    }

    public func planningEvents(
        calendarIDs: Set<CalendarID>,
        interval: DateInterval
    ) async throws -> [PlannerEvent] {
        events.filter {
            calendarIDs.contains($0.calendarID) && overlaps($0, interval: interval)
        }
    }

    public func referenceEvents(
        calendarID: CalendarID,
        interval: DateInterval
    ) async throws -> [PlannerEvent] {
        events.filter {
            $0.calendarID == calendarID && overlaps($0, interval: interval)
        }
    }

    private func overlaps(_ event: PlannerEvent, interval: DateInterval) -> Bool {
        event.start < interval.end && event.end > interval.start
    }
}
