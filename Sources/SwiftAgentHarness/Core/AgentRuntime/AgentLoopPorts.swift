import EasyJSON
import Foundation
import Logging
import SwiftAgentKit
import SwiftAgentKitOrchestrator

enum CompactionHint: Sendable {
    case normal
    case forceCompaction
}

struct ResolvedModelHandle: Sendable {
    let modelID: UUID
}

struct ToolCallRequest: Sendable {
    let id: String?
    let name: String
    let arguments: JSON
}

enum ToolDispatchOutcome: Sendable {
    case completed(Message)
    case pendingHandle(Message)
    case denied(Message)
    case approvalRequired(toolName: String, toolCallID: String?)
}

typealias ModelStreamEvent = StreamResult<LLMResponse, LLMResponse>

struct AgentLoopPorts: Sendable {
    let model: any RuntimeModelPort
    let context: any RuntimeContextPort
    let tools: any RuntimeToolPort
    let conversation: any RuntimeConversationPort
    let memory: (any RuntimeMemoryPort)?
    let agentHarness: AgentHarnessConfiguration
    let contextCompaction: ContextCompactionConfiguration
    let modeRegistry: any ModeRegistryAccessing
    let logger: Logger?
    /// Optional reconnect hook (tests). Production falls back to `orchestrator.mcpManager.reconnectClient(named:)`.
    let reconnectMCPClient: (@Sendable (_ serverName: String) async -> Bool)?
    /// What the budget gate settled for the last completion on this conversation. `nil` in tests and
    /// in hosts that never wired it; the loop then falls back to the conversation model's rates.
    let settlementSink: ModelCompletionSettlementSink?

    init(
        model: any RuntimeModelPort,
        context: any RuntimeContextPort,
        tools: any RuntimeToolPort,
        conversation: any RuntimeConversationPort,
        memory: (any RuntimeMemoryPort)?,
        agentHarness: AgentHarnessConfiguration,
        contextCompaction: ContextCompactionConfiguration,
        modeRegistry: any ModeRegistryAccessing,
        logger: Logger?,
        reconnectMCPClient: (@Sendable (_ serverName: String) async -> Bool)? = nil,
        settlementSink: ModelCompletionSettlementSink? = nil
    ) {
        self.model = model
        self.context = context
        self.tools = tools
        self.conversation = conversation
        self.memory = memory
        self.agentHarness = agentHarness
        self.contextCompaction = contextCompaction
        self.modeRegistry = modeRegistry
        self.logger = logger
        self.reconnectMCPClient = reconnectMCPClient
        self.settlementSink = settlementSink
    }
}

protocol RuntimeModelPort: Sendable {
    func resolve(for conversation: ModelConversation, orchestrator: SwiftAgentKitOrchestrator) async throws -> ResolvedModelHandle
    func stream(
        _ messages: [Message],
        orchestrator: SwiftAgentKitOrchestrator,
        handle: ResolvedModelHandle,
        tools: [ToolDefinition],
        toolParameterSchemasByName: [String: JSON],
        toolSchemaStrictByName: [String: Bool],
        toolChoice: RuntimeToolChoicePosture,
        temperatureOverride: Double?
    ) async -> AsyncThrowingStream<ModelStreamEvent, Error>
}

protocol RuntimeContextPort: Sendable {
    func bootstrap(conversationID: UUID, runID: UUID?) async
    func assembleForIteration(
        conversationID: UUID,
        runID: UUID?,
        phase: ContextTransformInvocationPhase,
        ephemeralTail: [Message],
        compaction: CompactionHint,
        configuration: AgentRuntimeTurnConfiguration
    ) async throws -> [Message]
    func projectedMemorySelectionKeys(conversationID: UUID) async -> Set<String>
    func afterTurn(conversationID: UUID, runID: UUID?, terminal: ConversationRunTerminalReason?) async
}

protocol RuntimeToolPort: Sendable {
    func consumeApprovalTimeouts(
        conversationID: UUID,
        runID: UUID?,
        iteration: Int,
        modelID: UUID,
        lifecycleEmitter: AgentRuntimeLifecycleEmitter
    ) async
    func effectiveTools(
        conversationID: UUID,
        runID: UUID?,
        configuration: AgentRuntimeTurnConfiguration,
        orchestrator: SwiftAgentKitOrchestrator
    ) async -> RuntimeToolTurnPolicySnapshot
    func dispatch(
        _ call: ToolCallRequest,
        conversationID: UUID,
        runID: UUID?,
        orchestrator: SwiftAgentKitOrchestrator,
        snapshot: RuntimeToolTurnPolicySnapshot,
        configuration: AgentRuntimeTurnConfiguration,
        iteration: Int,
        modelID: UUID,
        runtimePolicy: ModeProfileRuntimeSlice,
        lifecycleEmitter: AgentRuntimeLifecycleEmitter
    ) async -> ToolDispatchOutcome
    /// Dispatches an ordered batch via Kit `invokeTools` when eligible; otherwise falls back to per-call `dispatch`.
    func dispatchBatch(
        _ calls: [ToolCallRequest],
        conversationID: UUID,
        runID: UUID?,
        orchestrator: SwiftAgentKitOrchestrator,
        snapshot: RuntimeToolTurnPolicySnapshot,
        configuration: AgentRuntimeTurnConfiguration,
        iteration: Int,
        modelID: UUID,
        runtimePolicy: ModeProfileRuntimeSlice,
        lifecycleEmitter: AgentRuntimeLifecycleEmitter
    ) async -> [ToolDispatchOutcome]
    func handleDispatchApprovalRequired(
        call: ToolCallRequest,
        snapshot: RuntimeToolTurnPolicySnapshot,
        conversationID: UUID,
        runID: UUID?,
        iteration: Int,
        modelID: UUID,
        lifecycleEmitter: AgentRuntimeLifecycleEmitter
    ) async
    func isHaltSignal(_ toolName: String, in snapshot: RuntimeToolTurnPolicySnapshot) -> Bool
}

protocol RuntimeConversationPort: Sendable {
    func conversation(id: UUID) async -> ModelConversation?
    func append(_ message: Message, conversationID: UUID, runID: UUID?) async throws
    func appendRunCancelledMarker(conversationID: UUID, runID: UUID?, iteration: Int) async
    func rollbackAssistantTurn(messageID: UUID, conversationID: UUID) async
    func stampAssistantFinishReason(messageID: UUID, conversationID: UUID, finishReason: String) async
    func stopRequested(conversationID: UUID) async -> Bool
}

protocol RuntimeMemoryPort: Sendable {
    func blockingRecallSummary(
        conversationID: UUID,
        messages: [Message],
        anchorUserMessageID: UUID?,
        sessionEnabled: Bool,
        excludedSelectionKeys: Set<String>
    ) async -> ActiveMemoryRecallOutcome
    func prefetchRecall(
        conversationID: UUID,
        messages: [Message],
        anchorUserMessageID: UUID?,
        sessionEnabled: Bool
    ) async
}
