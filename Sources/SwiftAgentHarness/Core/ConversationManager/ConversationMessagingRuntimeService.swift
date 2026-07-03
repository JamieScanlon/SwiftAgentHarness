import EasyJSON
import Foundation
import Logging
import SwiftAgentKit

/// Conversation registry updates, message append/persistence, and projection refresh (Slice L1 Phase 3).
actor ConversationMessagingRuntimeService {
    private let deps: ConversationRuntimeDependencies
    private let persistenceDomain: ConversationPersistenceDomain
    private let agentRuntime: any AgentRuntimeOrchestratorBinding & AgentRuntimeOrchestrationEmitting
    private let contextProjection: ContextProjectionService
    private let startup: ConversationStartupService
    private let slashCommand: SlashCommandDispatchService
    private let lifecycle: any ConversationLifecycleServicing
    private let selection: ConversationSelectionAccessing
    private let sessionProjection: SessionProjectionAccessing
    private let topics: ConversationTopicPublicationPort
    private let toolEntryLookup = ToolRegistryEntryLookup()
    private var agentToolResultMiddlewares: [AgentToolResultMiddleware] = []

    init(
        deps: ConversationRuntimeDependencies,
        persistenceDomain: ConversationPersistenceDomain,
        agentRuntime: any AgentRuntimeOrchestratorBinding & AgentRuntimeOrchestrationEmitting,
        contextProjection: ContextProjectionService,
        startup: ConversationStartupService,
        slashCommand: SlashCommandDispatchService,
        lifecycle: any ConversationLifecycleServicing,
        selection: ConversationSelectionAccessing,
        sessionProjection: SessionProjectionAccessing,
        topics: ConversationTopicPublicationPort
    ) {
        self.deps = deps
        self.persistenceDomain = persistenceDomain
        self.agentRuntime = agentRuntime
        self.contextProjection = contextProjection
        self.startup = startup
        self.slashCommand = slashCommand
        self.lifecycle = lifecycle
        self.selection = selection
        self.sessionProjection = sessionProjection
        self.topics = topics
    }

    private var logger: Logger? { deps.logger }

    func update(conversation: ModelConversation) async {
        logger?.info("[ConversationMessagingRuntimeService] Updating conversation \(conversation.id)")
        await persistenceDomain.replaceConversationInRegistry(conversation)
        await syncSessionProjectionFromRegistry(conversationID: conversation.id, convo: conversation)
        try? await persistenceDomain.persistConversationResourceFields(
            conversation,
            streamingRunIDOverride: conversation.currentRunID
        )
    }

    func saveMessageToCache(
        _ message: Message,
        for conversationID: UUID,
        expectedPreviousTailHarnessMessageID: UUID? = nil,
        transcriptRunID: UUID? = nil
    ) async throws -> Message {
        try await persistenceDomain.routingSaveMessage(
            message,
            for: conversationID,
            resourceManager: await startup.resourceManagerForRuntime(),
            logger: logger,
            expectedPreviousTailHarnessMessageID: expectedPreviousTailHarnessMessageID,
            transcriptRunID: transcriptRunID
        )
    }

    func appendMessagesToConversation(_ inputMessages: [Message], conversationID: UUID) async {
        guard !inputMessages.isEmpty else { return }
        guard var updatedConversation = await persistenceDomain.modelConversation(id: conversationID) else {
            logger?.warning("[ConversationMessagingRuntimeService] Conversation \(conversationID) not found for message update. Aborting")
            return
        }
        var messages: [Message] = []
        messages.reserveCapacity(inputMessages.count)
        var replayContext = updatedConversation.messages
        let persistencePipeline = persistenceToolResultMiddlewarePipeline()
        for message in inputMessages {
            guard message.role == .tool else {
                messages.append(message)
                replayContext.append(message)
                continue
            }
            let toolCall = ConversationReplayRunner.toolCall(for: message, replayedMessages: replayContext)
            let transformedResult = await persistencePipeline.apply(
                stage: .persistence,
                toolCall: toolCall,
                result: ToolResult(
                    success: true,
                    content: message.content,
                    metadata: .object([:]),
                    toolCallId: message.toolCallId
                )
            )
            let rewrittenMessage = Message(
                id: message.id,
                role: message.role,
                content: transformedResult.content,
                timestamp: message.timestamp,
                images: message.images,
                toolCalls: message.toolCalls,
                toolCallId: message.toolCallId,
                responseFormat: message.responseFormat
            )
            messages.append(rewrittenMessage)
            replayContext.append(rewrittenMessage)
        }

        for message in messages where message.role == .tool {
            if let tid = message.toolCallId, !tid.isEmpty {
                logger?.debug("[ConversationMessagingRuntimeService] appendMessages: tool message id=\(message.id) toolCallId=\(tid) contentChars=\(message.content.count)")
            } else {
                logger?.warning("[ConversationMessagingRuntimeService] appendMessages: tool message id=\(message.id) toolCallId=nilOrEmpty contentChars=\(message.content.count)")
            }
        }

        let currentConversationID = await selection.currentConversationID()
        logger?.info("[ConversationMessagingRuntimeService] Updating conversation \(conversationID) with \(messages.count) messages (current=\(String(describing: currentConversationID)))")

        var metadataChanged = false
        var pendingToolRecords = await contextProjection.takePendingToolResultTransforms(conversationID: conversationID)
        var trimmedToolResultMessageIDs: [UUID] = []
        var trimmedToolCallIDs: [String] = []
        for message in messages where message.role == .tool {
            guard let toolCallID = message.toolCallId else { continue }
            let record = pendingToolRecords.removeValue(forKey: toolCallID)
            if applyToolResultDebugMetadata(
                conversation: &updatedConversation,
                messageID: message.id,
                origin: record?.origin ?? .original,
                originalContent: record?.originalContent
            ) {
                metadataChanged = true
            }
            if record?.origin == .synthesizedWithTransform {
                trimmedToolResultMessageIDs.append(message.id)
                trimmedToolCallIDs.append(toolCallID)
            }
        }

        updatedConversation.messages.append(contentsOf: messages)
        await preserveLatestRuntimeState(conversationID: conversationID, conversation: &updatedConversation)
        await persistenceDomain.replaceConversationInRegistry(updatedConversation)
        await appendEventsAndRefreshProjection(
            conversationID: conversationID,
            messages: messages,
            baseMessagesOverride: updatedConversation.messages
        )
        await persistenceDomain.persistToolResultTrimCheckpointIfNeededAsync(
            conversationID: conversationID,
            coveredMessageIDs: trimmedToolResultMessageIDs,
            trimmedToolCallIDs: trimmedToolCallIDs,
            logger: logger
        )
        updatedConversation.turns = await selection.transformedTurns(
            messages: updatedConversation.messages,
            interactionMode: updatedConversation.interactionMode,
            previousTurns: updatedConversation.turns
        )
        await preserveLatestRuntimeState(conversationID: conversationID, conversation: &updatedConversation)
        await persistenceDomain.replaceConversationInRegistry(updatedConversation)
        await refreshProjectedConversationMessages(conversationID: conversationID)

        for message in messages {
            do {
                let messageWithThumbs = try await saveMessageToCache(message, for: conversationID)
                if let idx = updatedConversation.messages.firstIndex(where: { $0.id == message.id }) {
                    updatedConversation.messages[idx] = messageWithThumbs
                }
            } catch {
                logger?.error("[ConversationMessagingRuntimeService] Error saving message to cache: \(error)")
            }
        }
        await preserveLatestRuntimeState(conversationID: conversationID, conversation: &updatedConversation)
        await persistenceDomain.replaceConversationInRegistry(updatedConversation)
        await refreshProjectedConversationMessages(conversationID: conversationID)
        if metadataChanged {
            try? await persistConversationMetadataToCache(
                conversationID: conversationID,
                metadata: updatedConversation.metadata
            )
        }
        try? await syncConversationTurnsInCache(
            conversationID: conversationID,
            interactionMode: updatedConversation.interactionMode,
            preferredTurns: updatedConversation.turns
        )
    }

    func syncConversationTurnsInCache(
        conversationID: UUID,
        interactionMode: InteractionMode,
        preferredTurns: [ConversationTurn]? = nil
    ) async throws {
        try await persistenceDomain.syncConversationTurnsInCache(
            conversationID: conversationID,
            interactionMode: interactionMode,
            preferredTurns: preferredTurns
        )
    }

    func stripRunTailAfterAnchorIfNeeded(conversationID: UUID, anchorUserMessageID: UUID) async {
        do {
            guard let conversation = await persistenceDomain.modelConversation(id: conversationID) else {
                return
            }
            let baseMessages = await persistenceDomain.transcriptBaseMessages(for: conversation)
            let preserveThroughID = RunTailStripping.preserveThroughMessageID(
                messages: baseMessages,
                anchorUserMessageID: anchorUserMessageID
            ) ?? anchorUserMessageID
            _ = try await persistenceDomain.routingRevertConversationPreservingPrefixThroughMessageAsync(
                conversationID: conversationID,
                messageID: preserveThroughID
            )
            if var conversation = await persistenceDomain.modelConversation(id: conversationID) {
                conversation.currentRunID = nil
                await update(conversation: conversation)
            }
        } catch {
            logger?.warning("[ConversationMessagingRuntimeService] cancel tail strip failed for conversation \(conversationID): \(error)")
        }
    }

    func refreshProjectedConversationMessages(
        conversationID: UUID,
        baseMessagesOverride: [Message]? = nil
    ) async {
        guard let conversation = await persistenceDomain.modelConversation(id: conversationID) else {
            return
        }
        let startedAt = Date()
        let baseMessages: [Message]
        if let baseMessagesOverride {
            baseMessages = baseMessagesOverride
        } else {
            baseMessages = await persistenceDomain.transcriptBaseMessages(for: conversation)
        }
        let projection = await persistenceDomain.projectUIMessagesWithMetrics(
            conversationID: conversationID,
            baseMessages: baseMessages
        )
        if projection.metrics.causalityRejectedSummaryCount > 0 || projection.metrics.overlapConflictResolvedCount > 0
            || projection.metrics.decodeRejectedSummaryCount > 0 || projection.metrics.invalidStructuralSummaryCount > 0
            || projection.metrics.unsuccessfulSummarySkippedCount > 0 || projection.metrics.deduplicatedSummaryEventCount > 0 {
            logger?.debug(
                "[ConversationMessagingRuntimeService] projection metrics conversationID=\(conversationID) rejected=\(projection.metrics.causalityRejectedSummaryCount) overlapResolved=\(projection.metrics.overlapConflictResolvedCount) decodeRejected=\(projection.metrics.decodeRejectedSummaryCount) invalidStructural=\(projection.metrics.invalidStructuralSummaryCount) unsuccessfulSkipped=\(projection.metrics.unsuccessfulSummarySkippedCount) deduped=\(projection.metrics.deduplicatedSummaryEventCount) frontier=\(projection.frontierEventID)"
            )
        }

        let projected = projection.messages
        let projectedHash = ConversationEventLogService.contentHash(for: projected)
        let applyOutcome = await sessionProjection.applySnapshotIfNotStale(
            conversationID: conversationID,
            messages: projected,
            frontierEventID: projection.frontierEventID,
            contentHash: projectedHash
        )
        let currentFrontier: Int
        let shouldPublish: Bool
        switch applyOutcome {
        case .applied(let publish):
            currentFrontier = projection.frontierEventID
            shouldPublish = publish
        case .droppedStale(let projectedFrontier, let storedFrontier):
            currentFrontier = storedFrontier
            shouldPublish = false
            await contextProjection.recordProjectionApplyMetrics(
                metrics: projection.metrics,
                projectedFrontierEventID: projectedFrontier,
                currentFrontierEventID: storedFrontier
            )
            logger?.debug("[ConversationMessagingRuntimeService] projection dropped stale snapshot conversationID=\(conversationID) projectedFrontier=\(projectedFrontier) currentFrontier=\(storedFrontier)")
            if let registryConversation = await persistenceDomain.modelConversation(id: conversationID) {
                let cached = await sessionProjection.projectedMessages(for: registryConversation)
                if registryConversation.messages.count > cached.count
                    || registryConversation.messages.last?.id != cached.last?.id {
                    await sessionProjection.syncFromRegistry(
                        conversationID: conversationID,
                        conversation: registryConversation
                    )
                }
            }
            return
        }
        let latency = max(0, Int(Date().timeIntervalSince(startedAt) * 1000.0))
        await contextProjection.recordProjectionApplyMetrics(
            metrics: projection.metrics,
            projectedFrontierEventID: projection.frontierEventID,
            currentFrontierEventID: currentFrontier,
            latencyMs: latency
        )
        if shouldPublish {
            await selection.setCurrentMessagesIfSelected(conversationID: conversationID, messages: projected)
        }
        if shouldPublish {
            let payload = ConversationTopicWireEncoding.messagesRefreshPayload(messages: projected)
            let assistantCount = projected.reduce(into: 0) { count, message in
                if message.role == .assistant { count += 1 }
            }
            if conversation.messages.count != projected.count
                || conversation.messages.last?.role != projected.last?.role {
                logger?.debug(
                    "[ConversationMessagingRuntimeService] messagesRefresh projection differs from registry conversationID=\(conversationID.uuidString) projectedCount=\(projected.count) registryCount=\(conversation.messages.count) projectedLastRole=\(projected.last?.role.rawValue ?? "nil") registryLastRole=\(conversation.messages.last?.role.rawValue ?? "nil") projectedFrontier=\(projection.frontierEventID)"
                )
            }
            logger?.debug(
                "[ConversationMessagingRuntimeService] Publishing messagesRefresh on conversation events topic conversationID=\(conversationID) count=\(projected.count) assistants=\(assistantCount) lastRole=\(projected.last?.role.rawValue ?? "nil") frontier=\(projection.frontierEventID) registryCount=\(conversation.messages.count) registryLastRole=\(conversation.messages.last?.role.rawValue ?? "nil")"
            )
            await topics.publishConversationTopicEventIfConfigured(
                conversationID: conversationID,
                payload: payload
            )
        }
    }

    func applyStreamingUserCancellation(conversationID: UUID) async {
        guard var conv = await persistenceDomain.modelConversation(id: conversationID) else { return }
        conv.state = .idle
        conv.agenticPhase = .idle
        conv.llmRequestPhase = nil
        conv.currentRunID = nil
        await update(conversation: conv)
        await agentRuntime.emitOrchestrationStateFromLiveSources(
            swiftAgentKitGeneration: nil,
            preferredConversationID: conversationID
        )
    }

    func applySendFailure(_ error: Error, conversationID: UUID) async {
        guard var conv = await persistenceDomain.modelConversation(id: conversationID) else { return }
        conv.state = .idle
        conv.agenticPhase = .idle
        await update(conversation: conv)
        await agentRuntime.emitOrchestrationStateFromLiveSources(
            swiftAgentKitGeneration: nil,
            preferredConversationID: conversationID
        )
        await slashCommand.drainPendingSlashCommandsIfNeeded(conversationID: conv.id)
    }

    func resolveOrchestratorTargetConversationID() async -> UUID? {
        if let scopeID = ConversationScope.current?.selfID {
            return scopeID
        }
        let lifecycle = await agentRuntime.lifecycleSnapshot(for: nil)
        if let streamingConversationID = lifecycle.activeStreamingConversationID {
            return streamingConversationID
        }
        return await selection.currentConversationID()
    }

    func waitUntilStreamingGenerationSettled(
        conversationID: UUID,
        runID: UUID?,
        timeoutMS: Int = 60_000
    ) async {
        guard timeoutMS > 0 else { return }
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000.0)
        while Date() < deadline {
            if await agentRuntime.streamingGenerationSettled(
                conversationID: conversationID,
                runID: runID
            ) {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func updateCurrentConversation(withMessages messages: [Message]) async {
        guard let conversationID = await resolveOrchestratorTargetConversationID() else {
            logger?.warning("[ConversationMessagingRuntimeService] No conversation id for orchestrator message update. Aborting")
            return
        }
        await appendMessagesToConversation(messages, conversationID: conversationID)
    }

    func rollbackLatestAssistantTurnForRuntime(
        conversationID: UUID,
        assistantMessageID: UUID?
    ) async {
        guard let assistantMessageID else { return }
        do {
            let prefixMessages = try await persistenceDomain.routingRevertActiveBranchRemovingAssistantMessageAsync(
                conversationID: conversationID,
                assistantMessageID: assistantMessageID
            )
            guard var conversation = await persistenceDomain.modelConversation(id: conversationID) else { return }
            conversation.messages = prefixMessages
            conversation.turns = await selection.transformedTurns(
                messages: prefixMessages,
                interactionMode: conversation.interactionMode,
                previousTurns: conversation.turns
            )
            await persistenceDomain.applyRegistryTranscriptTruncation(conversation)
            await syncSessionProjectionFromRegistry(conversationID: conversationID, convo: conversation)
        } catch {
            logger?.warning(
                "[ConversationMessagingRuntimeService] stalled-turn rollback failed for conversation \(conversationID): \(error)"
            )
        }
    }

    func installTurnToolRegistryEntries(_ entries: [ToolRegistryEntry]) async {
        await toolEntryLookup.install(entries)
    }

    /// Mounts a host-supplied runtime-delivery middleware on the tool-result seam. Registrations are
    /// applied (ordered by ``AgentToolResultMiddleware/order`` then `id`) at the order-100 slot of
    /// ``runtimeToolResultMiddlewarePipeline()``.
    func registerAgentToolResultMiddleware(_ middleware: AgentToolResultMiddleware) {
        agentToolResultMiddlewares.append(middleware)
    }

    func runtimeToolResultMiddlewarePipeline() -> ToolResultMiddlewarePipeline {
        ToolResultMiddlewarePipeline(
            registrations: [
                ToolResultMiddlewareRegistration(
                    id: "subdirectory-hint-tracker",
                    stage: .runtimeDelivery,
                    order: 50
                ) { toolCall, result in
                    await self.applySubdirectoryHintMiddleware(toolCall: toolCall, result: result)
                },
                ToolResultMiddlewareRegistration(
                    id: "agent-tool-result-middleware",
                    stage: .runtimeDelivery,
                    order: 100
                ) { toolCall, result in
                    await self.applyToolResultTransform(toolCall: toolCall, result: result)
                },
                ToolResultMiddlewareRegistration(
                    id: "external-content-envelope",
                    stage: .runtimeDelivery,
                    order: 200
                ) { toolCall, result in
                    await self.applyExternalContentMiddleware(toolCall: toolCall, result: result)
                },
            ]
        )
    }

    private func applyExternalContentMiddleware(toolCall: ToolCall, result: ToolResult) async -> ToolResult {
        let entry = await toolEntryLookup.entry(named: toolCall.name)
        return ToolResultExternalContentMiddleware.apply(
            toolCall: toolCall,
            result: result,
            entry: entry,
            logger: logger
        )
    }

    private func runtimeScopedConversationID(explicit: UUID? = nil) async -> UUID? {
        if let explicit { return explicit }
        if let scopeID = ConversationScope.current?.selfID {
            return scopeID
        }
        let lifecycle = await agentRuntime.lifecycleSnapshot(for: nil)
        return lifecycle.activeStreamingConversationID
    }

    private func applySubdirectoryHintMiddleware(toolCall: ToolCall, result: ToolResult) async -> ToolResult {
        guard let conversationID = await runtimeScopedConversationID(),
              let memoryService = (deps.contextEngine as? DefaultContextEngine)?.memoryService else {
            return result
        }
        let argsJSON = TransformingToolProvider.debugArgumentsString(for: toolCall)
        let content = await memoryService.appendSubdirectoryHintsIfNeeded(
            conversationID: conversationID,
            toolName: toolCall.name,
            toolArgumentsJSON: argsJSON,
            toolResultContent: result.content
        )
        guard content != result.content else { return result }
        return ToolResult(
            success: result.success,
            content: content,
            metadata: result.metadata,
            toolCallId: result.toolCallId
        )
    }

    /// Applies host-registered runtime-delivery middleware (the ``registerAgentToolResultMiddleware``
    /// seam) to a tool result, then runtime-stage formatting. When a middleware rewrites content it
    /// feeds the dormant `tool_result_trim` checkpoint via a `synthesizedWithTransform` pending
    /// record. With no host middleware mounted this is a deterministic passthrough that performs no
    /// LLM call.
    func applyToolResultTransform(toolCall: ToolCall, result: ToolResult, conversationID: UUID? = nil) async -> ToolResult {
        guard let resolvedConversationID = await runtimeScopedConversationID(explicit: conversationID),
              let conversation = await persistenceDomain.modelConversation(id: resolvedConversationID) else {
            return applyToolResultFormatting(result: result, stage: .runtime)
        }
        guard deps.conversationTransformConfiguration.toggles(for: conversation.interactionMode).enableToolResultTransform,
              !agentToolResultMiddlewares.isEmpty else {
            return applyToolResultFormatting(result: result, stage: .runtime)
        }
        let ordered = agentToolResultMiddlewares.sorted {
            $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order
        }
        var current = result
        for middleware in ordered {
            current = await middleware.transform(toolCall, current)
        }
        if current.content.count != result.content.count {
            logger?.info(
                "[ConversationMessagingRuntimeService] agent tool-result middleware applied for \(toolCall.name) (\(result.content.count) -> \(current.content.count) chars)"
            )
        }
        if let toolCallID = toolCall.id {
            let transformed = current.content != result.content
            let record = ContextProjectionService.PendingToolResultTransformRecord(
                origin: transformed ? .synthesizedWithTransform : .original,
                originalContent: transformed ? result.content : nil
            )
            await contextProjection.storePendingToolResultTransform(
                conversationID: resolvedConversationID,
                toolCallID: toolCallID,
                record: record
            )
        }
        return applyToolResultFormatting(result: current, stage: .runtime)
    }

    func applyTurnSummaryTransformIfNeeded(conversationID: UUID) async {
        guard let conversation = await persistenceDomain.modelConversation(id: conversationID) else {
            return
        }
        guard deps.conversationTransformConfiguration.toggles(for: conversation.interactionMode).enableTurnSummaryTransform else {
            return
        }
        let baselineMessageIDs = conversation.messages.map(\.id)
        guard let turnStart = conversation.messages.lastIndex(where: { $0.role == .user }) else {
            return
        }
        let turnMessages = Array(conversation.messages[turnStart...])
        guard turnMessages.count > 1 else {
            return
        }
        let basedOnEventID = await persistenceDomain.latestConversationEventID(conversationID: conversationID)
        let input = TurnSummaryTransformInput(
            conversation: ContextAssemblyService.conversationTransformMetadata(for: conversation),
            turnMessageRangeStartIndex: turnStart,
            turnMessages: turnMessages
        )
        do {
            let output = try await ContextAssemblyService.runTransformWithTimeout(
                transformTimeoutSeconds: deps.conversationTransformConfiguration.transformTimeoutSeconds
            ) {
                try await self.deps.conversationTransformer.transformTurnSummary(input)
            }
            let replacement = output.replacementTurnMessages
            guard !replacement.isEmpty else {
                return
            }
            if replacement.map(\.id) != turnMessages.map(\.id) || output.diagnostics != nil {
                logger?.info(
                    "[ConversationMessagingRuntimeService] transformTurnSummary applied (\(turnMessages.count) -> \(replacement.count) messages)\(output.diagnostics.map { " \($0)" } ?? "")"
                )
            }
            guard let latestConversation = await persistenceDomain.modelConversation(id: conversationID) else {
                return
            }
            let latestMessageIDs = latestConversation.messages.map(\.id)
            guard latestMessageIDs == baselineMessageIDs else {
                logger?.debug("[ConversationMessagingRuntimeService] transformTurnSummary skipped due to stale conversation snapshot")
                return
            }
            guard output.diagnostics == "turn_summary_success_result" else {
                return
            }
            guard let summaryMessage = replacement.last(where: { $0.role == .assistant }) else {
                return
            }
            let coveredMessages = Array(turnMessages.dropFirst())
            guard !coveredMessages.isEmpty else {
                return
            }
            let startEventID = await persistenceDomain.eventIDForMessage(conversationID: conversationID, messageID: coveredMessages.first?.id) ?? basedOnEventID
            let endEventID = await persistenceDomain.eventIDForMessage(conversationID: conversationID, messageID: coveredMessages.last?.id) ?? basedOnEventID
            let payload = SummaryCreatedEventPayload(
                summaryMessageID: summaryMessage.id,
                summaryContent: summaryMessage.content,
                coveredMessageIDs: coveredMessages.map(\.id),
                firstCoveredMessageID: coveredMessages.first?.id,
                basedOnEventID: basedOnEventID,
                startEventID: startEventID,
                endEventID: endEventID,
                basedOnTailMessageID: coveredMessages.last?.id,
                succeeded: output.diagnostics == "turn_summary_success_result",
                createdAt: summaryMessage.timestamp
            )
            do {
                try await persistenceDomain.routingAppendTurnSummaryEventAsync(
                    conversationID: conversationID,
                    payloadJSON: ConversationEventCodec.encode(payload),
                    basedOnEventID: basedOnEventID,
                    coversStartEventID: startEventID,
                    coversEndEventID: endEventID,
                    createdAt: summaryMessage.timestamp,
                    expectedDerivedSequence: nil
                )
                let afterSummaryEventID = await persistenceDomain.latestConversationEventID(conversationID: conversationID)
                try await persistenceDomain.routingAppendTurnFinalizedEventAsync(
                    conversationID: conversationID,
                    payloadJSON: ConversationEventCodec.encode(
                        TurnFinalizedEventPayload(
                            basedOnEventID: afterSummaryEventID,
                            createdAt: Date()
                        )
                    ),
                    basedOnEventID: afterSummaryEventID,
                    createdAt: Date(),
                    expectedDerivedSequence: nil
                )
            } catch {
                logger?.warning("[ConversationMessagingRuntimeService] derived journal append for turn summary failed: \(error)")
                return
            }
            await refreshProjectedConversationMessages(conversationID: conversationID)
            await persistenceDomain.applyBackgroundCompactionIfEligibleAsync(conversationID: conversationID)
        } catch {
            logger?.warning("[ConversationMessagingRuntimeService] transformTurnSummary failed; keeping original turn output: \(error)")
        }
    }

    func persistDelegateSpendSnapshot(conversationID: UUID) async {
        guard let delegateCostTracker = deps.delegateCostTracker else { return }
        var cursor: UUID? = conversationID
        var visited: Set<UUID> = []
        while let current = cursor, !visited.contains(current) {
            visited.insert(current)
            if let projected = await delegateCostTracker.projectedCostUSD(conversationID: current) {
                let existing = await persistenceDomain.modelConversation(id: current)?.budgetSnapshot
                let snapshot = ConversationBudgetSnapshot(
                    maxUSD: existing?.maxUSD,
                    spentUSD: projected,
                    contextBudgetRemainingTokens: existing?.contextBudgetRemainingTokens
                )
                do {
                    try await persistenceDomain.persistBudgetSnapshot(conversationID: current, snapshot: snapshot)
                    await delegateCostTracker.setConversationMaxUSD(
                        conversationID: current,
                        maxUSD: existing?.maxUSD
                    )
                } catch {
                    logger?.error("[ConversationMessagingRuntimeService] delegate spend snapshot persistence failed: \(error)")
                }
            }
            cursor = await persistenceDomain.modelConversation(id: current)?.parentConversationID
        }
    }

    func deleteConversation(conversationID: UUID) async throws {
        try await lifecycle.deleteConversation(conversationID: conversationID, hard: true)
    }

    func syncProjectionFromRegistry(conversationID: UUID) async {
        guard let conversation = await persistenceDomain.modelConversation(id: conversationID) else { return }
        await syncSessionProjectionFromRegistry(conversationID: conversationID, convo: conversation)
    }

    private func syncSessionProjectionFromRegistry(conversationID: UUID, convo: ModelConversation) async {
        await sessionProjection.syncFromRegistry(conversationID: conversationID, conversation: convo)
    }

    private func persistConversationMetadataToCache(conversationID: UUID, metadata: JSON?) async throws {
        guard let metadata else { return }
        try await persistenceDomain.persistConversationMetadataToCache(conversationID: conversationID, metadata: metadata)
    }

    private func appendEventsAndRefreshProjection(
        conversationID: UUID,
        messages: [Message],
        baseMessagesOverride: [Message]? = nil
    ) async {
        do {
            try await persistenceDomain.routingAppendMessageJournalEntriesAsync(conversationID: conversationID, messages: messages)
        } catch {
            logger?.error("[ConversationMessagingRuntimeService] raw journal append failed: \(error)")
        }
        await refreshProjectedConversationMessages(
            conversationID: conversationID,
            baseMessagesOverride: baseMessagesOverride
        )
    }

    private func persistenceToolResultMiddlewarePipeline() -> ToolResultMiddlewarePipeline {
        let formatting = deps.conversationTransformConfiguration.toolResultFormatting
        return ToolResultMiddlewarePipeline(
            registrations: [
                ToolResultMiddlewareRegistration(
                    id: "tool-result-persist-stage",
                    stage: .persistence,
                    order: 100
                ) { _, result in
                    ToolResultFormattingStack.apply(
                        result: result,
                        stage: .persistence,
                        configuration: formatting
                    )
                },
            ]
        )
    }

    private func applyToolResultFormatting(
        result: ToolResult,
        stage: ToolResultFormattingStage
    ) -> ToolResult {
        ToolResultFormattingStack.apply(
            result: result,
            stage: stage,
            configuration: deps.conversationTransformConfiguration.toolResultFormatting
        )
    }

    private func applyToolResultDebugMetadata(
        conversation: inout ModelConversation,
        messageID: UUID,
        origin: ContextProjectionService.ToolResultMessageOrigin,
        originalContent: String?
    ) -> Bool {
        var rootObject: [String: JSON] = {
            guard let metadata = conversation.metadata else { return [:] }
            if case .object(let object) = metadata {
                return object
            }
            return [:]
        }()
        let debugRootKey = "_transformDebug"
        var debugObject: [String: JSON] = {
            guard let existing = rootObject[debugRootKey], case .object(let object) = existing else {
                return [:]
            }
            return object
        }()

        var originByMessageID: [String: JSON] = {
            guard let existing = debugObject["toolResultMessageOriginByMessageID"],
                  case .object(let object) = existing else {
                return [:]
            }
            return object
        }()
        originByMessageID[messageID.uuidString] = .string(origin.rawValue)
        debugObject["toolResultMessageOriginByMessageID"] = .object(originByMessageID)

        if contextProjection.persistOriginalToolResultsDebugModeEnabled,
           origin == .synthesizedWithTransform,
           let originalContent {
            var originalByMessageID: [String: JSON] = {
                guard let existing = debugObject["originalToolResultByMessageID"],
                      case .object(let object) = existing else {
                    return [:]
                }
                return object
            }()
            originalByMessageID[messageID.uuidString] = .string(originalContent)
            debugObject["originalToolResultByMessageID"] = .object(originalByMessageID)
        }

        rootObject[debugRootKey] = .object(debugObject)
        conversation.metadata = .object(rootObject)
        return true
    }

    private func preserveLatestRuntimeState(conversationID: UUID, conversation: inout ModelConversation) async {
        guard let latest = await persistenceDomain.modelConversation(id: conversationID) else { return }
        conversation.state = latest.state
        conversation.agenticPhase = latest.agenticPhase
        conversation.llmRequestPhase = latest.llmRequestPhase
        conversation.currentRunID = latest.currentRunID
        conversation.controlPlaneRevision = latest.controlPlaneRevision
    }
}
