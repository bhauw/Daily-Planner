import Foundation

public enum MidnightSummaryIneligibleReason: Equatable, Sendable {
    case noUsage
    case noEligibleSources
}

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

    public init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    public func scanSlots(on localDay: Date) throws -> [Date] {
        let calendar = localCalendar
        return try [6, 12, 21].map { hour in
            guard let slot = calendar.date(
                bySettingHour: hour,
                minute: 0,
                second: 0,
                of: localDay
            ) else {
                throw LocalScheduleError.invalidLocalDay
            }
            return slot
        }
    }

    public func localDayInterval(containing date: Date) -> DateInterval {
        let calendar = localCalendar
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            return DateInterval(start: start, duration: 1)
        }
        return DateInterval(start: start, end: end)
    }

    public func midnightEligibility(
        usageSincePreviousMidnight: Bool,
        eligibleSourceCount: Int
    ) -> MidnightSummaryEligibility {
        guard usageSincePreviousMidnight else {
            return .ineligible(.noUsage)
        }
        guard eligibleSourceCount > 0 else {
            return .ineligible(.noEligibleSources)
        }
        return .eligible(sourceCount: eligibleSourceCount)
    }

    private var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
