import EasyJSON
import Foundation
import Testing
import SwiftAgentKit
import SwiftAgentKitOrchestrator
@testable import SwiftAgentHarness

@Suite("Agent loop tool batch dispatch")
struct AgentLoopToolBatchDispatchTests {
    private func makeEntry(
        name: String,
        effectClass: ToolRegistryEntry.EffectClass = .readOnly
    ) -> ToolRegistryEntry {
        ToolRegistryEntry(
            definition: ToolDefinition(name: name, description: "", parameters: [], type: .function),
            source: .local,
            effectClass: effectClass,
            parallelHint: effectClass == .readOnly ? .parallelizable : .serialOnly
        )
    }

    private func allowedDecision(
        blockReason: ToolAvailabilityBlockReason? = nil,
        requiresApproval: Bool = false
    ) -> ToolAvailabilityDecision {
        ToolAvailabilityDecision(
            allowed: blockReason == nil || blockReason == .approvalRequired,
            blockReason: blockReason,
            isSensitive: false,
            requiresEscalation: false,
            requiresApproval: requiresApproval,
            isElevated: false,
            approvalGranted: false,
            approvalRoute: nil,
            delegationPermissionPolicy: nil,
            delegationTrustLevel: nil
        )
    }

    private func makeSnapshot(
        entries: [ToolRegistryEntry],
        parallelEnabled: Bool,
        plannerMode: ToolPolicyConfiguration.DispatchPlannerMode?
    ) -> RuntimeToolTurnPolicySnapshot {
        let snapshots = entries.map {
            RuntimeToolAvailabilitySnapshot(entry: $0, decision: allowedDecision())
        }
        return RuntimeToolTurnPolicySnapshot(
            availabilitySnapshots: snapshots,
            effectiveEntries: entries,
            dispatchContract: AgentRuntimeToolDispatchContract(
                parallelDispatchEnabled: parallelEnabled,
                dispatchPlannerMode: plannerMode,
                pendingToolTimeoutSeconds: nil
            )
        )
    }

    @Test("kitDispatchPlannerMode maps harness modes")
    func plannerModeMapping() {
        #expect(AgentLoopToolDispatch.kitDispatchPlannerMode(nil) == nil)
        #expect(AgentLoopToolDispatch.kitDispatchPlannerMode(.serial) == .serial)
        #expect(AgentLoopToolDispatch.kitDispatchPlannerMode(.allParallel) == .allParallel)
        #expect(AgentLoopToolDispatch.kitDispatchPlannerMode(.mixedDeterministic) == .mixedDeterministic)
    }

    @Test("effective dispatch contract path never emits Kit allParallel")
    func effectiveContractPathNeverEmitsKitAllParallel() {
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let readOnlyEntry = makeEntry(name: "read_a")
        let policy = ToolPolicyConfiguration(
            parallelDispatchEnabled: true,
            dispatchPlannerMode: .allParallel
        )
        let contract = gateway.dispatchContract(from: policy, effectiveEntries: [readOnlyEntry])
        let kitMode = AgentLoopToolDispatch.kitDispatchPlannerMode(contract.dispatchPlannerMode)
        #expect(kitMode == .mixedDeterministic)
        #expect(kitMode != .allParallel)

        let batch = ToolBatchInvocationRequest(
            requests: [
                ToolInvocationRequest(toolName: "read_a", toolCallID: "1"),
                ToolInvocationRequest(toolName: "read_b", toolCallID: "2"),
            ],
            plannerMode: kitMode,
            defaultTimeoutSeconds: nil,
            source: .model,
            parallelToolDispatchEnabled: contract.parallelDispatchEnabled
        )
        #expect(batch.plannerMode != .allParallel)
        #expect(batch.plannerMode == .mixedDeterministic)
    }

