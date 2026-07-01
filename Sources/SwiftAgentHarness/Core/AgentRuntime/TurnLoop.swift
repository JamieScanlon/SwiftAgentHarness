import EasyJSON
import Foundation
import Logging
import SwiftAgentKit
import SwiftAgentKitOrchestrator

struct TurnLoop {
    let ports: AgentLoopPorts
    let publishDelta: @Sendable (ChatStreamingPartial, UUID, UUID?) async -> Void

    init(
        ports: AgentLoopPorts,
        publishDelta: @escaping @Sendable (ChatStreamingPartial, UUID, UUID?) async -> Void = { _, _, _ in }
    ) {
        self.ports = ports
        self.publishDelta = publishDelta
    }

    func run(
        conversationID: UUID,
        runID: UUID?,
        anchorUserMessageID: UUID?,
        configuration: AgentRuntimeTurnConfiguration,
        orchestrator: SwiftAgentKitOrchestrator,
        lifecycleEmitter: AgentRuntimeLifecycleEmitter
    ) async throws -> ConversationRunTerminalReason {
        await ports.context.bootstrap(conversationID: conversationID, runID: runID)

        let agentHarness = await resolveHarness()
        let maxIterations = await resolveMaxIterations(conversationID: conversationID)
        var iterState = RuntimeTerminationIterationState.neutral
        var toolChoice = RuntimeToolChoicePosture.auto
        var temperatureOverride: Double? = nil
        var ephemeralTail: [Message] = []
        var retriedCompactionThisIteration = false
        var continuationsUsed = 0
        var hasTranscriptDeltaAcrossRun = false
        let messageOutputPolicy = MessageOutputPolicyResolver.policy(
            originSurface: configuration.originSurface,
            legacyStreamedTextSurfaces: agentHarness.legacyStreamedTextSurfaces
        )
        for iteration in 1...maxIterations {
            try Task.checkCancellation()
            guard let conv = await ports.conversation.conversation(id: conversationID) else {
                return ConversationRunTerminalReason(category: .naturalStop, detail: "conversation_not_found")
            }
            await ports.tools.consumeApprovalTimeouts(
                conversationID: conversationID,
                runID: runID,
                iteration: iteration,
                modelID: conv.model.id,
                lifecycleEmitter: lifecycleEmitter
            )
            await lifecycleEmitter.emit(
                .loopIterationStarted(iteration: iteration, modelID: conv.model.id),
                conversationID: conversationID,
                runID: runID
            )

            let snapshot = await ports.tools.effectiveTools(
                conversationID: conversationID,
                runID: runID,
                configuration: configuration,
                orchestrator: orchestrator
            )
            let runtimePolicy = await resolveRuntimePolicy(for: conv)
            if toolChoice == .required, runtimePolicy.termination?.policy != .terminalTool {
                toolChoice = .auto
            }
            let phase: ContextTransformInvocationPhase = iteration == 1
                ? .initial
                : .continuation(round: continuationsUsed)
            let compaction: CompactionHint = retriedCompactionThisIteration ? .forceCompaction : .normal

            // Fire situational prefetch before assembly so recall overlaps context assembly.
            if iteration == 1, case .initial = phase, let memoryPort = ports.memory,
               ConversationActiveMemoryPolicy.shouldRunBlockingPreReplyRecall(for: conv) {
                if let query = resolveUserQuery(from: conv.messages, anchorUserMessageID: anchorUserMessageID) {
                    await memoryPort.prefetchRecall(conversationID: conversationID, userQuery: query)
                }
            }

            var messages: [Message]
            do {
                messages = try await ports.context.assembleForIteration(
                    conversationID: conversationID,
                    runID: runID,
                    phase: phase,
                    ephemeralTail: ephemeralTail,
                    compaction: compaction,
                    configuration: configuration
                )
            } catch {
                ports.logger?.error("[TurnLoop] context assembly failed: \(error)")
                throw error
            }
            if iteration == 1, case .initial = phase {
                if let reminder = configuration.ephemeralSystemReminder {
                    let reminderMessage = HarnessInjectedMessageMetadata.systemMessage(
                        id: UUID(),
                        content: """
\(HarnessInjectedMessagePrefixes.triggerProvenance)
\(reminder)
"""
                    )
                    messages = [reminderMessage] + messages
                }
            }
            if iteration == 1, case .initial = phase, let memoryPort = ports.memory,
               ConversationActiveMemoryPolicy.shouldRunBlockingPreReplyRecall(for: conv) {
                let userQuery = resolveUserQuery(from: messages, anchorUserMessageID: anchorUserMessageID)
                if let query = userQuery,
                   let recall = await memoryPort.blockingRecallSummary(conversationID: conversationID, userQuery: query) {
                    let recallMessage = HarnessInjectedMessageMetadata.systemMessage(
                        id: UUID(),
                        content: """
\(HarnessInjectedMessagePrefixes.activeMemoryRecall)
\(recall)
"""
                    )
                    messages = [recallMessage] + messages
                }
            }
            let handle = try await ports.model.resolve(for: conv, orchestrator: orchestrator)

            if toolChoice == .required {
                if let terminal = requiredToolChoiceTerminalIfUnsatisfiable(
                    snapshot: snapshot,
                    conversationID: conversationID,
                    runID: runID,
                    iteration: iteration
                ) {
                    return terminal
                }
            }

            var acc = AssistantMessageAccumulator()
            var publishedStreamDeltaThisAttempt = false
            var modelCallStartedEmitted = false
            var sawStreamComplete = false
            // Final provider-agnostic guard: never dispatch an unrenderable array (orphaned leading
            // tool result / missing system prompt) regardless of how `messages` was assembled.
            messages = RenderableMessageInvariant.sanitizeForDispatch(messages, logger: ports.logger)
            let providerBinding = ProviderBinding(
                providerId: conv.model.modelProtocol.rawValue,
                modelProtocol: conv.model.modelProtocol,
                endpointModelId: conv.model.modelName,
                serverURL: conv.model.serverURL
            )
            let compat = ProviderRuntimeHooks.compatForBinding(providerBinding)
            let targetCapabilities = Set(conv.model.capabilities)
            _ = ProviderRuntimeHooks.validateReplayTurns(
                messages,
                binding: providerBinding,
                compat: compat,
                targetCapabilities: targetCapabilities,
                logger: ports.logger
            )
            messages = ProviderRuntimeHooks.transformMessages(
                messages,
                binding: providerBinding,
                compat: compat,
                targetCapabilities: targetCapabilities
            )
            let normalizedTools = ProviderRuntimeHooks.normalizeTools(
                snapshot.effectiveTools,
                binding: providerBinding
            )
            do {
                let stream = await ports.model.stream(
                    messages,
                    orchestrator: orchestrator,
                    handle: handle,
                    tools: normalizedTools,
                    toolChoice: toolChoice,
                    temperatureOverride: temperatureOverride
                )
                for try await event in stream {
                    if !modelCallStartedEmitted {
                        modelCallStartedEmitted = true
                        await lifecycleEmitter.emit(
                            .modelCallStarted(iteration: iteration, modelID: handle.modelID),
                            conversationID: conversationID,
                            runID: runID
                        )
                    }
                    if await publishStreamDelta(
                        event,
                        conversationID: conversationID,
                        runID: runID
                    ) {
                        publishedStreamDeltaThisAttempt = true
                    }
                    if case .complete = event {
                        sawStreamComplete = true
                    }
                    acc.consume(event)
                }
                if !sawStreamComplete {
                    let userStopRequested = await ports.conversation.stopRequested(conversationID: conversationID)
                    if Task.isCancelled || userStopRequested {
                        await ports.conversation.appendRunCancelledMarker(
                            conversationID: conversationID,
                            runID: runID,
                            iteration: iteration
                        )
                        return ConversationRunTerminalReason(
                            category: .externalCancellation,
                            detail: Task.isCancelled ? "task_cancelled" : "user_stop_requested"
                        )
                    }
                    throw LLMError.timeout
                }
            } catch is CancellationError {
                await ports.conversation.appendRunCancelledMarker(
                    conversationID: conversationID,
                    runID: runID,
                    iteration: iteration
                )
                return ConversationRunTerminalReason(category: .externalCancellation, detail: "task_cancelled")
            } catch let err where shouldRetryCompaction(err)
                && !retriedCompactionThisIteration
                && !publishedStreamDeltaThisAttempt {
                retriedCompactionThisIteration = true
                continue
            }

            let assistantEnvelope = MessageOutputPostProcessor.apply(
                envelope: acc.finalize(),
                policy: messageOutputPolicy
            )
            HarnessMessageEnvelopeStore.store(assistantEnvelope)
            let assistant = assistantEnvelope.message
            let rejectedBareRequiredTurn = toolChoice == .required
                && runtimePolicy.termination?.policy == .terminalTool
                && !snapshot.effectiveTools.isEmpty
                && assistant.toolCalls.isEmpty
                && assistant.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && assistant.images.isEmpty

            if !rejectedBareRequiredTurn {
                try await ports.conversation.append(assistant, conversationID: conversationID, runID: runID)
                hasTranscriptDeltaAcrossRun = true
            }

            await lifecycleEmitter.emit(
                .modelCallCompleted(iteration: iteration, modelID: handle.modelID),
                conversationID: conversationID,
                runID: runID
            )

            var sawHaltSignal = false
            if rejectedBareRequiredTurn {
                // Bare required turn was not appended; pre-call `conv` matches post-call transcript state.
                let userStopRequested = await ports.conversation.stopRequested(conversationID: conversationID)
                let stopRequested = Task.isCancelled || userStopRequested
                let hasToolCallsInLatestAssistant = false
                let decision = TurnLoopPolicyEvaluator.evaluateContinuation(
                    conversation: conv,
                    anchorUserMessageID: anchorUserMessageID,
                    hasToolCallsInLatestAssistant: hasToolCallsInLatestAssistant,
                    hasHaltingToolCall: false,
                    terminationIterationState: iterState,
                    stopRequested: stopRequested,
                    continuationsUsed: continuationsUsed,
                    agentHarness: agentHarness,
                    runtimePolicy: await resolveRuntimePolicy(for: conv),
                    supportsForcedToolChoice: supportsForcedToolChoice(for: conv)
                )
                let previousStalls = iterState.consecutiveStalls
                iterState = decision.nextTerminationIterationState
                logStallCounterResetIfNeeded(
                    previousStalls: previousStalls,
                    currentStalls: iterState.consecutiveStalls,
                    conversationID: conversationID,
                    runID: runID,
                    reason: stallCounterResetReason(for: decision, hasToolCalls: false)
                )
                await lifecycleEmitter.emit(
                    .loopIterationCompleted(iteration: iteration, modelID: handle.modelID),
                    conversationID: conversationID,
                    runID: runID
                )
                if let terminal = decision.terminalReason {
                    return terminal
                }
                if decision.shouldRecover {
                    let runtimePolicy = await resolveRuntimePolicy(for: conv)
                    logTerminationRecovery(
                        conversationID: conversationID,
                        runID: runID,
                        attempt: iterState.consecutiveStalls,
                        runtimePolicy: runtimePolicy,
                        rollback: decision.rollbackStalledTurn,
                        decision: decision
                    )
                    toolChoice = Self.toolChoiceAfterRecoveryDecision(decision, runtimePolicy: runtimePolicy)
                    temperatureOverride = Self.behavioralRecoveryTemperature(decision, runtimePolicy: runtimePolicy)
                    if let reminder = decision.reminder {
                        ephemeralTail = await recoveryReminderMessages(
                            reminder: reminder,
                            attempt: iterState.consecutiveStalls
                        )
                    } else {
                        ephemeralTail = []
                    }
                } else {
                    toolChoice = .auto
                    temperatureOverride = nil
                    ephemeralTail = []
                }
                retriedCompactionThisIteration = false
                continuationsUsed += 1
                continue
            }
            var sawDispatchApprovalRequired = false
            let dispatchRuntimePolicy = await resolveRuntimePolicy(for: conv)
            toolDispatchLoop: for (callIndex, call) in assistant.toolCalls.enumerated() {
                let request = ToolCallRequest(id: call.id, name: call.name, arguments: call.arguments)
                await lifecycleEmitter.emit(
                    .toolCallStarted(
                        iteration: iteration,
                        modelID: handle.modelID,
                        toolName: call.name,
                        toolCallID: call.id
                    ),
                    conversationID: conversationID,
                    runID: runID
                )
                let outcome = await ports.tools.dispatch(
                    request,
                    conversationID: conversationID,
                    runID: runID,
                    orchestrator: orchestrator,
                    snapshot: snapshot,
                    configuration: configuration,
                    iteration: iteration,
                    modelID: handle.modelID,
                    runtimePolicy: dispatchRuntimePolicy,
                    lifecycleEmitter: lifecycleEmitter
                )
                switch outcome {
                case .approvalRequired(let toolName, let toolCallID):
                    sawDispatchApprovalRequired = true
                    await ports.tools.handleDispatchApprovalRequired(
                        toolName: toolName,
                        toolCallID: toolCallID,
                        snapshot: snapshot,
                        conversationID: conversationID,
                        runID: runID,
                        iteration: iteration,
                        modelID: handle.modelID,
                        lifecycleEmitter: lifecycleEmitter
                    )
                    try await appendApprovalPendingToolResults(
                        for: assistant.toolCalls,
                        startingAt: callIndex,
                        conversationID: conversationID,
                        runID: runID
                    )
                    break toolDispatchLoop
                case .completed(let message), .pendingHandle(let message), .denied(let message):
                    try await ports.conversation.append(message, conversationID: conversationID, runID: runID)
                    await lifecycleEmitter.emit(
                        .toolCallCompleted(
                            iteration: iteration,
                            modelID: handle.modelID,
                            toolName: call.name,
                            toolCallID: call.id
                        ),
                        conversationID: conversationID,
                        runID: runID
                    )
                    if ports.tools.isHaltSignal(call.name, in: snapshot) {
                        sawHaltSignal = true
                    }
                }
            }

            if sawDispatchApprovalRequired {
                let postDispatchPolicy = await resolveRuntimePolicy(for: conv)
                if let terminal = ModeRuntimePolicyEvaluator.stopOnApprovalTerminalReason(
                    runtime: postDispatchPolicy,
                    hasApprovalRequiredTools: true
                ) {
                    await lifecycleEmitter.emit(
                        .loopIterationCompleted(iteration: iteration, modelID: handle.modelID),
                        conversationID: conversationID,
                        runID: runID
                    )
                    await stampTerminalAssistantFinishReasonIfNeeded(
                        assistant: assistant,
                        terminal: terminal,
                        conversationID: conversationID
                    )
                    return terminal
                }
            }

            guard let convAfter = await ports.conversation.conversation(id: conversationID) else {
                return ConversationRunTerminalReason(category: .naturalStop, detail: "conversation_not_found_after_iteration")
            }
            let postDispatchRuntimePolicy = await resolveRuntimePolicy(for: convAfter)
            let userStopRequested = await ports.conversation.stopRequested(conversationID: conversationID)
            let stopRequested = Task.isCancelled || userStopRequested
            let decision = TurnLoopPolicyEvaluator.evaluateContinuation(
                conversation: convAfter,
                anchorUserMessageID: anchorUserMessageID,
                hasToolCallsInLatestAssistant: !rejectedBareRequiredTurn && !assistant.toolCalls.isEmpty,
                hasHaltingToolCall: sawHaltSignal,
                terminationIterationState: iterState,
                stopRequested: stopRequested,
                continuationsUsed: continuationsUsed,
                agentHarness: agentHarness,
                runtimePolicy: postDispatchRuntimePolicy,
                supportsForcedToolChoice: supportsForcedToolChoice(for: convAfter)
            )
            let previousStalls = iterState.consecutiveStalls
            iterState = decision.nextTerminationIterationState
            logStallCounterResetIfNeeded(
                previousStalls: previousStalls,
                currentStalls: iterState.consecutiveStalls,
                conversationID: conversationID,
                runID: runID,
                reason: stallCounterResetReason(
                    for: decision,
                    hasToolCalls: !rejectedBareRequiredTurn && !assistant.toolCalls.isEmpty,
                    hasHaltingToolCall: sawHaltSignal
                )
            )

            await lifecycleEmitter.emit(
                .loopIterationCompleted(iteration: iteration, modelID: handle.modelID),
                conversationID: conversationID,
                runID: runID
            )

            if let terminal = decision.terminalReason {
                if terminal.category == ConversationRunTerminalCategory.externalCancellation {
                    await ports.conversation.appendRunCancelledMarker(
                        conversationID: conversationID,
                        runID: runID,
                        iteration: iteration
                    )
                }
                if terminal.category == ConversationRunTerminalCategory.naturalStop, !hasTranscriptDeltaAcrossRun {
                    return ConversationRunTerminalReason(
                        category: ConversationRunTerminalCategory.naturalStop,
                        detail: (terminal.detail.map { "\($0); zero_transcript_delta" }) ?? "zero_transcript_delta"
                    )
                }
                await stampTerminalAssistantFinishReasonIfNeeded(
                    assistant: assistant,
                    terminal: terminal,
                    conversationID: conversationID
                )
                return terminal
            }

            if decision.shouldRecover {
                if decision.rollbackStalledTurn {
                    await ports.conversation.rollbackAssistantTurn(
                        messageID: assistant.id,
                        conversationID: conversationID
                    )
                }
                logTerminationRecovery(
                    conversationID: conversationID,
                    runID: runID,
                    attempt: iterState.consecutiveStalls,
                    runtimePolicy: postDispatchRuntimePolicy,
                    rollback: decision.rollbackStalledTurn,
                    decision: decision
                )
                toolChoice = Self.toolChoiceAfterRecoveryDecision(decision, runtimePolicy: postDispatchRuntimePolicy)
                temperatureOverride = Self.behavioralRecoveryTemperature(decision, runtimePolicy: postDispatchRuntimePolicy)
                if let reminder = decision.reminder {
                    ephemeralTail = await recoveryReminderMessages(
                        reminder: reminder,
                        attempt: iterState.consecutiveStalls
                    )
                } else {
                    ephemeralTail = []
                }
                if decision.injectThinkRecovery {
                    _ = await injectThinkRecoveryTurn(
                        conversationID: conversationID,
                        runID: runID,
                        orchestrator: orchestrator,
                        snapshot: snapshot,
                        configuration: configuration,
                        iteration: iteration,
                        modelID: handle.modelID,
                        runtimePolicy: postDispatchRuntimePolicy,
                        lifecycleEmitter: lifecycleEmitter
                    )
                }
            } else {
                toolChoice = .auto
                temperatureOverride = nil
                ephemeralTail = []
            }
            retriedCompactionThisIteration = false
            continuationsUsed += 1
        }

        return ConversationRunTerminalReason(
            category: .boundedStop,
            boundedReason: .maxAgentIterations
        )
    }

