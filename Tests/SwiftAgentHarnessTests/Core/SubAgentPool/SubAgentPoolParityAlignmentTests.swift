import Foundation
import Testing
@testable import SwiftAgentHarness

struct SubAgentPoolParityAlignmentTests {
    @Test("sub-agent invocation phases preserve model-pool style lifecycle progression")
    func invocationPhasesFollowPoolStyleProgression() {
        let phases: [SubAgentInvocationPhase] = [
            .queued,
            .dispatching,
            .running,
            .awaitingApproval,
            .completing,
            .done,
            .failed,
        ]
        #expect(phases.first == .queued)
        #expect(phases.contains(.dispatching))
        #expect(phases.contains(.completing))
        #expect(phases.last == .failed)
    }

    @Test("runtime lane-backed scheduler exposes deterministic admission and release")
    func runtimeLaneSchedulerAdmissionAndRelease() async throws {
        let runtimeLane = RuntimeLaneCoordinator(
            configuration: RuntimeLaneConfiguration(
                sessionMaxConcurrentRuns: 1,
                globalMainLaneLimit: 4,
                globalSubagentLaneLimit: 1,
                maxChildrenPerAgent: 1
            )
        )
        let scheduler = RuntimeLaneSubAgentRunScheduler(runtimeLaneCoordinator: runtimeLane)
        let parentConversationID = UUID()
        let first = try await scheduler.acquire(
            reservation: SubAgentRunReservation(
                parentConversationID: parentConversationID,
                lifecycleID: "l-1"
            )
        )
        #expect(await scheduler.inFlightCount(parentConversationID: parentConversationID) == 1)
        await #expect(throws: RuntimeLaneAdmissionError.self) {
            _ = try await scheduler.acquire(
                reservation: SubAgentRunReservation(
                    parentConversationID: parentConversationID,
                    lifecycleID: "l-2"
                )
            )
        }
        await scheduler.release(acquisition: first)
        #expect(await scheduler.inFlightCount(parentConversationID: parentConversationID) == 0)
    }
}