    @Test("batchRequiresSerialFallback when any call is approval-gated")
    func serialFallbackOnApprovalRequired() async {
        let readEntry = makeEntry(name: "read_a")
        let gatedEntry = makeEntry(name: "write_b", effectClass: .mutating)
        let snapshots = [
            RuntimeToolAvailabilitySnapshot(entry: readEntry, decision: allowedDecision()),
            RuntimeToolAvailabilitySnapshot(
                entry: gatedEntry,
                decision: allowedDecision(blockReason: .approvalRequired, requiresApproval: true)
            ),
        ]
        let snapshot = RuntimeToolTurnPolicySnapshot(
            availabilitySnapshots: snapshots,
            effectiveEntries: [readEntry, gatedEntry],
            dispatchContract: AgentRuntimeToolDispatchContract(
                parallelDispatchEnabled: true,
                dispatchPlannerMode: .mixedDeterministic,
                pendingToolTimeoutSeconds: nil
            )
        )
        let calls = [
            ToolCallRequest(id: "1", name: "read_a", arguments: .object([:])),
            ToolCallRequest(id: "2", name: "write_b", arguments: .object([:])),
        ]
        let requiresSerial = await AgentLoopToolDispatch.batchRequiresSerialFallback(
            calls: calls,
            snapshot: snapshot,
            configuration: AgentRuntimeTurnConfiguration()
        )
        #expect(requiresSerial)
    }

    @Test("batchRequiresSerialFallback is false for fully allowed read-only batch")
    func noSerialFallbackForAllowedReads() async {
        let entries = [makeEntry(name: "read_a"), makeEntry(name: "read_b")]
        let snapshot = makeSnapshot(
            entries: entries,
            parallelEnabled: true,
            plannerMode: .mixedDeterministic
        )
        let calls = [
            ToolCallRequest(id: "1", name: "read_a", arguments: .object([:])),
            ToolCallRequest(id: "2", name: "read_b", arguments: .object([:])),
        ]
        let requiresSerial = await AgentLoopToolDispatch.batchRequiresSerialFallback(
            calls: calls,
            snapshot: snapshot,
            configuration: AgentRuntimeTurnConfiguration()
        )
        #expect(!requiresSerial)
    }

    @Test("dispatchContract parallel and planner mode propagate into batch request fields")
    func dispatchContractPropagation() {
        let contract = AgentRuntimeToolDispatchContract(
            parallelDispatchEnabled: true,
            dispatchPlannerMode: .mixedDeterministic,
            pendingToolTimeoutSeconds: 30
        )
        #expect(contract.parallelDispatchEnabled == true)
        #expect(AgentLoopToolDispatch.kitDispatchPlannerMode(contract.dispatchPlannerMode) == .mixedDeterministic)
        #expect(contract.pendingToolTimeoutSeconds == 30)

        let batch = ToolBatchInvocationRequest(
            requests: [
                ToolInvocationRequest(toolName: "read_a", toolCallID: "1"),
                ToolInvocationRequest(toolName: "read_b", toolCallID: "2"),
            ],
            plannerMode: AgentLoopToolDispatch.kitDispatchPlannerMode(contract.dispatchPlannerMode),
            defaultTimeoutSeconds: contract.pendingToolTimeoutSeconds,
            source: .model,
            parallelToolDispatchEnabled: contract.parallelDispatchEnabled
        )
        #expect(batch.plannerMode == .mixedDeterministic)
        #expect(batch.parallelToolDispatchEnabled == true)
        #expect(batch.defaultTimeoutSeconds == 30)
        #expect(batch.requests.count == 2)
    }
}

