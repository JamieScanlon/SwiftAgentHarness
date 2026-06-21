import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("TriggerReplayHarness")
struct TriggerReplayHarnessTests {
    @Test("in-process replay admits trigger synchronously")
    func inProcessReplay() async throws {
        let service = TriggerReplayHarness.makeReplayService()
        let trigger = HarnessTrigger(
            id: "harness-1",
            source: .webhook,
            payload: "hello harness",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty
        )
        let result = try await service.replay(trigger)
        #expect(result.decision == .admitted)
        #expect(result.sessionID != nil)
    }
}
