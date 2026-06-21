import Foundation
import Testing
import SwiftAgentKit
import SwiftAgentKitOrchestrator
@testable import SwiftAgentHarness

@Suite("AgentRuntimeOrchestrationCore")
struct AgentRuntimeOrchestrationCoreTests {
    private func makeBuilt(conversationID: UUID) -> BuiltOrchestrator {
        BuiltOrchestrator(
            orchestrator: SwiftAgentKitOrchestrator(
                llm: StubTurnLoopLLM(),
                config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
            ),
            queuedLLM: QueuedLLM(baseLLM: StatefulLLM(baseLLM: StubTurnLoopLLM())),
            conversationID: conversationID
        )
    }

    @Test("clear binding removes pooled orchestrator")
    func clearBinding() async {
        let core = AgentRuntimeOrchestrationCore()
        let conversationID = UUID()
        let acquisition = await core.acquireOrchestrator(
            conversationID: conversationID,
            modelName: "core:test",
            buildIfMissing: { makeBuilt(conversationID: conversationID) }
        )
        #expect(acquisition != nil)
        #expect(await core.orchestrator(for: conversationID) != nil)
        await core.clearOrchestratorBinding()
        #expect(await core.orchestrator(for: conversationID) == nil)
    }

    @Test("lifecycle mutate and token snapshots")
    func lifecycleAndTokens() async {
        let core = AgentRuntimeOrchestrationCore()
        let conversationID = UUID()
        let runID = UUID()
        let acquisition = await core.acquireOrchestrator(
            conversationID: conversationID,
            modelName: "core:test",
            buildIfMissing: { makeBuilt(conversationID: conversationID) }
        )
        guard let acquisition else {
            Issue.record("Expected pool acquisition")
            return
        }
        await core.updateLifecycle(for: conversationID) { lifecycle in
            lifecycle.currentStreamingRunID = runID
            lifecycle.isContentStreamingActive = true
        }
        let lifecycle = await core.lifecycleSnapshot(for: conversationID)
        #expect(lifecycle.currentStreamingRunID == runID)
        #expect(lifecycle.isContentStreamingActive)

        await core.testing_setLastPromptTokens(42, conversationID: conversationID)
        await core.testing_setLastContextLimitTokens(128_000, conversationID: conversationID)
        let tokens = await core.tokenSnapshotsForOrchestration(for: conversationID)
        #expect(tokens.lastPromptTokens == 42)
        #expect(tokens.lastContextLimitTokens == 128_000)

        await core.resetTokenSnapshot(for: conversationID)
        let cleared = await core.tokenSnapshotsForOrchestration(for: conversationID)
        #expect(cleared.lastPromptTokens == nil)
        #expect(cleared.lastContextLimitTokens == nil)
        await core.releaseOrchestrator(acquisition.handle)
    }

    @Test("residual orchestration emission conversation id")
    func residualEmissionID() async {
        let core = AgentRuntimeOrchestrationCore()
        #expect(await core.lastOrchestrationEmissionConversationID() == nil)
        let id = UUID()
        await core.setOrchestrationEmissionConversationID(id)
        #expect(await core.lastOrchestrationEmissionConversationID() == id)
    }
}
