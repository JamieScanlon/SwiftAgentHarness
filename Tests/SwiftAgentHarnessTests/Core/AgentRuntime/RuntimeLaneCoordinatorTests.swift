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

    @Test("isRunAdmitted tracks admission until release")
    func isRunAdmittedTracksAdmission() async {
        let coordinator = RuntimeLaneCoordinator()
        let runID = UUID()
        #expect(await coordinator.isRunAdmitted(runID: runID) == false)
        #expect(await coordinator.tryAcquireMainRun(sessionKey: "session:admit", runID: runID) == nil)
        #expect(await coordinator.isRunAdmitted(runID: runID) == true)
        await coordinator.release(runID: runID)
        #expect(await coordinator.isRunAdmitted(runID: runID) == false)
    }

    @Test("global main lane cap is enforced")
    func globalMainLaneCap() async {
        let coordinator = RuntimeLaneCoordinator(
            configuration: RuntimeLaneConfiguration(
                sessionMaxConcurrentRuns: 1,
                globalMainLaneLimit: 2,
                globalSubagentLaneLimit: 8,
                globalCronLaneLimit: 2,
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

    @Test("per-owner subagent lane cap isolates owners")
    func perOwnerSubagentLaneCap() async {
        let ownerA = UUID()
        let ownerB = UUID()
        let coordinator = RuntimeLaneCoordinator(
            configuration: RuntimeLaneConfiguration(
                sessionMaxConcurrentRuns: 1,
                globalMainLaneLimit: 4,
                globalSubagentLaneLimit: 8,
                globalCronLaneLimit: 2,
                maxChildrenPerAgent: 5,
                perOwnerSubagentLaneLimit: 1
            )
        )
        #expect(
            await coordinator.tryAcquireSubagentRun(
                parentRunID: nil,
                parentConversationID: UUID(),
                ownerAccountID: ownerA,
                runID: UUID()
            ) == nil
        )
        #expect(
            await coordinator.tryAcquireSubagentRun(
                parentRunID: nil,
                parentConversationID: UUID(),
                ownerAccountID: ownerA,
                runID: UUID()
            ) == .perOwnerSubagentLaneAtCapacity(limit: 1)
        )
        #expect(
            await coordinator.tryAcquireSubagentRun(
                parentRunID: nil,
                parentConversationID: UUID(),
                ownerAccountID: ownerB,
                runID: UUID()
            ) == nil
        )
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

    @Test("global cron lane cap is enforced independently of main lane")
    func globalCronLaneCapIndependentOfMain() async {
        let coordinator = RuntimeLaneCoordinator(
            configuration: RuntimeLaneConfiguration(
                sessionMaxConcurrentRuns: 1,
                globalMainLaneLimit: 1,
                globalSubagentLaneLimit: 8,
                globalCronLaneLimit: 2,
                maxChildrenPerAgent: 5
            )
        )
        let mainRun = UUID()
        let cronA = UUID()
        let cronB = UUID()
        let cronC = UUID()

        #expect(
            await coordinator.tryAcquire(
                RunLaneResolver.resolve(
                    RunLaneOriginContext(sessionKey: "session:main", runID: mainRun, origin: .interactive)
                )
            ) == nil
        )
        #expect(
            await coordinator.tryAcquire(
                RunLaneResolver.resolve(
                    RunLaneOriginContext(sessionKey: "session:cron-a", runID: cronA, origin: .trigger(.cron))
                )
            ) == nil
        )
        #expect(
            await coordinator.tryAcquire(
                RunLaneResolver.resolve(
                    RunLaneOriginContext(sessionKey: "session:cron-b", runID: cronB, origin: .trigger(.cron))
                )
            ) == nil
        )
        #expect(
            await coordinator.tryAcquire(
                RunLaneResolver.resolve(
                    RunLaneOriginContext(sessionKey: "session:cron-c", runID: cronC, origin: .trigger(.cron))
                )
            ) == .globalCronLaneAtCapacity(limit: 2)
        )
        #expect(
            await coordinator.tryAcquireMainRun(sessionKey: "session:main-2", runID: UUID())
            == .globalMainLaneAtCapacity(limit: 1)
        )
    }

    @Test("cron and main lanes can both be at capacity without sharing counter")
    func cronAndMainLanesSeparateCounters() async {
        let coordinator = RuntimeLaneCoordinator(
            configuration: RuntimeLaneConfiguration(
                sessionMaxConcurrentRuns: 1,
                globalMainLaneLimit: 1,
                globalSubagentLaneLimit: 8,
                globalCronLaneLimit: 1,
                maxChildrenPerAgent: 5
            )
        )
        let mainRun = UUID()
        let cronRun = UUID()

        #expect(
            await coordinator.tryAcquireMainRun(sessionKey: "session:main", runID: mainRun) == nil
        )
        #expect(
            await coordinator.tryAcquire(
                RunLaneResolver.resolve(
                    RunLaneOriginContext(sessionKey: "session:cron", runID: cronRun, origin: .trigger(.cron))
                )
            ) == nil
        )
        #expect(
            await coordinator.tryAcquireMainRun(sessionKey: "session:main-2", runID: UUID())
            == .globalMainLaneAtCapacity(limit: 1)
        )
        #expect(
            await coordinator.tryAcquire(
                RunLaneResolver.resolve(
                    RunLaneOriginContext(sessionKey: "session:cron-2", runID: UUID(), origin: .trigger(.cron))
                )
            ) == .globalCronLaneAtCapacity(limit: 1)
        )
    }

    @Test("release by run ID uses stored admission context")
    func releaseByRunIDUsesStoredContext() async {
        let coordinator = RuntimeLaneCoordinator(
            configuration: RuntimeLaneConfiguration(
                sessionMaxConcurrentRuns: 1,
                globalMainLaneLimit: 1,
                globalSubagentLaneLimit: 8,
                globalCronLaneLimit: 1,
                maxChildrenPerAgent: 5
            )
        )
        let cronRun = UUID()
        let context = RunLaneResolver.resolve(
            RunLaneOriginContext(sessionKey: "session:cron", runID: cronRun, origin: .trigger(.cron))
        )
        #expect(await coordinator.tryAcquire(context) == nil)
        #expect(
            await coordinator.tryAcquire(
                RunLaneResolver.resolve(
                    RunLaneOriginContext(sessionKey: "session:cron-2", runID: UUID(), origin: .trigger(.cron))
                )
            ) == .globalCronLaneAtCapacity(limit: 1)
        )

        await coordinator.release(runID: cronRun)

        #expect(
            await coordinator.tryAcquire(
                RunLaneResolver.resolve(
                    RunLaneOriginContext(sessionKey: "session:cron-3", runID: UUID(), origin: .trigger(.cron))
                )
            ) == nil
        )
    }
}
