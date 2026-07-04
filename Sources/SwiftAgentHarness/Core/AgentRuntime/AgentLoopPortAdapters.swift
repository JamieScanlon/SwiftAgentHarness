import EasyJSON
import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator

struct SessionRuntimeModelPort: RuntimeModelPort {
    let ensureBoundFn: @Sendable (ModelConversation, SwiftAgentKitOrchestrator) async -> UUID
    let streamLLM: @Sendable (
        [Message],
        SwiftAgentKitOrchestrator,
        [ToolDefinition],
        RuntimeToolChoicePosture,
        Double?
    ) async -> AsyncThrowingStream<ModelStreamEvent, Error>

    func resolve(for conversation: ModelConversation, orchestrator: SwiftAgentKitOrchestrator) async throws -> ResolvedModelHandle {
        let modelID = await ensureBoundFn(conversation, orchestrator)
        return ResolvedModelHandle(modelID: modelID)
    }

    func stream(
        _ messages: [Message],
        orchestrator: SwiftAgentKitOrchestrator,
        handle: ResolvedModelHandle,
        tools: [ToolDefinition],
        toolChoice: RuntimeToolChoicePosture,
        temperatureOverride: Double?
    ) async -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let _ = handle
        return await streamLLM(messages, orchestrator, tools, toolChoice, temperatureOverride)
    }
}

struct SessionRuntimeContextPort: RuntimeContextPort {
    let bootstrapFn: @Sendable (UUID, UUID?) async -> Void
    let assembleFn: @Sendable (
        UUID,
        ContextTransformInvocationPhase,
        [Message],
        CompactionHint,
        AgentRuntimeTurnConfiguration
    ) async throws -> [Message]
    let afterTurnFn: @Sendable (UUID, UUID?, ConversationRunTerminalReason?) async -> Void

    func bootstrap(conversationID: UUID, runID: UUID?) async {
        await bootstrapFn(conversationID, runID)
    }

    func assembleForIteration(
        conversationID: UUID,
        runID: UUID?,
        phase: ContextTransformInvocationPhase,
        ephemeralTail: [Message],
        compaction: CompactionHint,
        configuration: AgentRuntimeTurnConfiguration
    ) async throws -> [Message] {
        let _ = runID
        return try await assembleFn(conversationID, phase, ephemeralTail, compaction, configuration)
    }

    func afterTurn(conversationID: UUID, runID: UUID?, terminal: ConversationRunTerminalReason?) async {
        await afterTurnFn(conversationID, runID, terminal)
    }
}

struct SessionRuntimeToolPort: RuntimeToolPort {
    let consumeApprovalTimeoutsFn: @Sendable (
        UUID,
        UUID?,
        Int,
        UUID,
        AgentRuntimeLifecycleEmitter
    ) async -> Void
    let effectiveToolsFn: @Sendable (UUID, UUID?, AgentRuntimeTurnConfiguration, SwiftAgentKitOrchestrator) async -> RuntimeToolTurnPolicySnapshot
    let dispatchFn: @Sendable (
        ToolCallRequest,
        UUID,
        UUID?,
        SwiftAgentKitOrchestrator,
        RuntimeToolTurnPolicySnapshot,
        AgentRuntimeTurnConfiguration,
        Int,
        UUID,
        ModeProfileRuntimeSlice,
        AgentRuntimeLifecycleEmitter
    ) async -> ToolDispatchOutcome
    let dispatchApprovalFn: @Sendable (
        String,
        String?,
        RuntimeToolTurnPolicySnapshot,
        UUID,
        UUID?,
        Int,
        UUID,
        AgentRuntimeLifecycleEmitter
    ) async -> Void
    let isHaltingFn: @Sendable (String, [ToolRegistryEntry]) async -> Bool

    func consumeApprovalTimeouts(
        conversationID: UUID,
        runID: UUID?,
        iteration: Int,
        modelID: UUID,
        lifecycleEmitter: AgentRuntimeLifecycleEmitter
    ) async {
        await consumeApprovalTimeoutsFn(conversationID, runID, iteration, modelID, lifecycleEmitter)
    }

