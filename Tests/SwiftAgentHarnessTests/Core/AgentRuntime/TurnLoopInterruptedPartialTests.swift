import Foundation
import Testing
import SwiftAgentKit
import SwiftAgentKitOrchestrator
@testable import SwiftAgentHarness

@Suite("TurnLoop interrupted partial persistence")
struct TurnLoopInterruptedPartialTests {
    private func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "interrupted-partial",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
    }

    private func makeConversation(model: Model) -> ModelConversation {
        ModelConversation(
            id: UUID(),
            model: model,
            messages: [Message(id: UUID(), role: .user, content: "go", timestamp: Date(), toolCalls: [])],
            turns: [],
            interactionMode: .chat
        )
    }

    private func hangingPartialStream(content: String) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.stream(LLMResponse(content: content, toolCalls: [])))
            continuation.finish()
        }
    }

    private func cancellationAfterPartialStream(content: String) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.stream(LLMResponse(content: content, toolCalls: [])))
            continuation.finish(throwing: CancellationError())
        }
    }

    private func emptyHangingStream() -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    @Test("user stop mid-stream persists partial assistant with interrupted finishReason")
    func userStopMidStreamPersistsPartial() async throws {
        let model = makeModel()
        let conversation = makeConversation(model: model)
        let state = TurnLoopConversationState(conversation: conversation)
        let finishReasonRecorder = TurnLoopFinishReasonRecorder()
        let markerRecorder = TurnLoopMarkerRecorder()
        let ports = TurnLoopTestPorts.make(
            state: state,
            streamFactory: { self.hangingPartialStream(content: "Hello partial") },
            finishReasonRecorder: finishReasonRecorder,
            markerRecorder: markerRecorder,
            stopRequestedFn: { _ in true }
        )
        let loop = TurnLoop(ports: ports)
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        let reason = try await loop.run(
            conversationID: conversation.id,
            runID: UUID(),
            anchorUserMessageID: await state.anchorUserMessageID(),
            configuration: AgentRuntimeTurnConfiguration(),
            orchestrator: orchestrator,
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, _ in }
        )
        #expect(reason.category == .externalCancellation)
        #expect(reason.detail == "user_stop_requested")
        let messages = await state.snapshot().messages
        #expect(messages.contains(where: { $0.role == .assistant && $0.content == "Hello partial" }))
        let stamps = await finishReasonRecorder.recordedStamps()
        #expect(stamps.count == 1)
        #expect(stamps.first?.finishReason == "interrupted")
        #expect(await markerRecorder.recordedMarkers().count == 1)
    }

    @Test("CancellationError mid-stream persists partial assistant with interrupted finishReason")
    func cancellationErrorMidStreamPersistsPartial() async throws {
        let model = makeModel()
        let conversation = makeConversation(model: model)
        let state = TurnLoopConversationState(conversation: conversation)
        let finishReasonRecorder = TurnLoopFinishReasonRecorder()
        let markerRecorder = TurnLoopMarkerRecorder()
        let ports = TurnLoopTestPorts.make(
            state: state,
            streamFactory: { self.cancellationAfterPartialStream(content: "Partial before cancel") },
            finishReasonRecorder: finishReasonRecorder,
            markerRecorder: markerRecorder
        )
        let loop = TurnLoop(ports: ports)
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        let reason = try await loop.run(
            conversationID: conversation.id,
            runID: UUID(),
            anchorUserMessageID: await state.anchorUserMessageID(),
            configuration: AgentRuntimeTurnConfiguration(),
            orchestrator: orchestrator,
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, _ in }
        )
        #expect(reason.category == .externalCancellation)
        #expect(reason.detail == "task_cancelled")
        let messages = await state.snapshot().messages
        #expect(messages.contains(where: { $0.role == .assistant && $0.content == "Partial before cancel" }))
        let stamps = await finishReasonRecorder.recordedStamps()
        #expect(stamps.count == 1)
        #expect(stamps.first?.finishReason == "interrupted")
        #expect(await markerRecorder.recordedMarkers().count == 1)
    }

    @Test("empty partial on cancel does not append assistant")
    func emptyPartialOnCancelDoesNotAppend() async throws {
        let model = makeModel()
        let conversation = makeConversation(model: model)
        let state = TurnLoopConversationState(conversation: conversation)
        let finishReasonRecorder = TurnLoopFinishReasonRecorder()
        let markerRecorder = TurnLoopMarkerRecorder()
        let ports = TurnLoopTestPorts.make(
            state: state,
            streamFactory: { self.emptyHangingStream() },
            finishReasonRecorder: finishReasonRecorder,
            markerRecorder: markerRecorder,
            stopRequestedFn: { _ in true }
        )
        let loop = TurnLoop(ports: ports)
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        let reason = try await loop.run(
            conversationID: conversation.id,
            runID: UUID(),
            anchorUserMessageID: await state.anchorUserMessageID(),
            configuration: AgentRuntimeTurnConfiguration(),
            orchestrator: orchestrator,
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, _ in }
        )
        #expect(reason.category == .externalCancellation)
        let messages = await state.snapshot().messages
        #expect(!messages.contains(where: { $0.role == .assistant }))
        #expect(await finishReasonRecorder.recordedStamps().isEmpty)
        #expect(await markerRecorder.recordedMarkers().count == 1)
    }

    @Test("timeout with partial persists assistant before throwing")
    func timeoutWithPartialPersistsBeforeThrow() async throws {
        let model = makeModel()
        let conversation = makeConversation(model: model)
        let state = TurnLoopConversationState(conversation: conversation)
        let finishReasonRecorder = TurnLoopFinishReasonRecorder()
        let ports = TurnLoopTestPorts.make(
            state: state,
            streamFactory: { self.hangingPartialStream(content: "Timed out partial") },
            finishReasonRecorder: finishReasonRecorder,
            stopRequestedFn: { _ in false }
        )
        let loop = TurnLoop(ports: ports)
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        await #expect(throws: LLMError.self) {
            _ = try await loop.run(
                conversationID: conversation.id,
                runID: UUID(),
                anchorUserMessageID: await state.anchorUserMessageID(),
                configuration: AgentRuntimeTurnConfiguration(),
                orchestrator: orchestrator,
                lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, _ in }
            )
        }
        let messages = await state.snapshot().messages
        #expect(messages.contains(where: { $0.role == .assistant && $0.content == "Timed out partial" }))
        let stamps = await finishReasonRecorder.recordedStamps()
        #expect(stamps.count == 1)
        #expect(stamps.first?.finishReason == "interrupted")
    }
}