    private func stampTerminalAssistantFinishReasonIfNeeded(
        assistant: Message,
        terminal: ConversationRunTerminalReason,
        conversationID: UUID
    ) async {
        guard assistant.toolCalls.isEmpty else { return }
        switch terminal.category {
        case .naturalStop, .boundedStop:
            await ports.conversation.stampAssistantFinishReason(
                messageID: assistant.id,
                conversationID: conversationID,
                finishReason: "stop"
            )
        default:
            break
        }
    }

    private func publishStreamDelta(
        _ event: ModelStreamEvent,
        conversationID: UUID,
        runID: UUID?
    ) async -> Bool {
        var published = false
        switch event {
        case .stream(let chunk):
            if !chunk.content.isEmpty {
                await publishDelta(.text(chunk.content), conversationID, runID)
                published = true
            }
            if let fragment = chunk.streamingFragment {
                switch fragment {
                case .text(let text):
                    if !text.isEmpty {
                        await publishDelta(.text(text), conversationID, runID)
                        published = true
                    }
                case .reasoning(let text):
                    await publishDelta(.reasoning(text, blockIndex: nil), conversationID, runID)
                    published = true
                case .toolCall(let id, let name, let args):
                    await publishDelta(
                        .toolCall(toolName: name, toolCallId: id, argumentsFragment: args, blockIndex: nil),
                        conversationID,
                        runID
                    )
                    published = true
                case .toolCallStarted(let id, let name, let contentIndex):
                    await publishDelta(
                        .toolCallStarted(toolName: name, toolCallId: id, contentIndex: contentIndex),
                        conversationID,
                        runID
                    )
                    published = true
                case .toolCallCompleted(let id, let name, let arguments):
                    await publishDelta(
                        .toolCallCompleted(
                            toolName: name,
                            toolCallId: id,
                            arguments: arguments,
                            blockIndex: nil
                        ),
                        conversationID,
                        runID
                    )
                    published = true
                }
            }
        case .complete:
            break
        }
        return published
    }

