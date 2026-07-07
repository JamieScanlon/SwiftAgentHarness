import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Sub-agent lane lifecycle")
struct SubAgentLaneLifecycleTests {
    private func makeCoordinator(
        globalSubagentLaneLimit: Int = 1,
        maxChildrenPerAgent: Int = 1
    ) -> SubAgentInvocationCoordinator {
        let runtimeLane = RuntimeLaneCoordinator(
            configuration: RuntimeLaneConfiguration(
                sessionMaxConcurrentRuns: 1,
                globalMainLaneLimit: 4,
                globalSubagentLaneLimit: globalSubagentLaneLimit,
                maxChildrenPerAgent: maxChildrenPerAgent
            )
        )
        let scheduler = RuntimeLaneSubAgentRunScheduler(runtimeLaneCoordinator: runtimeLane)
        return SubAgentInvocationCoordinator(scheduler: scheduler)
    }

    private func reservation(
        parentConversationID: UUID = UUID(),
        lifecycleID: String
    ) -> SubAgentRunReservation {
        SubAgentRunReservation(
            parentConversationID: parentConversationID,
            lifecycleID: lifecycleID
        )
    }

    @Test("lane slot held until lifecycle release")
    func laneSlotHeldUntilLifecycleRelease() async throws {
        let coordinator = makeCoordinator()
        let parentConversationID = UUID()
        let first = try await coordinator.beginInvocation(
            reservation: reservation(parentConversationID: parentConversationID, lifecycleID: "l-1")
        )
        #expect(await coordinator.inFlightCount(parentConversationID: parentConversationID) == 1)

        await #expect(throws: RuntimeLaneAdmissionError.self) {
            _ = try await coordinator.beginInvocation(
                reservation: reservation(parentConversationID: parentConversationID, lifecycleID: "l-2")
            )
        }

        await coordinator.endInvocation(lifecycleID: first.reservation.lifecycleID)
        #expect(await coordinator.inFlightCount(parentConversationID: parentConversationID) == 0)

        _ = try await coordinator.beginInvocation(
            reservation: reservation(parentConversationID: parentConversationID, lifecycleID: "l-3")
        )
        #expect(await coordinator.inFlightCount(parentConversationID: parentConversationID) == 1)
    }

    @Test("endInvocation by lifecycleID is idempotent")
    func endInvocationByLifecycleIDIsIdempotent() async throws {
        let coordinator = makeCoordinator(maxChildrenPerAgent: 2)
        let parentConversationID = UUID()
        let first = try await coordinator.beginInvocation(
            reservation: reservation(parentConversationID: parentConversationID, lifecycleID: "l-1")
        )
        #expect(await coordinator.inFlightCount(parentConversationID: parentConversationID) == 1)

        await coordinator.endInvocation(lifecycleID: first.reservation.lifecycleID)
        #expect(await coordinator.inFlightCount(parentConversationID: parentConversationID) == 0)

        await coordinator.endInvocation(lifecycleID: first.reservation.lifecycleID)
        #expect(await coordinator.inFlightCount(parentConversationID: parentConversationID) == 0)

        _ = try await coordinator.beginInvocation(
            reservation: reservation(parentConversationID: parentConversationID, lifecycleID: "l-2")
        )
        #expect(await coordinator.inFlightCount(parentConversationID: parentConversationID) == 1)
    }

    @Test("spawn failure after admission releases slot")
    func spawnFailureAfterAdmissionReleasesSlot() async throws {
        let coordinator = makeCoordinator()
        let parentConversationID = UUID()
        let lifecycleID = "spawn-failure"

        do {
            _ = try await coordinator.beginInvocation(
                reservation: reservation(parentConversationID: parentConversationID, lifecycleID: lifecycleID)
            )
            #expect(await coordinator.inFlightCount(parentConversationID: parentConversationID) == 1)

            var runLaneHandoffCommitted = false
            defer {
                if !runLaneHandoffCommitted {
                    Task {
                        await coordinator.endInvocation(lifecycleID: lifecycleID)
                    }
                }
            }

            #expect(runLaneHandoffCommitted == false)
            throw SubAgentPoolError.operationFailed(reason: "simulated spawn failure")
        } catch SubAgentPoolError.operationFailed {
            try await Task.sleep(for: .milliseconds(50))
            #expect(await coordinator.inFlightCount(parentConversationID: parentConversationID) == 0)
        }
    }

    @Test("terminal lifecycle phase releases held lane slot")
    func terminalLifecyclePhaseReleasesHeldLaneSlot() async throws {
        let runtimeLane = RuntimeLaneCoordinator(
            configuration: RuntimeLaneConfiguration(
                sessionMaxConcurrentRuns: 1,
                globalMainLaneLimit: 4,
                globalSubagentLaneLimit: 1,
                maxChildrenPerAgent: 1
            )
        )
        let scheduler = RuntimeLaneSubAgentRunScheduler(runtimeLaneCoordinator: runtimeLane)
        let coordinator = SubAgentInvocationCoordinator(scheduler: scheduler)
        let parentConversationID = UUID()
        let lifecycleID = "terminal-release"

        _ = try await coordinator.beginInvocation(
            reservation: reservation(parentConversationID: parentConversationID, lifecycleID: lifecycleID)
        )
        #expect(await coordinator.inFlightCount(parentConversationID: parentConversationID) == 1)

        await coordinator.endInvocation(lifecycleID: lifecycleID)
        #expect(await scheduler.inFlightCount(parentConversationID: parentConversationID) == 0)
    }
}
