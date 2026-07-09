import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator
import Testing
@testable import SwiftAgentHarness

private struct ContextAssemblyFailure: Error {}

private struct AfterTurnInvocation: Sendable {
    let conversationID: UUID
    let runID: UUID?
    let terminalReason: ConversationRunTerminalReason?
    let anchorUserMessageID: UUID?
}

private actor AfterTurnRecordingRuntime: AgentRuntimeCoordinatorServicing {
    private let ports: AgentLoopPorts
    private var invocations: [AfterTurnInvocation] = []

    init(ports: AgentLoopPorts) {
        self.ports = ports
    }

    func afterTurnContextEngineLifecycle(
        conversationID: UUID,
        runID: UUID?,
        terminalReason: ConversationRunTerminalReason?,
        anchorUserMessageID: UUID?
    ) async {
        invocations.append(
            AfterTurnInvocation(
                conversationID: conversationID,
                runID: runID,
                terminalReason: terminalReason,
                anchorUserMessageID: anchorUserMessageID
            )
        )
    }

    func makeAgentLoopPorts() async -> AgentLoopPorts {
        ports
    }

    func publishAgentLoopDelta(
        _ partial: ChatStreamingPartial,
        conversationID: UUID,
        runID: UUID?
    ) async {
        let _ = partial
        let _ = conversationID
        let _ = runID
    }

    func invocationCount() -> Int {
        invocations.count
    }

    func lastInvocation() -> AfterTurnInvocation? {
        invocations.last
    }
}

@Suite("AgentRuntimeCoordinator after-turn lifecycle")
struct AgentRuntimeCoordinatorAfterTurnTests {
    private func makeRunContext(
        conversationID: UUID,
        runID: UUID,
        anchorUserMessageID: UUID?
    ) -> AgentRuntimeRunContext {
        let scope = ConversationScope(
            selfID: conversationID,
            parentID: nil,
            rootID: conversationID,
            lineageKind: .root,
            origin: .user
        )
        return AgentRuntimeRunContext(
            conversationID: conversationID,
            conversationScope: scope,
            runID: runID,
            turnLoopAnchorUserMessageID: anchorUserMessageID,
            configuration: AgentRuntimeTurnConfiguration(),
            orchestrator: SwiftAgentKitOrchestrator(
                llm: StubTurnLoopLLM(),
                config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
            ),
            runtimeLifecyclePublish: nil,
            lifecycleEmitterOverride: nil
        )
    }

    private func makeConversationState(conversationID: UUID) -> TurnLoopConversationState {
        TurnLoopConversationState(
            conversation: ModelConversation(
                id: conversationID,
                model: Model(
                    protocol: .openAIAPI,
                    modelName: "test",
                    serverURL: URL(string: "http://localhost:1")!,
                    capabilities: [.completion],
                    modelProtocol: .openAIAPI
                ),
                messages: [
                    Message(
                        id: UUID(),
                        role: .user,
                        content: "hello",
                        timestamp: Date(),
                        toolCalls: []
                    ),
                ],
                turns: [],
                interactionMode: .chat
            )
        )
    }

    private func makeThrowingAssemblePorts(state: TurnLoopConversationState) -> AgentLoopPorts {
        let conversationPort = SessionRuntimeConversationPort(
            conversationFn: { _ in await state.snapshot() },
            appendFn: { message, _, _ in await state.append(message) },
            markerFn: { _, _, _ in },
            rollbackFn: { _, _ in },
            stampFinishReasonFn: { _, _, _ in },
            stopRequestedFn: { _ in false }
        )
        let contextPort = SessionRuntimeContextPort(
            bootstrapFn: { _, _ in },
            assembleFn: { _, _, _, _, _ in throw ContextAssemblyFailure() },
            afterTurnFn: { _, _, _ in }
        )
        let emptySnapshot = RuntimeToolTurnPolicySnapshot(
            availabilitySnapshots: [],
            effectiveEntries: [],
            dispatchContract: .conservativeDefault
        )
        let modelPort = SessionRuntimeModelPort(
            ensureBoundFn: { conv, _ in conv.model.id },
            streamLLM: { _, _, _, _, _, _, _ in
                AsyncThrowingStream { $0.finish() }
            }
        )
        let toolPort = SessionRuntimeToolPort(
            consumeApprovalTimeoutsFn: { _, _, _, _, _ in },
            effectiveToolsFn: { _, _, _, _ in emptySnapshot },
            dispatchFn: { _, _, _, _, _, _, _, _, _, _ in
                .completed(
                    Message(
                        id: UUID(),
                        role: .tool,
                        content: "ok",
                        timestamp: Date(),
                        toolCalls: []
                    )
                )
            },
            dispatchApprovalFn: { _, _, _, _, _, _, _ in },
            isHaltingFn: { _, _ in false }
        )
        return AgentLoopPorts(
            model: modelPort,
            context: contextPort,
            tools: toolPort,
            conversation: conversationPort,
            memory: nil,
            agentHarness: .default,
            contextCompaction: .default,
            modeRegistry: ModeRegistryTestSupport.makePort(seedingBuiltIns: true),
            logger: nil
        )
    }

    @Test("afterTurn runs when loop throws during context assembly")
    func afterTurnRunsOnAssemblyFailure() async throws {
        let conversationID = UUID()
        let runID = UUID()
        let state = makeConversationState(conversationID: conversationID)
        let anchorUserMessageID = await state.anchorUserMessageID()
        let runtime = AfterTurnRecordingRuntime(ports: makeThrowingAssemblePorts(state: state))
        let coordinator = AgentRuntimeCoordinator(runtime: runtime)
        let context = makeRunContext(
            conversationID: conversationID,
            runID: runID,
            anchorUserMessageID: anchorUserMessageID
        )

        let result = await coordinator.runTurn(context)

        #expect(result.terminalState == .failed)
        #expect(await runtime.invocationCount() == 1)
        let invocation = await runtime.lastInvocation()
        #expect(invocation?.conversationID == conversationID)
        #expect(invocation?.runID == runID)
        #expect(invocation?.terminalReason == nil)
        #expect(invocation?.anchorUserMessageID == anchorUserMessageID)
    }

    @Test("afterTurn runs with terminal reason when loop completes")
    func afterTurnRunsOnSuccessfulTurn() async throws {
        let conversationID = UUID()
        let runID = UUID()
        let state = makeConversationState(conversationID: conversationID)
        let anchorUserMessageID = await state.anchorUserMessageID()
        let ports = TurnLoopTestPorts.make(
            state: state,
            streamFactory: {
                AsyncThrowingStream { continuation in
                    continuation.yield(.complete(LLMResponse(content: "done", toolCalls: [])))
                    continuation.finish()
                }
            }
        )
        let runtime = AfterTurnRecordingRuntime(ports: ports)
        let coordinator = AgentRuntimeCoordinator(runtime: runtime)
        let context = makeRunContext(
            conversationID: conversationID,
            runID: runID,
            anchorUserMessageID: anchorUserMessageID
        )

        let result = await coordinator.runTurn(context)

        #expect(result.terminalState == .completed)
        #expect(await runtime.invocationCount() == 1)
        let invocation = await runtime.lastInvocation()
        #expect(invocation?.conversationID == conversationID)
        #expect(invocation?.runID == runID)
        #expect(invocation?.terminalReason != nil)
        #expect(invocation?.anchorUserMessageID == anchorUserMessageID)
    }
}