    private func appendApprovalPendingToolResults(
        for toolCalls: [ToolCall],
        startingAt startIndex: Int,
        conversationID: UUID,
        runID: UUID?
    ) async throws {
        guard startIndex < toolCalls.count else { return }
        for call in toolCalls[startIndex...] {
            let message = AgentLoopToolDispatch.approvalPendingToolResultMessage(toolCallId: call.id)
            try await ports.conversation.append(message, conversationID: conversationID, runID: runID)
        }
    }

    private func shouldRetryCompaction(_ error: Error) -> Bool {
        ContextWindowRecoveryCoordinator.shouldRetry(
            error: error,
            config: ports.contextCompaction,
            alreadyRetriedThisTurn: false
        )
    }

    private func resolveHarness() async -> AgentHarnessConfiguration {
        ports.agentHarness
    }

    private func resolveMaxIterations(conversationID: UUID) async -> Int {
        guard let conv = await ports.conversation.conversation(id: conversationID) else {
            return Self.defaultTurnLoopMaxIterations
        }
        let profile = await ContextEngineProjectionPolicyBuilder.resolvedModeProfile(
            for: conv,
            modeRegistry: ports.modeRegistry,
            logger: ports.logger
        )
        return profile.runtime.maxIterations ?? Self.defaultTurnLoopMaxIterations
    }