    func effectiveTools(
        conversationID: UUID,
        runID: UUID?,
        configuration: AgentRuntimeTurnConfiguration,
        orchestrator: SwiftAgentKitOrchestrator
    ) async -> RuntimeToolTurnPolicySnapshot {
        await effectiveToolsFn(conversationID, runID, configuration, orchestrator)
    }

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
    ) async -> ToolDispatchOutcome {
        await dispatchFn(
            call,
            conversationID,
            runID,
            orchestrator,
            snapshot,
            configuration,
            iteration,
            modelID,
            runtimePolicy,
            lifecycleEmitter
        )
    }

    func handleDispatchApprovalRequired(
        toolName: String,
        toolCallID: String?,
        snapshot: RuntimeToolTurnPolicySnapshot,
        conversationID: UUID,
        runID: UUID?,
        iteration: Int,
        modelID: UUID,
        lifecycleEmitter: AgentRuntimeLifecycleEmitter
    ) async {
        await dispatchApprovalFn(
            toolName,
            toolCallID,
            snapshot,
            conversationID,
            runID,
            iteration,
            modelID,
            lifecycleEmitter
        )
    }

    func isHaltSignal(_ toolName: String, in snapshot: RuntimeToolTurnPolicySnapshot) -> Bool {
        snapshot.effectiveEntries.first(where: { $0.name == toolName })?.haltsLoop == true
    }
}

struct SessionRuntimeConversationPort: RuntimeConversationPort {
    let conversationFn: @Sendable (UUID) async -> ModelConversation?
    let appendFn: @Sendable (Message, UUID, UUID?) async throws -> Void
    let markerFn: @Sendable (UUID, UUID?, Int) async -> Void
    let rollbackFn: @Sendable (UUID, UUID) async -> Void
    let stampFinishReasonFn: @Sendable (UUID, UUID, String) async -> Void
    let stopRequestedFn: @Sendable (UUID) async -> Bool

    func conversation(id: UUID) async -> ModelConversation? {
        await conversationFn(id)
    }

    func append(_ message: Message, conversationID: UUID, runID: UUID?) async throws {
        try await appendFn(message, conversationID, runID)
    }

    func appendRunCancelledMarker(conversationID: UUID, runID: UUID?, iteration: Int) async {
        await markerFn(conversationID, runID, iteration)
    }

    func rollbackAssistantTurn(messageID: UUID, conversationID: UUID) async {
        await rollbackFn(messageID, conversationID)
    }

    func stampAssistantFinishReason(messageID: UUID, conversationID: UUID, finishReason: String) async {
        await stampFinishReasonFn(messageID, conversationID, finishReason)
    }

    func stopRequested(conversationID: UUID) async -> Bool {
        await stopRequestedFn(conversationID)
    }
}

struct SessionRuntimeMemoryPort: RuntimeMemoryPort {
    let recallFn: @Sendable (UUID, String) async -> String?
    let prefetchFn: @Sendable (UUID, String) async -> Void

    func blockingRecallSummary(conversationID: UUID, userQuery: String) async -> String? {
        await recallFn(conversationID, userQuery)
    }

    func prefetchRecall(conversationID: UUID, userQuery: String) async {
        await prefetchFn(conversationID, userQuery)
    }
}

enum AgentLoopLLMStreaming {
    static func toolInvocationPolicy(for toolChoice: RuntimeToolChoicePosture) -> ToolInvocationPolicy {
        toolChoice == .required ? .required : .automatic
    }

    static func stream(
        messages: [Message],
        orchestrator: SwiftAgentKitOrchestrator,
        tools: [ToolDefinition],
        toolChoice: RuntimeToolChoicePosture,
        temperatureOverride: Double?
    ) async -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let orchestratorConfig = await orchestrator.config
        let llm = await orchestrator.llm
        let config = LLMRequestConfig(
            maxTokens: orchestratorConfig.maxTokens,
            temperature: temperatureOverride ?? orchestratorConfig.temperature,
            topP: orchestratorConfig.topP,
            availableTools: tools,
            additionalParameters: orchestratorConfig.additionalParameters,
            toolInvocationPolicy: toolInvocationPolicy(for: toolChoice)
        )
        return llm.stream(messages, config: config)
    }
}

enum AgentLoopToolDispatch {
    static let approvalPendingToolResultContent = "Tool execution pending user approval."

    static func toolResultMessage(toolCallId: String?, content: String) -> Message {
        Message(
            id: UUID(),
            role: .tool,
            content: content,
            timestamp: Date(),
            toolCalls: [],
            toolCallId: toolCallId
        )
    }

    static func approvalPendingToolResultMessage(toolCallId: String?) -> Message {
        toolResultMessage(toolCallId: toolCallId, content: approvalPendingToolResultContent)
    }

