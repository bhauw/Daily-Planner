import Foundation

public enum ProbeEvent: Sendable, Equatable {
    case thread(id: String)
    case turnStarted(id: String)
    case turnCompleted(id: String, status: String)
}

public struct ProbeStateMachine: Sendable {
    public enum Phase: Sendable, Equatable {
        case idle
        case threadStarted
        case turnInProgress
        case completed
    }

    public private(set) var phase: Phase = .idle
    private var turnID: String?

    public init() {}

    public mutating func accept(_ event: ProbeEvent) {
        switch event {
        case .thread:
            phase = .threadStarted
        case let .turnStarted(id):
            turnID = id
            phase = .turnInProgress
        case let .turnCompleted(id, status):
            guard id == turnID, status == "completed" else { return }
            phase = .completed
        }
    }
}