    private static let defaultTurnLoopMaxIterations = Int.max

    private func resolveRuntimePolicy(for conversation: ModelConversation) async -> ModeProfileRuntimeSlice {
        let profile = await ContextEngineProjectionPolicyBuilder.resolvedModeProfile(
            for: conversation,
            modeRegistry: ports.modeRegistry,
            logger: ports.logger
        )
        return profile.runtime
    }

    /// Whether the conversation's model advertises provider-enforced forced tool choice.
    /// Drives capability-aware recovery: unsupported models degrade to behavioral fallback.
    private func supportsForcedToolChoice(for conversation: ModelConversation) -> Bool {
        conversation.model.requestFeatures.toolChoiceModes.contains(.required)
    }

    private static func toolChoiceAfterRecoveryDecision(
        _ decision: TurnLoopPolicyEvaluator.ContinuationDecision,
        runtimePolicy: ModeProfileRuntimeSlice
    ) -> RuntimeToolChoicePosture {
        guard decision.shouldRecover else { return .auto }
        guard runtimePolicy.termination?.policy == .terminalTool else { return .auto }
        return decision.toolChoiceNext == .required ? .required : .auto
    }

    /// Temperature nudge applied to the next model call during *behavioral* recovery (auto posture).
    /// Forced recovery enforces `tool_choice` at the provider, so it keeps the configured temperature.
    private static func behavioralRecoveryTemperature(
        _ decision: TurnLoopPolicyEvaluator.ContinuationDecision,
        runtimePolicy: ModeProfileRuntimeSlice
    ) -> Double? {
        guard decision.shouldRecover, decision.toolChoiceNext != .required else { return nil }
        return runtimePolicy.termination?.recovery?.behavioralRecoveryTemperature
    }