    static func dispatch(
        call: ToolCallRequest,
        conversationID: UUID,
        runID: UUID?,
        orchestrator: SwiftAgentKitOrchestrator,
        snapshot: RuntimeToolTurnPolicySnapshot,
        configuration: AgentRuntimeTurnConfiguration = AgentRuntimeTurnConfiguration(enableTools: true, enableAgents: true),
        conversation: ModelConversation? = nil,
        gateway: (any ToolSystemGatewaying)? = nil,
        parentLookup: (@Sendable (UUID) async -> ModelConversation?)? = nil,
        tenancyPolicy: TenancyPolicySettings = .disabled,
        spawnService: SubAgentSpawnService? = nil
    ) async -> ToolDispatchOutcome {
        if let spawnService,
           let delegateOutcome = await SubAgentDelegateInvocationService.dispatchModelTurnIfDelegate(
            call: call,
            conversationID: conversationID,
            runID: runID,
            orchestrator: orchestrator,
            snapshot: snapshot,
            spawnService: spawnService
           ) {
            return delegateOutcome
        }
        return await dispatchViaOrchestrator(
            call: call,
            conversationID: conversationID,
            runID: runID,
            orchestrator: orchestrator,
            snapshot: snapshot,
            configuration: configuration,
            conversation: conversation,
            gateway: gateway,
            parentLookup: parentLookup,
            tenancyPolicy: tenancyPolicy
        )
    }

    private static func dispatchViaOrchestrator(
        call: ToolCallRequest,
        conversationID: UUID,
        runID: UUID?,
        orchestrator: SwiftAgentKitOrchestrator,
        snapshot: RuntimeToolTurnPolicySnapshot,
        configuration: AgentRuntimeTurnConfiguration = AgentRuntimeTurnConfiguration(enableTools: true, enableAgents: true),
        conversation: ModelConversation? = nil,
        gateway: (any ToolSystemGatewaying)? = nil,
        parentLookup: (@Sendable (UUID) async -> ModelConversation?)? = nil,
        tenancyPolicy: TenancyPolicySettings = .disabled
    ) async -> ToolDispatchOutcome {
        guard snapshot.effectiveEntries.contains(where: { $0.name == call.name }) else {
            return .denied(
                toolResultMessage(
                    toolCallId: call.id,
                    content: "Tool dispatch denied: tool not in effective allow-list."
                )
            )
        }
        if let availability = snapshot.availabilitySnapshots.first(where: { $0.entry.name == call.name }) {
            if availability.decision.blockReason == .approvalRequired {
                return .approvalRequired(toolName: call.name, toolCallID: call.id)
            }
            if !availability.decision.allowed {
                let reason = availability.decision.blockReason.map { String(describing: $0) } ?? "blocked"
                return .denied(
                    toolResultMessage(
                        toolCallId: call.id,
                        content: "Tool dispatch denied: \(reason)."
                    )
                )
            }
        }
        if !configuration.preApprovedToolNames.contains(call.name),
           let gateway,
           let conversation,
           let parentLookup,
           let entry = snapshot.effectiveEntries.first(where: { $0.name == call.name }),
           await gateway.evaluateCallApproval(
               entry: entry,
               call: call,
               conversation: conversation,
               configuration: configuration,
               parentLookup: parentLookup,
               tenancyPolicy: tenancyPolicy
           ) {
            return .approvalRequired(toolName: call.name, toolCallID: call.id)
        }
        let request = ToolInvocationRequest(
            toolName: call.name,
            argumentsPayload: call.arguments,
            toolCallID: call.id,
            conversationID: conversationID.uuidString,
            runID: runID?.uuidString,
            source: .model
        )
        let outcome = await orchestrator.invokeTool(request)
        switch outcome {
        case .completed(let result, _):
            let content = result.success ? result.content : (result.error ?? "Tool execution failed.")
            return .completed(toolResultMessage(toolCallId: result.toolCallId ?? call.id, content: content))
        case .pending(let handle, _):
            return .pendingHandle(
                toolResultMessage(toolCallId: call.id, content: "Pending tool handle: \(handle.handleID)")
            )
        case .denied:
            return .denied(toolResultMessage(toolCallId: call.id, content: "Tool dispatch denied."))
        case .approvalRequired:
            return .approvalRequired(toolName: call.name, toolCallID: call.id)
        }
    }
}
