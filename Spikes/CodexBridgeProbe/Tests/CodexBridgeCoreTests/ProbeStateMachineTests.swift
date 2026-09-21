import Testing
@testable import CodexBridgeCore

@Test func completesOnlyAfterMatchingTurnEvent() {
    var state = ProbeStateMachine()
    state.accept(.thread(id: "thr_synthetic"))
    state.accept(.turnStarted(id: "turn_synthetic"))
    state.accept(.turnCompleted(id: "turn_other", status: "completed"))
    #expect(state.phase == .turnInProgress)

    state.accept(.turnCompleted(id: "turn_synthetic", status: "completed"))

    #expect(state.phase == .completed)
}