    private func requiredToolChoiceTerminalIfUnsatisfiable(
        snapshot: RuntimeToolTurnPolicySnapshot,
        conversationID: UUID,
        runID: UUID?,
        iteration: Int
    ) -> ConversationRunTerminalReason? {
        guard snapshot.effectiveTools.isEmpty else { return nil }
        ports.logger?.error(
            "[TurnLoop] required tool choice with no callable tools conversationID=\(conversationID.uuidString) runID=\(runID?.uuidString ?? "nil") iteration=\(iteration)"
        )
        return ConversationRunTerminalReason(
            category: .boundedStop,
            boundedReason: .maxAgentIterations,
            detail: "required_tool_choice_unsatisfiable"
        )
    }

    private func logTerminationRecovery(
        conversationID: UUID,
        runID: UUID?,
        attempt: Int,
        runtimePolicy: ModeProfileRuntimeSlice,
        rollback: Bool,
        decision: TurnLoopPolicyEvaluator.ContinuationDecision
    ) {
        let maxAttempts = max(1, runtimePolicy.termination?.recovery?.maxAttempts ?? 2)
        let strategy = decision.toolChoiceNext == .required ? "forced" : "behavioral"
        ports.logger?.info(
            "[TurnLoop] termination recovery conversationID=\(conversationID.uuidString) runID=\(runID?.uuidString ?? "nil") attempt=\(attempt)/\(maxAttempts) strategy=\(strategy) injectThink=\(decision.injectThinkRecovery) rollbackStalledTurn=\(rollback)"
        )
    }

