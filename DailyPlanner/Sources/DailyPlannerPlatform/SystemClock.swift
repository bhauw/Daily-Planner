import Foundation
import DailyPlannerDomain

public struct SystemClock: PlannerClock, Sendable {
    public init() {}

    public var now: Date { Date() }
}