@Suite("TurnLoop batch wiring")
struct TurnLoopBatchWiringTests {
    private func makeModel(id: UUID = UUID()) -> Model {
        Model(
            id: id,
            protocol: .openAIAPI,
            modelName: "turn-loop-batch",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
    }

    @Test("multi tool-call turn commits results in call order via dispatchBatch")
    func multiToolCallCommitsInCallOrder() async throws {
        let model = makeModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            messages: [Message(id: UUID(), role: .user, content: "go", timestamp: Date(), toolCalls: [])],
            turns: [],
            interactionMode: .agent
        )
        let state = TurnLoopConversationState(conversation: conversation)
        let callA = ToolCall(name: "read_a", arguments: .object([:]), id: "a")
        let callB = ToolCall(name: "read_b", arguments: .object([:]), id: "b")
        let streamGate = OnceToolThenDoneStream(toolCalls: [callA, callB])
        let entries = [
            ToolRegistryEntry(
                definition: ToolDefinition(name: "read_a", description: "", parameters: [], type: .function),
                source: .local,
                effectClass: .readOnly,
                parallelHint: .parallelizable
            ),
            ToolRegistryEntry(
                definition: ToolDefinition(name: "read_b", description: "", parameters: [], type: .function),
                source: .local,
                effectClass: .readOnly,
                parallelHint: .parallelizable
            ),
        ]
        let ports = TurnLoopTestPorts.make(
            state: state,
            dispatchOutcomes: [
                .completed(AgentLoopToolDispatch.toolResultMessage(toolCallId: "a", content: "result-a")),
                .completed(AgentLoopToolDispatch.toolResultMessage(toolCallId: "b", content: "result-b")),
            ],
            streamFactory: { await streamGate.nextStream() },
            effectiveToolEntries: entries
        )
        let loop = TurnLoop(ports: ports)
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: false),
            toolManager: ToolManager(providers: [])
        )
        let emitter = AgentRuntimeLifecycleEmitter { _, _ in }
        _ = try await loop.run(
            conversationID: conversation.id,
            runID: UUID(),
            anchorUserMessageID: conversation.messages.first?.id,
            configuration: AgentRuntimeTurnConfiguration(),
            orchestrator: orchestrator,
            lifecycleEmitter: emitter
        )
        let messages = await state.snapshot().messages
        let toolMessages = messages.filter { $0.role == .tool }
        #expect(toolMessages.count == 2)
        #expect(toolMessages[0].toolCallId == "a")
        #expect(toolMessages[0].content == "result-a")
        #expect(toolMessages[1].toolCallId == "b")
        #expect(toolMessages[1].content == "result-b")
    }

    @Test("approval-required mid-batch stops and appends pending for remainder")
    func approvalFallbackStopsBatch() async throws {
        let model = makeModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            messages: [Message(id: UUID(), role: .user, content: "go", timestamp: Date(), toolCalls: [])],
            turns: [],
            interactionMode: .agent
        )
        let state = TurnLoopConversationState(conversation: conversation)
        let callA = ToolCall(name: "read_a", arguments: .object([:]), id: "a")
        let callB = ToolCall(name: "write_b", arguments: .object([:]), id: "b")
        let callC = ToolCall(name: "read_c", arguments: .object([:]), id: "c")
        let streamGate = OnceToolThenDoneStream(toolCalls: [callA, callB, callC])
        let ports = TurnLoopTestPorts.make(
            state: state,
            dispatchOutcomes: [
                .completed(AgentLoopToolDispatch.toolResultMessage(toolCallId: "a", content: "ok-a")),
                .approvalRequired(toolName: "write_b", toolCallID: "b"),
            ],
            streamFactory: { await streamGate.nextStream() }
        )
        let loop = TurnLoop(ports: ports)
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: false),
            toolManager: ToolManager(providers: [])
        )
        let emitter = AgentRuntimeLifecycleEmitter { _, _ in }
        _ = try await loop.run(
            conversationID: conversation.id,
            runID: UUID(),
            anchorUserMessageID: conversation.messages.first?.id,
            configuration: AgentRuntimeTurnConfiguration(),
            orchestrator: orchestrator,
            lifecycleEmitter: emitter
        )
        let messages = await state.snapshot().messages
        let toolMessages = messages.filter { $0.role == .tool }
        #expect(toolMessages.count == 3)
        #expect(toolMessages[0].content == "ok-a")
        #expect(toolMessages[1].content == AgentLoopToolDispatch.approvalPendingToolResultContent)
        #expect(toolMessages[2].content == AgentLoopToolDispatch.approvalPendingToolResultContent)
        #expect(toolMessages[1].toolCallId == "b")
        #expect(toolMessages[2].toolCallId == "c")
    }
}

actor OnceToolThenDoneStream {
    private let toolCalls: [ToolCall]
    private var emittedTools = false

    init(toolCalls: [ToolCall]) {
        self.toolCalls = toolCalls
    }

    func nextStream() -> AsyncThrowingStream<ModelStreamEvent, Error> {
        if !emittedTools {
            emittedTools = true
            let calls = toolCalls
            return AsyncThrowingStream { continuation in
                continuation.yield(.complete(LLMResponse(content: "", toolCalls: calls)))
                continuation.finish()
            }
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.complete(LLMResponse(content: "done", toolCalls: [])))
            continuation.finish()
        }
    }
}