    private func stallCounterResetReason(
        for decision: TurnLoopPolicyEvaluator.ContinuationDecision,
        hasToolCalls: Bool,
        hasHaltingToolCall: Bool = false
    ) -> String {
        if hasHaltingToolCall { return "halt_signal" }
        if hasToolCalls { return "tool_calls" }
        return "progress"
    }

    private func logStallCounterResetIfNeeded(
        previousStalls: Int,
        currentStalls: Int,
        conversationID: UUID,
        runID: UUID?,
        reason: String
    ) {
        guard previousStalls > 0, currentStalls == 0 else { return }
        ports.logger?.info(
            "[TurnLoop] termination recovery stall counter reset conversationID=\(conversationID.uuidString) runID=\(runID?.uuidString ?? "nil") previousStalls=\(previousStalls) reason=\(reason)"
        )
    }

    /// Behavioral recovery for models that cannot be API-forced: fabricate and dispatch a
    /// deterministic `think` tool call so the loop makes progress and the text-only stall is broken.
    /// The stall counter is intentionally left climbing so repeated stalls still exhaust `maxAttempts`.
    /// Returns true when a `think` turn was injected.
    private func injectThinkRecoveryTurn(
        conversationID: UUID,
        runID: UUID?,
        orchestrator: SwiftAgentKitOrchestrator,
        snapshot: RuntimeToolTurnPolicySnapshot,
        configuration: AgentRuntimeTurnConfiguration,
        iteration: Int,
        modelID: UUID,
        runtimePolicy: ModeProfileRuntimeSlice,
        lifecycleEmitter: AgentRuntimeLifecycleEmitter
    ) async -> Bool {
        let thinkName = TerminationToolProvider.thinkToolName
        guard snapshot.effectiveTools.contains(where: { $0.name == thinkName }) else {
            ports.logger?.warning(
                "[TurnLoop] behavioral recovery wanted think injection but think tool unavailable conversationID=\(conversationID.uuidString)"
            )
            return false
        }
        let toolCallID = UUID().uuidString
        let arguments = JSON.object(["conversation_id": .string(conversationID.uuidString)])
        let assistant = Message(
            id: UUID(),
            role: .assistant,
            content: "",
            timestamp: Date(),
            toolCalls: [ToolCall(name: thinkName, arguments: arguments, id: toolCallID)]
        )
        do {
            try await ports.conversation.append(assistant, conversationID: conversationID, runID: runID)
        } catch {
            ports.logger?.error("[TurnLoop] failed to append injected think assistant turn: \(error)")
            return false
        }
        let outcome = await ports.tools.dispatch(
            ToolCallRequest(id: toolCallID, name: thinkName, arguments: arguments),
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
        switch outcome {
        case .completed(let message), .pendingHandle(let message), .denied(let message):
            try? await ports.conversation.append(message, conversationID: conversationID, runID: runID)
        case .approvalRequired:
            break
        }
        ports.logger?.info(
            "[TurnLoop] behavioral recovery injected think tool call conversationID=\(conversationID.uuidString) runID=\(runID?.uuidString ?? "nil") iteration=\(iteration)"
        )
        return true
    }

    private func recoveryReminderMessages(
        reminder: ModeProfileTerminationRecoveryReminder,
        attempt: Int
    ) async -> [Message] {
        guard reminder != .off else { return [] }
        let message = Message(
            id: UUID(),
            role: .system,
            content: """
            [Ephemeral runtime notice] A tool call is required for this turn.
            Attempt \(attempt). Call an allowed tool now. Use a terminal tool call when work is complete.
            """,
            timestamp: Date(),
            toolCalls: []
        )
        return [message]
    }

    private func resolveUserQuery(from messages: [Message], anchorUserMessageID: UUID?) -> String? {
        if let anchorUserMessageID,
           let anchored = messages.first(where: { $0.id == anchorUserMessageID && $0.role == .user })?.content,
           !anchored.isEmpty {
            return anchored
        }
        guard let content = messages.last(where: { $0.role == .user })?.content,
              !content.isEmpty else { return nil }
        return content
    }
}
