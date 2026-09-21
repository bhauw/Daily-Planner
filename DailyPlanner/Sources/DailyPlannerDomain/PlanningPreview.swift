import Foundation

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

    init(
        conflictSourceIDs: Set<String>,
        freeBusySourceIDs: Set<String>,
        workloadSourceIDs: Set<String>,
        fatigueSourceIDs: Set<String>,
        prioritySourceIDs: Set<String>,
        digestSourceIDs: Set<String>,
        summarySourceIDs: Set<String>,
        proposalContextSourceIDs: Set<String>,
        assistantContextSourceIDs: Set<String>,
        actionCandidateSourceIDs: Set<String>
    ) {
        self.conflictSourceIDs = conflictSourceIDs
        self.freeBusySourceIDs = freeBusySourceIDs
        self.workloadSourceIDs = workloadSourceIDs
        self.fatigueSourceIDs = fatigueSourceIDs
        self.prioritySourceIDs = prioritySourceIDs
        self.digestSourceIDs = digestSourceIDs
        self.summarySourceIDs = summarySourceIDs
        self.proposalContextSourceIDs = proposalContextSourceIDs
        self.assistantContextSourceIDs = assistantContextSourceIDs
        self.actionCandidateSourceIDs = actionCandidateSourceIDs
    }

    public func contains(_ id: String) -> Bool {
        [
            conflictSourceIDs, freeBusySourceIDs, workloadSourceIDs, fatigueSourceIDs,
            prioritySourceIDs, digestSourceIDs, summarySourceIDs, proposalContextSourceIDs,
            assistantContextSourceIDs, actionCandidateSourceIDs,
        ].contains { $0.contains(id) }
    }
}

public struct PlanningPreview: Equatable, Sendable {
    public let queue: [PlannerEvent]
    public let schedule: [PlannerEvent]
    public let influence: PlanningInfluence

    init(queue: [PlannerEvent], schedule: [PlannerEvent], influence: PlanningInfluence) {
        self.queue = queue
        self.schedule = schedule
        self.influence = influence
    }

    public var allSourceIDs: Set<String> {
        Set(queue.map(\.id) + schedule.map(\.id))
    }

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
                if $0.start != $1.start {
                    return $0.start < $1.start
                }
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
