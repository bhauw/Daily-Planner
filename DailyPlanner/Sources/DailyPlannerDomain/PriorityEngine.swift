import Foundation

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
                if $0.start != $1.start {
                    return $0.start < $1.start
                }
                return $0.id < $1.id
            }
    }
}
