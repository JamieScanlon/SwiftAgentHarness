import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator
import Testing
@testable import SwiftAgentHarness

@Suite("HarnessRuntimeProtocolWitness")
struct HarnessRuntimeProtocolWitnessTests {
    actor FakeOrchestratorBinding: AgentRuntimeOrchestratorBinding {
        private var storedOrchestrator: SwiftAgentKitOrchestrator?
        private var storedConversationID: UUID?

        func orchestrator(for conversationID: UUID) async -> SwiftAgentKitOrchestrator? {
            storedConversationID == conversationID ? storedOrchestrator : nil
        }
        func lifecycleSnapshot(for conversationID: UUID?) async -> ChatRuntimeLifecycle { ChatRuntimeLifecycle() }
        func clearOrchestratorBinding() async {
            storedOrchestrator = nil
            storedConversationID = nil
        }
        func resetContextTokenSnapshot() async {}
        func recordContextSnapshot(
            for conversationID: UUID,
            from response: LLMResponse,
            requestConfig: LLMRequestConfig
        ) async {}
        func acquireOrchestrator(
            conversationID: UUID,
            modelName: String,
            buildIfMissing: @escaping OrchestratorPoolBuildFactory
        ) async -> OrchestratorAcquisition? { nil }
        func releaseOrchestrator(_ handle: OrchestratorHandle) async {}
        func invalidateOrchestrator(for conversationID: UUID) async {}
    }

    actor FakeOrchestrationEmitting: AgentRuntimeOrchestrationEmitting {
        func emitOrchestrationStateFromLiveSources(
            swiftAgentKitGeneration: UInt64?,
            preferredConversationID: UUID?
        ) async {}
        func streamingGenerationSettled(conversationID: UUID, runID: UUID?) async -> Bool { true }
    }

    actor FakeSpawnLifecycle: SubAgentSpawnLifecycleServicing {
        private(set) var stopHandoffCount = 0
        private(set) var rebuildCount = 0

        func stopCompletionHandoffOwner() async { stopHandoffCount += 1 }
        func rebuildSubAgentLifecycleFromPersistedConversations() async { rebuildCount += 1 }
    }

    @Test("orchestrator binding protocol witness is callable without HarnessRuntimeSession")
    func orchestratorBindingWitness() async {
        let binding: any AgentRuntimeOrchestratorBinding = FakeOrchestratorBinding()
        #expect(await binding.orchestrator(for: UUID()) == nil)
    }

    @Test("orchestration emitting protocol witness is callable without HarnessRuntimeSession")
    func orchestrationEmittingWitness() async {
        let emitting: any AgentRuntimeOrchestrationEmitting = FakeOrchestrationEmitting()
        #expect(await emitting.streamingGenerationSettled(conversationID: UUID(), runID: UUID()) == true)
    }

    @Test("spawn lifecycle protocol witness is callable without HarnessRuntimeSession")
    func spawnLifecycleWitness() async {
        let spawn: any SubAgentSpawnLifecycleServicing = FakeSpawnLifecycle()
        await spawn.stopCompletionHandoffOwner()
        await spawn.rebuildSubAgentLifecycleFromPersistedConversations()
        let fake = spawn as! FakeSpawnLifecycle
        #expect(await fake.stopHandoffCount == 1)
        #expect(await fake.rebuildCount == 1)
    }
}
