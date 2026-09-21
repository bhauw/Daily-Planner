import Foundation

/// Fixtures for the two surfaces that have no engine behind them this round. They are inert
/// sample data: no draft here has ever been near a real inbox, and nothing sends. The mail
/// draft workbench (task 04) and tasks workspace (task 06) render these until live sources land.
enum SyntheticContent {
    static func drafts(referenceDay: Date) -> [DraftDTO] {
        let created = APIDateFormat.iso8601(referenceDay)
        return [
            DraftDTO(
                id: "draft-office-hours",
                title: "Re: Office hours this week",
                summary: "Asks to stop by Thursday office hours about the problem set 3 feedback.",
                kind: "reply",
                sender: "Prof. Rivera",
                category: .school,
                receivedAt: created,
                // Sample data has no real thread, and must not pretend to: a reply composed
                // from a fixture has nothing to thread into.
                threadId: nil
            ),
            DraftDTO(
                id: "draft-club-logistics",
                title: "Finance club — room booking confirmation",
                summary: "Confirms the Tuesday 18:00 room booking for roughly 20 attendees.",
                kind: "bundle",
                sender: "Student Union bookings",
                category: .other,
                receivedAt: created,
                threadId: nil
            ),
        ]
    }

    static func taskLists(referenceDay: Date) -> [TaskListDTO] {
        // A task's due value is a DATE. Anchor it at local start-of-day rather than a
        // time-of-day: the product rule is that a task never carries a clock time, and the
        // engine should not send one it expects the client to hide.
        func due(_ daysFromNow: Int = 0) -> String {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = APIDateFormat.timeZone
            let start = calendar.startOfDay(for: referenceDay)
            let date = calendar.date(byAdding: .day, value: daysFromNow, to: start) ?? start
            return APIDateFormat.iso8601(date)
        }
        return [
            TaskListDTO(name: "School", items: [
                TaskDTO(id: "task-pset", title: "Finish problem set 3", category: .school, due: due(), done: false, estimateMinutes: 90),
                TaskDTO(id: "task-reading", title: "Read chapter 7", category: .school, due: due(1), done: true, estimateMinutes: 45),
            ]),
            TaskListDTO(name: "Career", items: [
                TaskDTO(id: "task-resume", title: "Update résumé bullet points", category: .career, due: nil, done: false, estimateMinutes: 30),
            ]),
            TaskListDTO(name: "Extracurricular", items: [
                TaskDTO(id: "task-club-agenda", title: "Draft finance club agenda", category: .other, due: due(2), done: false, estimateMinutes: 25),
            ]),
            TaskListDTO(name: "Personal", items: [
                TaskDTO(id: "task-groceries", title: "Grocery run", category: .personal, due: nil, done: false, estimateMinutes: 40),
            ]),
            TaskListDTO(name: "Finance", items: [
                TaskDTO(id: "task-budget", title: "Reconcile monthly budget", category: .finance, due: due(1), done: false, estimateMinutes: 35),
            ]),
        ]
    }
}
