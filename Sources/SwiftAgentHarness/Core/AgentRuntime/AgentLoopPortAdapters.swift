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
        [String: JSON],
        [String: Bool],
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
        toolParameterSchemasByName: [String: JSON],
        toolSchemaStrictByName: [String: Bool],
        toolChoice: RuntimeToolChoicePosture,
        temperatureOverride: Double?
    ) async -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let _ = handle
        return await streamLLM(
            messages,
            orchestrator,
            tools,
            toolParameterSchemasByName,
            toolSchemaStrictByName,
            toolChoice,
            temperatureOverride
        )
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
    let projectedMemorySelectionKeysFn: @Sendable (UUID) async -> Set<String>
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

    func projectedMemorySelectionKeys(conversationID: UUID) async -> Set<String> {
        await projectedMemorySelectionKeysFn(conversationID)
    }

    func afterTurn(conversationID: UUID, runID: UUID?, terminal: ConversationRunTerminalReason?) async {
        await afterTurnFn(conversationID, runID, terminal)
    }
}

extension SessionRuntimeContextPort {
    init(
        bootstrapFn: @escaping @Sendable (UUID, UUID?) async -> Void,
        assembleFn: @escaping @Sendable (
            UUID,
            ContextTransformInvocationPhase,
            [Message],
            CompactionHint,
            AgentRuntimeTurnConfiguration
        ) async throws -> [Message],
        afterTurnFn: @escaping @Sendable (UUID, UUID?, ConversationRunTerminalReason?) async -> Void
    ) {
        self.init(
            bootstrapFn: bootstrapFn,
            assembleFn: assembleFn,
            projectedMemorySelectionKeysFn: { _ in [] },
            afterTurnFn: afterTurnFn
        )
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
    let dispatchBatchFn: (@Sendable (
        [ToolCallRequest],
        UUID,
        UUID?,
        SwiftAgentKitOrchestrator,
        RuntimeToolTurnPolicySnapshot,
        AgentRuntimeTurnConfiguration,
        Int,
        UUID,
        ModeProfileRuntimeSlice,
        AgentRuntimeLifecycleEmitter
    ) async -> [ToolDispatchOutcome])?
    let dispatchApprovalFn: @Sendable (
        ToolCallRequest,
        RuntimeToolTurnPolicySnapshot,
        UUID,
        UUID?,
        Int,
        UUID,
        AgentRuntimeLifecycleEmitter
    ) async -> Void
    let isHaltingFn: @Sendable (String, [ToolRegistryEntry]) async -> Bool

    init(
        consumeApprovalTimeoutsFn: @escaping @Sendable (
            UUID,
            UUID?,
            Int,
            UUID,
            AgentRuntimeLifecycleEmitter
        ) async -> Void,
        effectiveToolsFn: @escaping @Sendable (UUID, UUID?, AgentRuntimeTurnConfiguration, SwiftAgentKitOrchestrator) async -> RuntimeToolTurnPolicySnapshot,
        dispatchFn: @escaping @Sendable (
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
        ) async -> ToolDispatchOutcome,
        dispatchBatchFn: (@Sendable (
            [ToolCallRequest],
            UUID,
            UUID?,
            SwiftAgentKitOrchestrator,
            RuntimeToolTurnPolicySnapshot,
            AgentRuntimeTurnConfiguration,
            Int,
            UUID,
            ModeProfileRuntimeSlice,
            AgentRuntimeLifecycleEmitter
        ) async -> [ToolDispatchOutcome])? = nil,
        dispatchApprovalFn: @escaping @Sendable (
            ToolCallRequest,
            RuntimeToolTurnPolicySnapshot,
            UUID,
            UUID?,
            Int,
            UUID,
            AgentRuntimeLifecycleEmitter
        ) async -> Void,
        isHaltingFn: @escaping @Sendable (String, [ToolRegistryEntry]) async -> Bool
    ) {
        self.consumeApprovalTimeoutsFn = consumeApprovalTimeoutsFn
        self.effectiveToolsFn = effectiveToolsFn
        self.dispatchFn = dispatchFn
        self.dispatchBatchFn = dispatchBatchFn
        self.dispatchApprovalFn = dispatchApprovalFn
        self.isHaltingFn = isHaltingFn
    }

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
    ) async -> [ToolDispatchOutcome] {
        if let dispatchBatchFn {
            return await dispatchBatchFn(
                calls,
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
        var outcomes: [ToolDispatchOutcome] = []
        outcomes.reserveCapacity(calls.count)
        for call in calls {
            outcomes.append(
                await dispatch(
                    call,
                    conversationID: conversationID,
                    runID: runID,
                    orchestrator: orchestrator,
                    snapshot: snapshot,
                    configuration: configuration,
                    iteration: iteration,
                    modelID: modelID,
                    runtimePolicy: runtimePolicy,
                    lifecycleEmitter: lifecycleEmitter
                )
            )
        }
        return outcomes
    }

    func handleDispatchApprovalRequired(
        call: ToolCallRequest,
        snapshot: RuntimeToolTurnPolicySnapshot,
        conversationID: UUID,
        runID: UUID?,
        iteration: Int,
        modelID: UUID,
        lifecycleEmitter: AgentRuntimeLifecycleEmitter
    ) async {
        await dispatchApprovalFn(
            call,
            snapshot,
            conversationID,
            runID,
            iteration,
            modelID,
            lifecycleEmitter
        )
    }

    func isHaltSignal(_ toolName: String, in snapshot: RuntimeToolTurnPolicySnapshot) -> Bool {
        snapshot.effectiveEntries.first { entry in
            snapshot.nameIndex.matchesRegistryName(callName: toolName, entryName: entry.name)
        }?.haltsLoop == true
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
    let recallFn: @Sendable (UUID, [Message], UUID?, Bool, Set<String>) async -> ActiveMemoryRecallOutcome
    let prefetchFn: @Sendable (UUID, [Message], UUID?, Bool) async -> Void

    func blockingRecallSummary(
        conversationID: UUID,
        messages: [Message],
        anchorUserMessageID: UUID?,
        sessionEnabled: Bool,
        excludedSelectionKeys: Set<String>
    ) async -> ActiveMemoryRecallOutcome {
        await recallFn(conversationID, messages, anchorUserMessageID, sessionEnabled, excludedSelectionKeys)
    }

    func prefetchRecall(
        conversationID: UUID,
        messages: [Message],
        anchorUserMessageID: UUID?,
        sessionEnabled: Bool
    ) async {
        await prefetchFn(conversationID, messages, anchorUserMessageID, sessionEnabled)
    }
}

extension SessionRuntimeMemoryPort {
    init(
        recallFn: @escaping @Sendable (UUID, [Message], UUID?, Bool) async -> ActiveMemoryRecallOutcome,
        prefetchFn: @escaping @Sendable (UUID, [Message], UUID?, Bool) async -> Void
    ) {
        self.init(
            recallFn: { conversationID, messages, anchorUserMessageID, sessionEnabled, _ in
                await recallFn(conversationID, messages, anchorUserMessageID, sessionEnabled)
            },
            prefetchFn: prefetchFn
        )
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
        toolParameterSchemasByName: [String: JSON],
        toolSchemaStrictByName: [String: Bool],
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
            toolParameterSchemasByName: toolParameterSchemasByName,
            toolSchemaStrictByName: toolSchemaStrictByName,
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
        guard snapshot.nameIndex.resolveEntry(named: call.name, in: snapshot.effectiveEntries) != nil else {
            return .denied(
                toolResultMessage(
                    toolCallId: call.id,
                    content: "Tool dispatch denied: tool not in effective allow-list."
                )
            )
        }
        let bindingPreApproved = ToolCallApprovalPolicy.isBindingPreApproved(
            call: call,
            configuration: configuration
        )
        let durableNamePreApproved = ToolCallApprovalPolicy.isDurableNamePreApproved(
            call: call,
            configuration: configuration
        )
        let durableRulePreApproved = ToolCallApprovalPolicy.isDurableRulePreApproved(
            call: call,
            entry: snapshot.nameIndex.resolveEntry(named: call.name, in: snapshot.effectiveEntries),
            configuration: configuration,
            groupIndex: snapshot.groupIndex,
            nameIndex: snapshot.nameIndex
        )
        if !bindingPreApproved && !durableNamePreApproved && !durableRulePreApproved,
           let availability = snapshot.availabilitySnapshots.first(where: {
               snapshot.nameIndex.matchesRegistryName(callName: call.name, entryName: $0.entry.name)
           }) {
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
        let resolvedEntry = snapshot.nameIndex.resolveEntry(named: call.name, in: snapshot.effectiveEntries)
        if !bindingPreApproved && !durableNamePreApproved && !durableRulePreApproved,
           let gateway,
           let conversation,
           let entry = resolvedEntry {
            let gatingDecision = gateway.evaluateCallGating(
                entry: entry,
                call: call,
                conversation: conversation,
                configuration: configuration,
                toolPolicy: .unrestricted,
                modePolicyContext: snapshot.modePolicyContext,
                groupIndex: snapshot.groupIndex,
                durableRules: configuration.preApprovedToolRules
            )
            switch gatingDecision.behavior {
            case .deny:
                return .denied(
                    toolResultMessage(
                        toolCallId: call.id,
                        content: "Tool dispatch denied: call-level policy."
                    )
                )
            case .ask, .allow:
                break
            }
        }
        if !bindingPreApproved && !durableRulePreApproved,
           let gateway,
           let conversation,
           let parentLookup,
           let entry = resolvedEntry,
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

    /// Returns true when any call in the batch should force serial per-call dispatch
    /// (approval-gated, deny-gated, or sub-agent delegate).
    static func batchRequiresSerialFallback(
        calls: [ToolCallRequest],
        snapshot: RuntimeToolTurnPolicySnapshot,
        configuration: AgentRuntimeTurnConfiguration,
        conversation: ModelConversation? = nil,
        gateway: (any ToolSystemGatewaying)? = nil,
        parentLookup: (@Sendable (UUID) async -> ModelConversation?)? = nil,
        tenancyPolicy: TenancyPolicySettings = .disabled,
        spawnService: SubAgentSpawnService? = nil
    ) async -> Bool {
        for call in calls {
            if let spawnService,
               let entry = snapshot.nameIndex.resolveEntry(named: call.name, in: snapshot.effectiveEntries),
               spawnService.subAgentPool.isDelegateTool(entry: entry) {
                return true
            }
            let preflight = await preflightOutcome(
                call: call,
                snapshot: snapshot,
                configuration: configuration,
                conversation: conversation,
                gateway: gateway,
                parentLookup: parentLookup,
                tenancyPolicy: tenancyPolicy
            )
            switch preflight {
            case .approvalRequired, .denied:
                return true
            case .ready:
                continue
            }
        }
        return false
    }

    static func dispatchBatch(
        calls: [ToolCallRequest],
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
    ) async -> [ToolDispatchOutcome] {
        guard !calls.isEmpty else { return [] }
        if calls.count == 1 {
            return [
                await dispatch(
                    call: calls[0],
                    conversationID: conversationID,
                    runID: runID,
                    orchestrator: orchestrator,
                    snapshot: snapshot,
                    configuration: configuration,
                    conversation: conversation,
                    gateway: gateway,
                    parentLookup: parentLookup,
                    tenancyPolicy: tenancyPolicy,
                    spawnService: spawnService
                )
            ]
        }
        if await batchRequiresSerialFallback(
            calls: calls,
            snapshot: snapshot,
            configuration: configuration,
            conversation: conversation,
            gateway: gateway,
            parentLookup: parentLookup,
            tenancyPolicy: tenancyPolicy,
            spawnService: spawnService
        ) {
            var serialOutcomes: [ToolDispatchOutcome] = []
            serialOutcomes.reserveCapacity(calls.count)
            for call in calls {
                let outcome = await dispatch(
                    call: call,
                    conversationID: conversationID,
                    runID: runID,
                    orchestrator: orchestrator,
                    snapshot: snapshot,
                    configuration: configuration,
                    conversation: conversation,
                    gateway: gateway,
                    parentLookup: parentLookup,
                    tenancyPolicy: tenancyPolicy,
                    spawnService: spawnService
                )
                serialOutcomes.append(outcome)
                if case .approvalRequired = outcome {
                    break
                }
            }
            return serialOutcomes
        }

        let contract = snapshot.dispatchContract
        let plannerMode = kitDispatchPlannerMode(contract.dispatchPlannerMode)
        let requests: [ToolInvocationRequest] = calls.map { call in
            ToolInvocationRequest(
                toolName: call.name,
                argumentsPayload: call.arguments,
                toolCallID: call.id,
                conversationID: conversationID.uuidString,
                runID: runID?.uuidString,
                source: .model
            )
        }
        let batchRequest = ToolBatchInvocationRequest(
            requests: requests,
            plannerMode: plannerMode,
            defaultTimeoutSeconds: contract.pendingToolTimeoutSeconds,
            conversationID: conversationID.uuidString,
            runID: runID?.uuidString,
            source: .model,
            parallelToolDispatchEnabled: contract.parallelDispatchEnabled
        )
        let batchOutcome = await orchestrator.invokeTools(batchRequest)
        return zip(calls, batchOutcome.outcomes).map { call, outcome in
            mapInvocationOutcome(outcome, fallbackCall: call)
        }
    }

    static func kitDispatchPlannerMode(
        _ mode: ToolPolicyConfiguration.DispatchPlannerMode?
    ) -> ToolDispatchPlannerMode? {
        guard let mode else { return nil }
        switch mode {
        case .serial:
            return .serial
        case .allParallel:
            return .allParallel
        case .mixedDeterministic:
            return .mixedDeterministic
        }
    }

    private enum PreflightResult: Sendable {
        case ready
        case denied(ToolDispatchOutcome)
        case approvalRequired(ToolDispatchOutcome)
    }

    private static func preflightOutcome(
        call: ToolCallRequest,
        snapshot: RuntimeToolTurnPolicySnapshot,
        configuration: AgentRuntimeTurnConfiguration,
        conversation: ModelConversation?,
        gateway: (any ToolSystemGatewaying)?,
        parentLookup: (@Sendable (UUID) async -> ModelConversation?)?,
        tenancyPolicy: TenancyPolicySettings
    ) async -> PreflightResult {
        guard snapshot.nameIndex.resolveEntry(named: call.name, in: snapshot.effectiveEntries) != nil else {
            return .denied(
                .denied(
                    toolResultMessage(
                        toolCallId: call.id,
                        content: "Tool dispatch denied: tool not in effective allow-list."
                    )
                )
            )
        }
        let bindingPreApproved = ToolCallApprovalPolicy.isBindingPreApproved(
            call: call,
            configuration: configuration
        )
        let durableNamePreApproved = ToolCallApprovalPolicy.isDurableNamePreApproved(
            call: call,
            configuration: configuration
        )
        let durableRulePreApproved = ToolCallApprovalPolicy.isDurableRulePreApproved(
            call: call,
            entry: snapshot.nameIndex.resolveEntry(named: call.name, in: snapshot.effectiveEntries),
            configuration: configuration,
            groupIndex: snapshot.groupIndex,
            nameIndex: snapshot.nameIndex
        )
        if !bindingPreApproved && !durableNamePreApproved && !durableRulePreApproved,
           let availability = snapshot.availabilitySnapshots.first(where: {
               snapshot.nameIndex.matchesRegistryName(callName: call.name, entryName: $0.entry.name)
           }) {
            if availability.decision.blockReason == .approvalRequired {
                return .approvalRequired(.approvalRequired(toolName: call.name, toolCallID: call.id))
            }
            if !availability.decision.allowed {
                let reason = availability.decision.blockReason.map { String(describing: $0) } ?? "blocked"
                return .denied(
                    .denied(
                        toolResultMessage(
                            toolCallId: call.id,
                            content: "Tool dispatch denied: \(reason)."
                        )
                    )
                )
            }
        }
        let resolvedEntry = snapshot.nameIndex.resolveEntry(named: call.name, in: snapshot.effectiveEntries)
        if !bindingPreApproved && !durableNamePreApproved && !durableRulePreApproved,
           let gateway,
           let conversation,
           let entry = resolvedEntry {
            let gatingDecision = gateway.evaluateCallGating(
                entry: entry,
                call: call,
                conversation: conversation,
                configuration: configuration,
                toolPolicy: .unrestricted,
                modePolicyContext: snapshot.modePolicyContext,
                groupIndex: snapshot.groupIndex,
                durableRules: configuration.preApprovedToolRules
            )
            switch gatingDecision.behavior {
            case .deny:
                return .denied(
                    .denied(
                        toolResultMessage(
                            toolCallId: call.id,
                            content: "Tool dispatch denied: call-level policy."
                        )
                    )
                )
            case .ask, .allow:
                break
            }
        }
        if !bindingPreApproved && !durableRulePreApproved,
           let gateway,
           let conversation,
           let parentLookup,
           let entry = resolvedEntry,
           await gateway.evaluateCallApproval(
               entry: entry,
               call: call,
               conversation: conversation,
               configuration: configuration,
               parentLookup: parentLookup,
               tenancyPolicy: tenancyPolicy
           ) {
            return .approvalRequired(.approvalRequired(toolName: call.name, toolCallID: call.id))
        }
        return .ready
    }

    private static func mapInvocationOutcome(
        _ outcome: ToolInvocationOutcome,
        fallbackCall: ToolCallRequest
    ) -> ToolDispatchOutcome {
        switch outcome {
        case .completed(let result, _):
            let content = result.success ? result.content : (result.error ?? "Tool execution failed.")
            return .completed(toolResultMessage(toolCallId: result.toolCallId ?? fallbackCall.id, content: content))
        case .pending(let handle, _):
            return .pendingHandle(
                toolResultMessage(toolCallId: fallbackCall.id, content: "Pending tool handle: \(handle.handleID)")
            )
        case .denied:
            return .denied(toolResultMessage(toolCallId: fallbackCall.id, content: "Tool dispatch denied."))
        case .approvalRequired:
            return .approvalRequired(toolName: fallbackCall.name, toolCallID: fallbackCall.id)
        }
    }
}
