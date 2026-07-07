import Foundation
import SwiftData
import Testing
import SwiftAgentKit
@testable import SwiftAgentHarness

@Suite("AgentRuntime CLI provenance")
struct AgentRuntimeCLIProvenanceTests {
    private func makeContainer() throws -> ModelContainer {
                return try HarnessTestModelContainer.makeInMemory()
    }

    private func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "cli-provenance",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    @Test("runtime configuration bridging preserves originSurface")
    func bridgingPreservesOriginSurface() {
        let original = AgentRuntimeTurnConfiguration(
            originSurface: InteractiveSurfaceID.cli,
            originSenderID: "*"
        )
        let manager = HarnessRuntimeSession.Configuration(runtimeConfiguration: original)
        let roundTripped = AgentRuntimeTurnConfiguration(managerConfiguration: manager)
        #expect(roundTripped.originSurface == InteractiveSurfaceID.cli)
        #expect(roundTripped.originSenderID == "*")
    }

    @Test("tool approval merge preserves originSurface")
    func toolApprovalMergePreservesOriginSurface() async throws {
        let manager = HarnessRuntimeSession(
            container: try makeContainer(),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        try await manager.createConversation(with: makeModel(), userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)
        let runID = UUID()
        let original = AgentRuntimeTurnConfiguration(
            ephemeralSystemReminder: "Output contract: test",
            originSurface: InteractiveSurfaceID.cli,
            originSenderID: "*"
        )
        let merged = await manager.agentRuntimeSessionService.configurationApplyingToolApprovals(
            original,
            conversationID: conversationID,
            runID: runID
        )
        #expect(merged.originSurface == InteractiveSurfaceID.cli)
        #expect(merged.originSenderID == "*")
        #expect(merged.ephemeralSystemReminder == "Output contract: test")
    }
}

private actor AgentRuntimeCLIProvenanceRecorder {
    var capturedTurnConfiguration: AgentRuntimeTurnConfiguration?

    func recordExecuteTurn(configuration: AgentRuntimeTurnConfiguration) {
        capturedTurnConfiguration = configuration
    }

    func capturedConfiguration() -> AgentRuntimeTurnConfiguration? {
        capturedTurnConfiguration
    }
}

private struct AgentRuntimeCLIProvenanceSpy: AgentRuntimeExecuting {
    let recorder: AgentRuntimeCLIProvenanceRecorder
    let terminalReason = ConversationRunTerminalReason(category: .naturalStop, detail: "cli_provenance_complete")

    func runTurn(_ context: AgentRuntimeRunContext) async -> AgentRuntimeRunResult {
        let _ = context
        return .completed(reason: terminalReason)
    }

    func executeTurn(_ context: AgentRuntimeRunContext) -> AgentRuntimeTurnExecution {
        let (events, continuation) = AsyncStream.makeStream(
            of: RuntimeLifecycleEventPayload.self,
            bufferingPolicy: .unbounded
        )
        let result = Task {
            await recorder.recordExecuteTurn(configuration: context.configuration)
            continuation.finish()
            return AgentRuntimeRunResult.completed(reason: terminalReason)
        }
        return AgentRuntimeTurnExecution(events: events, result: result)
    }
}

extension AgentRuntimeCLIProvenanceTests {
    @Test("harness send applies CLI provenance to turn configuration")
    func harnessSendAppliesCLIProvenance() async throws {
        let recorder = AgentRuntimeCLIProvenanceRecorder()
        let runtime = AgentRuntimeCLIProvenanceSpy(recorder: recorder)
        let manager = HarnessRuntimeSession(
            container: try makeContainer(),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence(),
            runtimeExecutorFactory: { _ in runtime }
        )
        let model = makeModel()
        try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)

        let stream = try await manager.sendMessageAndStreamResponse("hello cli", images: [], conversationID: conversationID)
        for await _ in stream.partialContent {}
        for await _ in stream.orchestrationState {}

        let captured = await recorder.capturedConfiguration()
        #expect(captured?.originSurface == InteractiveSurfaceID.cli)
        #expect(captured?.originSenderID == "*")
        #expect(captured?.ephemeralSystemReminder?.contains("Output contract:") == true)
    }
}
