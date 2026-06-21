import Foundation
import SwiftData
import Testing
@testable import SwiftAgentHarness

private enum AgentRuntimeSessionServiceTestSupport {
    static func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    static func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "agent-runtime-service:test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }
}

@Suite("AgentRuntimeSessionService")
struct AgentRuntimeSessionServiceTests {
    @Test("session service is wired on HarnessRuntimeSession with empty orchestrator state")
    func initialOrchestratorState() async throws {
        let container = try AgentRuntimeSessionServiceTestSupport.makeContainer()
        let host = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        await host.agentRuntimeSessionService.clearOrchestratorBinding()
        let conversationID = UUID()
        #expect(await host.agentRuntimeSessionService.orchestrator(for: conversationID) == nil)
    }

    @Test("service snapshot treats stale active run as terminal when no generation task is running")
    func serviceSnapshotTreatsStaleActiveRunAsTerminalWithoutGenerationTask() async throws {
        let container = try AgentRuntimeSessionServiceTestSupport.makeContainer()
        let host = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        let service = await host.agentRuntimeSessionService
        let model = AgentRuntimeSessionServiceTestSupport.makeModel()
        try await host.createConversation(with: model, userSystemPrompt: "sys")
        let conversationID = try #require(await host.currentConversationID)
        let conversation = try #require(await host.currentConversation())
        await host.orchestratorRuntimeService.setupOrchestrator(with: model, activeConversation: conversation)
        let runID = UUID()

        await host.testing_setConversationRuntimeState(
            conversationID: conversationID,
            state: .generating,
            agenticPhase: .started,
            llmRequestPhase: .queued,
            currentRunID: runID
        )
        await service.testing_setActiveStreamingRun(conversationID: conversationID, runID: runID)
        await service.testing_setContentStreamingActive(false)
        await service.testing_setGenerationTaskActive(false)

        let snapshot = try #require(await service.snapshotOrchestrationState(for: conversationID))
        #expect(snapshot.llmRequestPhase == .idle)
        #expect(snapshot.llmRuntimePhase == .idleReady)
        #expect(snapshot.agenticPhase == .idle)
        #expect(snapshot.currentRunID == nil)
    }

    @Test("streaming generation is not settled while task runs without active run id")
    func streamingGenerationUnsettledWhenRunIDMissingButTaskActive() async throws {
        let container = try AgentRuntimeSessionServiceTestSupport.makeContainer()
        let host = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        let service = await host.agentRuntimeSessionService
        let model = AgentRuntimeSessionServiceTestSupport.makeModel()
        try await host.createConversation(with: model, userSystemPrompt: "sys")
        let conversationID = try #require(await host.currentConversationID)
        let conversation = try #require(await host.currentConversation())
        await host.orchestratorRuntimeService.setupOrchestrator(with: model, activeConversation: conversation)
        let runID = UUID()

        await service.testing_setActiveStreamingRun(conversationID: conversationID, runID: runID)
        await service.testing_setCurrentStreamingRunID(nil)

        let settled = await service.streamingGenerationSettled(conversationID: conversationID, runID: runID)
        #expect(settled == false)

        await service.testing_setActiveStreamingRun(conversationID: nil, runID: nil)
    }

    @Test("service orchestration emission deduplicates identical out-of-band pushes")
    func serviceOrchestrationEmissionDeduplicatesOutOfBandPush() async throws {
        let container = try AgentRuntimeSessionServiceTestSupport.makeContainer()
        let host = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        let service = await host.agentRuntimeSessionService
        let model = AgentRuntimeSessionServiceTestSupport.makeModel()
        try await host.createConversation(with: model, userSystemPrompt: "sys")
        let conversationID = try #require(await host.currentConversationID)

        actor PushCapture {
            private(set) var count = 0
            func record() { count += 1 }
            func pushCount() -> Int { count }
        }
        let capture = PushCapture()
        let captureID = UUID()
        await service.setOrchestrationStateOutOfBandPush(id: captureID) { _ in
            await capture.record()
        }

        await service.emitOrchestrationStateFromLiveSources(preferredConversationID: conversationID)
        await service.emitOrchestrationStateFromLiveSources(preferredConversationID: conversationID)

        #expect(await capture.pushCount() == 1)
        await service.clearOrchestrationStateOutOfBandPush(id: captureID)
    }
}
