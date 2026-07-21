import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Run lane resolver")
struct RunLaneResolverTests {
    @Test("interactive origin resolves to main lane")
    func interactiveResolvesToMain() {
        let runID = UUID()
        let context = RunLaneResolver.resolve(
            RunLaneOriginContext(
                sessionKey: "session:a",
                runID: runID,
                origin: .interactive
            )
        )
        #expect(context.globalLane == .main)
        #expect(context.originSurface == "interactive")
    }

    @Test("cron trigger origin resolves to cron lane")
    func cronTriggerResolvesToCron() {
        let runID = UUID()
        let context = RunLaneResolver.resolve(
            RunLaneOriginContext(
                sessionKey: "session:a",
                runID: runID,
                origin: .trigger(.cron)
            )
        )
        #expect(context.globalLane == .cron)
        #expect(context.originSurface == "cron")
    }

    @Test("webhook trigger origin resolves to main lane")
    func webhookTriggerResolvesToMain() {
        let runID = UUID()
        let context = RunLaneResolver.resolve(
            RunLaneOriginContext(
                sessionKey: "session:a",
                runID: runID,
                origin: .trigger(.webhook)
            )
        )
        #expect(context.globalLane == .main)
        #expect(context.originSurface == "webhook")
    }

    @Test("sub-agent spawn resolves to subagent lane and never inherits parent cron")
    func subagentSpawnResolvesToSubagentLane() {
        let parentRunID = UUID()
        let parentConversationID = UUID()
        let runID = UUID()
        let context = RunLaneResolver.resolve(
            RunLaneOriginContext(
                sessionKey: "subagent:\(parentConversationID.uuidString.lowercased())",
                runID: runID,
                origin: .subagentSpawn,
                parentRunID: parentRunID,
                parentConversationID: parentConversationID
            )
        )
        #expect(context.globalLane == .subagent)
        #expect(context.originSurface == "subagent")
        #expect(context.parentRunID == parentRunID)
        #expect(context.parentConversationID == parentConversationID)
    }

    @Test("pending completion resume resolves to main lane")
    func pendingCompletionResumeResolvesToMain() {
        let runID = UUID()
        let context = RunLaneResolver.resolve(
            RunLaneOriginContext(
                sessionKey: "session:a",
                runID: runID,
                origin: .pendingCompletionResume
            )
        )
        #expect(context.globalLane == .main)
        #expect(context.originSurface == "pending_completion_resume")
    }

    @Test("plan exit denial resume resolves to main lane")
    func planExitDenialResumeResolvesToMain() {
        let runID = UUID()
        let context = RunLaneResolver.resolve(
            RunLaneOriginContext(
                sessionKey: "session:a",
                runID: runID,
                origin: .planExitDenialResume
            )
        )
        #expect(context.globalLane == .main)
        #expect(context.originSurface == "plan_exit_denial_resume")
    }

    @Test("runLaneOrigin maps origin surface strings")
    func runLaneOriginFromOriginSurface() {
        #expect(RunLaneResolver.runLaneOrigin(originSurface: nil) == .interactive)
        #expect(RunLaneResolver.runLaneOrigin(originSurface: "") == .interactive)
        #expect(RunLaneResolver.runLaneOrigin(originSurface: "tui") == .interactive)
        #expect(RunLaneResolver.runLaneOrigin(originSurface: TriggerSource.cron.rawValue) == .trigger(.cron))
        #expect(RunLaneResolver.runLaneOrigin(originSurface: TriggerSource.webhook.rawValue) == .trigger(.webhook))
    }
}
