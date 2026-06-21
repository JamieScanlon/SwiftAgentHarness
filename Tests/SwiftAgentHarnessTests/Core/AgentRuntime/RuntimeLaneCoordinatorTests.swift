import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Runtime lane coordinator")
struct RuntimeLaneCoordinatorTests {
    @Test("session lane allows one active run per key")
    func sessionLaneSingleActiveRun() async {
        let coordinator = RuntimeLaneCoordinator()
        let runA = UUID()
        let runB = UUID()
        let sessionKey = "session:test"
        #expect(await coordinator.tryAcquireMainRun(sessionKey: sessionKey, runID: runA) == nil)
        #expect(await coordinator.tryAcquireMainRun(sessionKey: sessionKey, runID: runB) == .sessionLaneBusy(activeRunID: runA))
        await coordinator.releaseMainRun(sessionKey: sessionKey, runID: runA)
        #expect(await coordinator.tryAcquireMainRun(sessionKey: sessionKey, runID: runB) == nil)
    }

    @Test("global main lane cap is enforced")
    func globalMainLaneCap() async {
        let coordinator = RuntimeLaneCoordinator(
            configuration: RuntimeLaneConfiguration(
                sessionMaxConcurrentRuns: 1,
                globalMainLaneLimit: 2,
                globalSubagentLaneLimit: 8,
                maxChildrenPerAgent: 5
            )
        )
        let first = UUID()
        let second = UUID()
        let third = UUID()
        #expect(await coordinator.tryAcquireMainRun(sessionKey: "session:a", runID: first) == nil)
        #expect(await coordinator.tryAcquireMainRun(sessionKey: "session:b", runID: second) == nil)
        #expect(await coordinator.tryAcquireMainRun(sessionKey: "session:c", runID: third) == .globalMainLaneAtCapacity(limit: 2))
    }

    @Test("per-parent fanout cap is enforced for subagent runs")
    func subagentFanoutCap() async {
        let coordinator = RuntimeLaneCoordinator(
            configuration: RuntimeLaneConfiguration(
                sessionMaxConcurrentRuns: 1,
                globalMainLaneLimit: 4,
                globalSubagentLaneLimit: 8,
                maxChildrenPerAgent: 2
            )
        )
        let parent = UUID()
        #expect(await coordinator.tryAcquireSubagentRun(parentRunID: parent, runID: UUID()) == nil)
        #expect(await coordinator.tryAcquireSubagentRun(parentRunID: parent, runID: UUID()) == nil)
        #expect(await coordinator.tryAcquireSubagentRun(parentRunID: parent, runID: UUID()) == .parentFanoutExceeded(limit: 2))
    }

    @Test("parent conversation identity enforces fanout when parent run is absent")
    func subagentFanoutCapByParentConversationID() async {
        let coordinator = RuntimeLaneCoordinator(
            configuration: RuntimeLaneConfiguration(
                sessionMaxConcurrentRuns: 1,
                globalMainLaneLimit: 4,
                globalSubagentLaneLimit: 8,
                maxChildrenPerAgent: 1
            )
        )
        let parentConversationID = UUID()
        #expect(
            await coordinator.tryAcquireSubagentRun(
                parentRunID: nil,
                parentConversationID: parentConversationID,
                runID: UUID()
            ) == nil
        )
        #expect(
            await coordinator.tryAcquireSubagentRun(
                parentRunID: nil,
                parentConversationID: parentConversationID,
                runID: UUID()
            ) == .parentFanoutExceeded(limit: 1)
        )
    }
}
