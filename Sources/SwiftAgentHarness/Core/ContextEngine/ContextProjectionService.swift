import Foundation
import Logging
import SwiftAgentKit

actor ContextProjectionService {
    struct ProjectionHardeningMetrics: Sendable {
        let staleProjectionDropCount: Int
        let causalityRejectedSummaryCount: Int
        let overlapConflictResolvedCount: Int
        let decodeRejectedSummaryCount: Int
        let invalidStructuralSummaryCount: Int
        let unsuccessfulSummarySkippedCount: Int
        let deduplicatedSummaryEventCount: Int
        let projectionApplyLatencyMsP50: Int
        let projectionApplyLatencyMsP95: Int
    }

    struct ContextTransformSnapshot: Sendable {
        struct MessageEntry: Sendable {
            let message: Message
            let origin: ContextTransformedMessageOrigin
            let sourceMessageIDs: [UUID]
        }

        let conversationID: UUID
        let phase: ContextTransformInvocationPhase
        let diagnostics: String?
        let transformedMessageEntries: [MessageEntry]
        let originalMessagesByID: [UUID: Message]
        let recordedAt: Date
    }

    enum ToolResultMessageOrigin: String, Sendable {
        case original
        case synthesizedWithTransform = "synthesized_with_transform"
    }

    struct PendingToolResultTransformRecord: Sendable {
        let origin: ToolResultMessageOrigin
        let originalContent: String?
    }

    private let deps: ConversationRuntimeDependencies
    private let agentRuntime: any AgentRuntimeTokenSnapshotting
    private let selection: ConversationSelectionAccessing
    private let topics: ConversationTopicPublicationPort

    private var consecutiveCompactionFailuresByConversationID: [UUID: Int] = [:]
    private var consecutiveLowSavingsCompactionsByConversationID: [UUID: Int] = [:]
    private var lastContextCompactionLLMDateByConversationID: [UUID: Date] = [:]
    private var lastAttachmentProjectionByConversationID: [UUID: ContextEngineAttachmentProjectionArtifact] = [:]
    private var lastContextTransformSnapshotByConversationID: [UUID: ContextTransformSnapshot] = [:]
    private var pendingToolResultTransformRecordsByConversationID: [UUID: [String: PendingToolResultTransformRecord]] = [:]
    nonisolated let persistOriginalToolResultsDebugModeEnabled: Bool = true

    private var staleProjectionDropCount: Int = 0
    private var causalityRejectedSummaryCount: Int = 0
    private var overlapConflictResolvedCount: Int = 0
    private var decodeRejectedSummaryCount: Int = 0
    private var invalidStructuralSummaryCount: Int = 0
    private var unsuccessfulSummarySkippedCount: Int = 0
    private var deduplicatedSummaryEventCount: Int = 0
    private var projectionApplyLatencyMs: [Int] = []

    init(
        deps: ConversationRuntimeDependencies,
        agentRuntime: any AgentRuntimeTokenSnapshotting,
        selection: ConversationSelectionAccessing,
        topics: ConversationTopicPublicationPort
    ) {
        self.deps = deps
        self.agentRuntime = agentRuntime
        self.selection = selection
        self.topics = topics
    }

    private func tokenSnapshots(for conversationID: UUID) async -> (lastPromptTokens: Int?, lastContextLimitTokens: Int?) {
        await agentRuntime.tokenSnapshotsForOrchestration(for: conversationID)
    }

    func cachedAttachmentProjection(conversationID: UUID) -> ContextEngineAttachmentProjectionArtifact? {
        lastAttachmentProjectionByConversationID[conversationID]
    }

    func makeProjectionContext(
        conversation: ModelConversation,
        configuration: HarnessRuntimeSession.Configuration? = nil
    ) async -> ContextEngineProjectionContext {
        let tokens = await tokenSnapshots(for: conversation.id)
        return await ContextEngineProjectionPolicyBuilder.makeProjectionContext(
            deps: deps,
            conversation: conversation,
            configuration: configuration,
            tokenSnapshots: tokens
        )
    }

    func contextCompactionGatingResponse(for conversation: ModelConversation) async -> ContextCompactionGatingResponse {
        let config = deps.conversationTransformConfiguration.contextCompaction
        let tokens = await tokenSnapshots(for: conversation.id)
        let modelContextLimit = tokens.lastContextLimitTokens
            ?? conversation.model.maxContextLength
            ?? config.fallbackContextLimitTokens
        let threshold = ContextCompactionPolicy.proactiveThresholdTokens(
            modelContextLimitTokens: modelContextLimit,
            config: config
        )
        let resolved = await ContextEngineProjectionPolicyBuilder.resolvedModeProfile(
            for: conversation,
            modeRegistry: deps.modeRegistry,
            logger: deps.logger
        )
        let enableCT = ContextEngineProjectionPolicyBuilder.shouldEnableContextTransform(
            interactionMode: conversation.interactionMode,
            contextCompactionLevel: resolved.context.compactionLevel,
            transformConfiguration: deps.conversationTransformConfiguration
        )
        return ContextCompactionGatingResponse(
            proactiveThresholdTokens: threshold,
            charactersPerToken: config.charactersPerToken,
            modelContextLimitTokens: modelContextLimit,
            enableContextTransform: enableCT,
            contextCompactionConfigEnabled: config.enabled
        )
    }

    nonisolated func manualRESTEnabled() -> Bool {
        deps.conversationTransformConfiguration.contextCompaction.manualRESTEnabled
    }

    func conversationServerMetadata(for conversation: ModelConversation) async -> ConversationServerMetadata {
        ConversationServerMetadata(contextCompactionGating: await contextCompactionGatingResponse(for: conversation))
    }

    func projectionContextBudgetForState(conversationID: UUID) async -> ConversationContextBudget? {
        guard let conversation = await deps.persistenceDomain.modelConversation(id: conversationID) else { return nil }
        let projectionContext = await makeProjectionContext(conversation: conversation, configuration: nil)
        let messages = await selection.projectedMessages(for: conversation)
        let request = ContextEngineProjectedContextBudgetRequest(
            messages: messages,
            conversation: conversation,
            compactionConfig: deps.conversationTransformConfiguration.contextCompaction,
            lastContextLimitTokens: projectionContext.lastContextLimitTokens,
            lastPromptTokens: projectionContext.lastPromptTokens,
            projectionPolicy: projectionContext.projectionPolicy
        )
        return await deps.contextEngine.projectedContextBudget(request: request)
    }

    func transformedContextMessages(
        from messages: [Message],
        conversation: ModelConversation,
        phase: ContextTransformInvocationPhase,
        configuration: AgentRuntimeTurnConfiguration,
        gatingOverride: ContextCompactionGatingOptions? = nil
    ) async -> [Message] {
        await transformedContextMessages(
            from: messages,
            conversation: conversation,
            phase: phase,
            configuration: HarnessRuntimeSession.Configuration(
                enableTools: configuration.enableTools,
                enableAgents: configuration.enableAgents,
                allowEscalatedTools: configuration.allowEscalatedTools,
                preApprovedToolNames: configuration.preApprovedToolNames,
                expectedPreviousTailHarnessMessageID: configuration.expectedPreviousTailHarnessMessageID,
                inputTrustRaw: configuration.inputTrustRaw,
                resolvedInputTrustClass: configuration.resolvedInputTrustClass
            ),
            gatingOverride: gatingOverride
        )
    }

    func transformedContextMessages(
        from messages: [Message],
        conversation: ModelConversation,
        phase: ContextTransformInvocationPhase,
        configuration: HarnessRuntimeSession.Configuration? = nil,
        gatingOverride: ContextCompactionGatingOptions? = nil
    ) async -> [Message] {
        let projectionContext = await makeProjectionContext(
            conversation: conversation,
            configuration: configuration
        )
        return await transformedContextMessages(
            from: messages,
            conversation: conversation,
            phase: phase,
            projectionContext: projectionContext,
            gatingOverride: gatingOverride
        )
    }

    func transformedContextMessages(
        from messages: [Message],
        conversation: ModelConversation,
        phase: ContextTransformInvocationPhase,
        projectionContext: ContextEngineProjectionContext,
        gatingOverride: ContextCompactionGatingOptions? = nil
    ) async -> [Message] {
        guard projectionContext.enableContextTransform else {
            return messages
        }
        let compactionCfg = deps.conversationTransformConfiguration.contextCompaction
        let bypassCircuit = gatingOverride?.forceRunCompactionLLM == true
        if compactionCfg.enabled,
           !bypassCircuit,
           consecutiveCompactionFailuresByConversationID[conversation.id, default: 0]
           >= compactionCfg.compactionCircuitBreakerMaxFailures {
            deps.logger?.warning(
                "[ContextProjectionService] auto-compaction circuit open for \(conversation.id) after \(compactionCfg.compactionCircuitBreakerMaxFailures) failures"
            )
            return messages
        }
        if compactionCfg.enabled,
           !bypassCircuit,
           consecutiveLowSavingsCompactionsByConversationID[conversation.id, default: 0]
           >= compactionCfg.compactionCircuitBreakerMaxFailures {
            deps.logger?.warning(
                "[ContextProjectionService] auto-compaction circuit open for \(conversation.id) after \(compactionCfg.compactionCircuitBreakerMaxFailures) low-savings compactions"
            )
            return messages
        }
        if bypassCircuit,
           compactionCfg.enabled,
           consecutiveCompactionFailuresByConversationID[conversation.id, default: 0]
               >= compactionCfg.compactionCircuitBreakerMaxFailures
           || consecutiveLowSavingsCompactionsByConversationID[conversation.id, default: 0]
               >= compactionCfg.compactionCircuitBreakerMaxFailures {
            deps.logger?.info(
                "[ContextProjectionService] bypassing auto-compaction circuit for \(conversation.id) (forceRunCompactionLLM emergency retry)"
            )
        }
        return await withCompactionCriticalSectionIfNeeded(
            conversationID: conversation.id,
            phase: phase,
            persistCompactionCheckpoint: true,
            onLockHeld: messages
        ) { lockHeldByCaller in
            let pipelineOutput = await ContextAssemblyPipeline.ingestAndOrchestratorAssemble(
                contextEngine: deps.contextEngine,
                persistenceDomain: deps.persistenceDomain,
                runtimeFacade: deps.contextAssemblyRuntime,
                conversationID: conversation.id,
                messages: messages,
                conversation: conversation,
                phase: phase,
                gatingOverride: gatingOverride,
                allowProactiveCompactionTriggers: projectionContext.resolvedMode.allowsProactiveCompactionTriggers,
                compactionLockAlreadyHeldByCaller: lockHeldByCaller,
                projectionPolicy: projectionContext.projectionPolicy,
                lastContextLimitTokens: projectionContext.lastContextLimitTokens,
                lastPromptTokens: projectionContext.lastPromptTokens,
                lastContextCompactionLLMDateByConversationID: lastContextCompactionLLMDateByConversationID,
                logger: deps.logger,
                performTransform: { input in
                    try await ContextAssemblyService.runTransformWithTimeout(
                        transformTimeoutSeconds: self.deps.conversationTransformConfiguration.transformTimeoutSeconds
                    ) {
                        try await self.deps.conversationTransformer.transformContext(input)
                    }
                }
            )
            let result = pipelineOutput.result
            let assembleRequest = pipelineOutput.assembleRequest
            if result.transformFailed {
                consecutiveCompactionFailuresByConversationID[conversation.id, default: 0] += 1
                deps.logger?.warning("[ContextProjectionService] transformContext failed; using original payload")
                return messages
            }
            consecutiveCompactionFailuresByConversationID[conversation.id] = 0
            if result.compactionLowSavings {
                consecutiveLowSavingsCompactionsByConversationID[conversation.id, default: 0] += 1
                deps.logger?.info(
                    "[ContextProjectionService] compaction skipped checkpoint (low savings) conversation=\(conversation.id) count=\(consecutiveLowSavingsCompactionsByConversationID[conversation.id] ?? 0)"
                )
            }
            if let output = result.transformOutput {
                recordContextTransformSnapshot(
                    conversation: conversation,
                    phase: phase,
                    originalMessages: messages,
                    output: output
                )
                await invalidateMemorySnapshotIfStoreVersionDrift(
                    conversationID: conversation.id,
                    events: assembleRequest.events,
                    frontierEventID: assembleRequest.eventLogFrontier,
                    currentMemoryStoreVersion: result.memoryInjectionSnapshot?.memoryStoreVersion
                )
                if output.messages.count != messages.count || output.diagnostics != nil {
                    deps.logger?.info(
                        "[ContextProjectionService] transformContext applied (\(messages.count) -> \(output.messages.count))\(output.diagnostics.map { " \($0)" } ?? "")"
                    )
                }
            }
            let persistenceEffects = pipelineOutput.persistenceEffects
            if persistenceEffects.persistedCompactionCheckpoint, let spec = result.checkpointPersistence {
                consecutiveLowSavingsCompactionsByConversationID[conversation.id] = 0
                lastContextCompactionLLMDateByConversationID[conversation.id] = Date()
                await topics.publishContextCompactionCheckpointTopic(spec: spec)
                deps.logger?.debug("[ContextProjectionService] persisted compaction checkpoint for \(spec.conversationID)")
            }
            if let attachmentProjection = persistenceEffects.attachmentProjectionArtifactForCache {
                lastAttachmentProjectionByConversationID[conversation.id] = attachmentProjection
            }
            return result.messages
        }
    }

    func projectModelContextPreview(
        conversationID: UUID,
        phase: ContextTransformInvocationPhase = .initial,
        gatingOverride: ContextCompactionGatingOptions? = nil
    ) async throws -> ContextModelContextPreviewResult {
        guard let conversation = await deps.persistenceDomain.modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        let messages = conversation.messages
        let projectionContext = await makeProjectionContext(conversation: conversation, configuration: nil)
        guard projectionContext.enableContextTransform else {
            return ContextModelContextPreviewResult(
                originalMessages: messages,
                projectedMessages: messages,
                passthroughReason: "context_transform_disabled",
                transformFailed: false
            )
        }
        let pipelineOutput = await ContextAssemblyPipeline.ingestAndOrchestratorAssemblePreview(
            contextEngine: deps.contextEngine,
            persistenceDomain: deps.persistenceDomain,
            runtimeFacade: deps.contextAssemblyRuntime,
            conversationID: conversation.id,
            messages: messages,
            conversation: conversation,
            phase: phase,
            gatingOverride: gatingOverride,
            allowProactiveCompactionTriggers: projectionContext.resolvedMode.allowsProactiveCompactionTriggers,
            projectionPolicy: projectionContext.projectionPolicy,
            lastContextLimitTokens: projectionContext.lastContextLimitTokens,
            lastPromptTokens: projectionContext.lastPromptTokens,
            lastContextCompactionLLMDateByConversationID: lastContextCompactionLLMDateByConversationID,
            performTransform: { input in
                try await ContextAssemblyService.runTransformWithTimeout(
                    transformTimeoutSeconds: self.deps.conversationTransformConfiguration.transformTimeoutSeconds,
                    timeoutSecondsOverride: ContextAssemblyService.contextCompactionPreviewTransformTaskTimeoutSeconds
                ) {
                    try await self.deps.conversationTransformer.transformContext(input)
                }
            }
        )
        let result = pipelineOutput.result
        return ContextModelContextPreviewResult(
            originalMessages: messages,
            projectedMessages: result.messages,
            passthroughReason: result.passthroughReason,
            transformFailed: result.transformFailed
        )
    }

    func performContextCompactionPreview(
        conversationID: UUID,
        gating: ContextCompactionGatingOptions,
        summarizerDebugOutputPath: String? = nil
    ) async throws -> ContextCompactionPreviewResult {
        guard let conversation = await deps.persistenceDomain.modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        let messages = conversation.messages
        let (compactionInjectedPrefix, compactionTranscript) =
            ContextCompactionCheckpointSupport.partitionForCompaction(messages)
        let projectionContext = await makeProjectionContext(conversation: conversation, configuration: nil)
        guard projectionContext.enableContextTransform else {
            return ContextCompactionPreviewResult(
                originalMessages: messages,
                compactedMessages: nil,
                diagnostics: nil,
                messageProvenance: nil,
                noopReason: "context_transform_disabled"
            )
        }
        let compactionConfig = deps.conversationTransformConfiguration.contextCompaction
        let transformMeta = ContextAssemblyService.conversationTransformMetadata(for: conversation)
        let (events, eventLogFrontier) = await deps.persistenceDomain.loadConversationEventsWithFrontier(conversationID: conversation.id)
        let initial = ContextCompactionInputBuilder.buildInitialPhaseInput(
            messages: compactionTranscript,
            conversation: conversation,
            transformMetadata: transformMeta,
            compactionConfig: compactionConfig,
            enableContextTransform: true,
            lastContextLimitTokens: projectionContext.lastContextLimitTokens,
            lastPromptTokens: projectionContext.lastPromptTokens,
            events: events,
            eventLogFrontier: eventLogFrontier,
            lastLLMDateByConversationID: lastContextCompactionLLMDateByConversationID,
            gating: gating,
            compactionSummarizerDebugOutputPath: summarizerDebugOutputPath,
            allowProactiveCompactionTriggers: true,
            compactionInjectedPrefix: compactionInjectedPrefix
        )
        switch initial {
        case .passthrough(let reason):
            return ContextCompactionPreviewResult(
                originalMessages: messages,
                compactedMessages: nil,
                diagnostics: nil,
                messageProvenance: nil,
                noopReason: reason
            )
        case .transform(let input):
            do {
                let output = try await ContextAssemblyService.runTransformWithTimeout(
                    transformTimeoutSeconds: deps.conversationTransformConfiguration.transformTimeoutSeconds,
                    timeoutSecondsOverride: ContextAssemblyService.contextCompactionPreviewTransformTaskTimeoutSeconds
                ) {
                    try await self.deps.conversationTransformer.transformContext(input)
                }
                let prov = (output.messageProvenance ?? []).map { p in
                    ContextCompactionProvenanceEntry(
                        transformedMessageID: p.transformedMessageID,
                        origin: p.origin.rawValue,
                        sourceMessageIDs: p.sourceMessageIDs
                    )
                }
                return ContextCompactionPreviewResult(
                    originalMessages: messages,
                    compactedMessages: output.messages,
                    diagnostics: output.diagnostics,
                    messageProvenance: prov.isEmpty ? nil : prov,
                    noopReason: nil
                )
            } catch {
                deps.logger?.warning("[ContextProjectionService] performContextCompactionPreview transform failed: \(error)")
                throw error
            }
        }
    }

    func performManualCompaction(
        conversationID: UUID,
        trigger: ContextCompactionManualTrigger,
        reason: String? = nil
    ) async throws -> ContextCompactionManualResult {
        guard let conversation = await deps.persistenceDomain.modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        let messages = conversation.messages
        let compactionConfig = deps.conversationTransformConfiguration.contextCompaction
        let projectionContext = await makeProjectionContext(conversation: conversation, configuration: nil)
        let modelContextLimit = projectionContext.lastContextLimitTokens
            ?? conversation.model.maxContextLength
            ?? compactionConfig.fallbackContextLimitTokens
        let promptTokens = ContextCompactionPolicy.resolvedTotalPromptTokens(
            messages: messages,
            lastActualPromptTokens: projectionContext.lastPromptTokens,
            charactersPerToken: compactionConfig.charactersPerToken
        )
        let thresholdTokens = ContextCompactionPolicy.proactiveThresholdTokens(
            modelContextLimitTokens: modelContextLimit,
            config: compactionConfig
        )

        if trigger == .modelTool {
            let gateTokens = max(0, Int(Double(thresholdTokens) * compactionConfig.manualToolMinUtilization))
            if promptTokens < gateTokens {
                let refusal = "Refused: conversation is below \(Int(compactionConfig.manualToolMinUtilization * 100))% of compaction threshold (\(promptTokens) / \(thresholdTokens) tokens; gate \(gateTokens))."
                deps.logger?.info("[ContextProjectionService] Manual compaction refused (modelTool below gate): \(refusal)")
                return ContextCompactionManualResult(
                    trigger: trigger,
                    conversationID: conversation.id,
                    originalMessages: messages,
                    compactedMessages: nil,
                    diagnostics: nil,
                    messageProvenance: nil,
                    noopReason: nil,
                    refusalReason: refusal,
                    persisted: false,
                    promptTokens: promptTokens,
                    thresholdTokens: thresholdTokens
                )
            }
        }

        guard projectionContext.enableContextTransform else {
            return ContextCompactionManualResult(
                trigger: trigger,
                conversationID: conversation.id,
                originalMessages: messages,
                compactedMessages: nil,
                diagnostics: nil,
                messageProvenance: nil,
                noopReason: "context_transform_disabled",
                refusalReason: nil,
                persisted: false,
                promptTokens: promptTokens,
                thresholdTokens: thresholdTokens
            )
        }

        let trimmedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let override: String? = {
            guard let trimmedReason, !trimmedReason.isEmpty else { return nil }
            let focus = ContextCompactionPolicy.focusedCompactionInstructionBlock(topic: trimmedReason)
            return "\(focus)\n\n\(trimmedReason)"
        }()
        return await withCompactionCriticalSectionIfNeeded(
            conversationID: conversation.id,
            phase: .initial,
            persistCompactionCheckpoint: true,
            onLockHeld: ContextCompactionManualResult(
                trigger: trigger,
                conversationID: conversation.id,
                originalMessages: messages,
                compactedMessages: nil,
                diagnostics: nil,
                messageProvenance: nil,
                noopReason: "compaction_lock_held",
                refusalReason: nil,
                persisted: false,
                promptTokens: promptTokens,
                thresholdTokens: thresholdTokens
            )
        ) { lockHeldByCaller in
            let pipelineOutput = await ContextAssemblyPipeline.ingestAndManualCompact(
                contextEngine: deps.contextEngine,
                persistenceDomain: deps.persistenceDomain,
                runtimeFacade: deps.contextAssemblyRuntime,
                conversationID: conversation.id,
                messages: messages,
                conversation: conversation,
                compactionCustomInstructionsOverride: override,
                compactionLockAlreadyHeldByCaller: lockHeldByCaller,
                projectionPolicy: projectionContext.projectionPolicy,
                lastContextLimitTokens: projectionContext.lastContextLimitTokens,
                lastPromptTokens: projectionContext.lastPromptTokens,
                lastContextCompactionLLMDateByConversationID: lastContextCompactionLLMDateByConversationID,
                logger: deps.logger,
                performTransform: { input in
                    try await ContextAssemblyService.runTransformWithTimeout(
                        transformTimeoutSeconds: self.deps.conversationTransformConfiguration.transformTimeoutSeconds
                    ) {
                        try await self.deps.conversationTransformer.transformContext(input)
                    }
                }
            )
            let result = pipelineOutput.result
            let assembleRequest = pipelineOutput.assembleRequest
            if result.transformFailed {
                consecutiveCompactionFailuresByConversationID[conversation.id, default: 0] += 1
                deps.logger?.warning("[ContextProjectionService] Manual compaction transform failed")
                return ContextCompactionManualResult(
                    trigger: trigger,
                    conversationID: conversation.id,
                    originalMessages: messages,
                    compactedMessages: nil,
                    diagnostics: nil,
                    messageProvenance: nil,
                    noopReason: "context_compaction_failed",
                    refusalReason: nil,
                    persisted: false,
                    promptTokens: promptTokens,
                    thresholdTokens: thresholdTokens
                )
            }
            consecutiveCompactionFailuresByConversationID[conversation.id] = 0
            if result.compactionLowSavings, trigger == .modelTool {
                consecutiveLowSavingsCompactionsByConversationID[conversation.id, default: 0] += 1
            }
            guard let output = result.transformOutput else {
                return ContextCompactionManualResult(
                    trigger: trigger,
                    conversationID: conversation.id,
                    originalMessages: messages,
                    compactedMessages: nil,
                    diagnostics: nil,
                    messageProvenance: nil,
                    noopReason: result.passthroughReason ?? "context_compaction_noop",
                    refusalReason: nil,
                    persisted: false,
                    promptTokens: promptTokens,
                    thresholdTokens: thresholdTokens
                )
            }
            let prov = (output.messageProvenance ?? []).map { p in
                ContextCompactionProvenanceEntry(
                    transformedMessageID: p.transformedMessageID,
                    origin: p.origin.rawValue,
                    sourceMessageIDs: p.sourceMessageIDs
                )
            }
            await invalidateMemorySnapshotIfStoreVersionDrift(
                conversationID: conversation.id,
                events: assembleRequest.events,
                frontierEventID: assembleRequest.eventLogFrontier,
                currentMemoryStoreVersion: result.memoryInjectionSnapshot?.memoryStoreVersion
            )
            let persisted = pipelineOutput.persistenceEffects.persistedCompactionCheckpoint
            if persisted, let spec = result.checkpointPersistence {
                consecutiveLowSavingsCompactionsByConversationID[conversation.id] = 0
                lastContextCompactionLLMDateByConversationID[conversation.id] = Date()
                await topics.publishContextCompactionCheckpointTopic(spec: spec)
            }
            deps.logger?.info(
                "[ContextProjectionService] Manual compaction (\(trigger.rawValue)) for \(conversation.id) -> \(messages.count)→\(output.messages.count) messages, persisted=\(persisted)\(output.diagnostics.map { " diag=\($0)" } ?? "")"
            )
            return ContextCompactionManualResult(
                trigger: trigger,
                conversationID: conversation.id,
                originalMessages: messages,
                compactedMessages: output.messages,
                diagnostics: output.diagnostics,
                messageProvenance: prov.isEmpty ? nil : prov,
                noopReason: nil,
                refusalReason: nil,
                persisted: persisted,
                promptTokens: promptTokens,
                thresholdTokens: thresholdTokens
            )
        }
    }

    func recordContextTransformSnapshot(
        conversation: ModelConversation,
        phase: ContextTransformInvocationPhase,
        originalMessages: [Message],
        output: ContextTransformOutput
    ) {
        let originalByID = Dictionary(originalMessages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let provenanceByTransformedID = Dictionary(
            (output.messageProvenance ?? []).map { ($0.transformedMessageID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let entries = output.messages.map { message in
            let provenance = provenanceByTransformedID[message.id]
            return ContextTransformSnapshot.MessageEntry(
                message: message,
                origin: provenance?.origin ?? .original,
                sourceMessageIDs: provenance?.sourceMessageIDs ?? [message.id]
            )
        }
        lastContextTransformSnapshotByConversationID[conversation.id] = ContextTransformSnapshot(
            conversationID: conversation.id,
            phase: phase,
            diagnostics: output.diagnostics,
            transformedMessageEntries: entries,
            originalMessagesByID: originalByID,
            recordedAt: Date()
        )
    }

    func originalMessagesForTransformedContextMessage(
        conversationID: UUID,
        transformedMessageID: UUID
    ) -> [Message] {
        guard let snapshot = lastContextTransformSnapshotByConversationID[conversationID],
              let entry = snapshot.transformedMessageEntries.first(where: { $0.message.id == transformedMessageID }) else {
            return []
        }
        return entry.sourceMessageIDs.compactMap { snapshot.originalMessagesByID[$0] }
    }

    func lastContextTransformSnapshot(conversationID: UUID) -> ContextTransformSnapshot? {
        lastContextTransformSnapshotByConversationID[conversationID]
    }

    func storePendingToolResultTransform(
        conversationID: UUID,
        toolCallID: String,
        record: PendingToolResultTransformRecord
    ) {
        var byToolCallID = pendingToolResultTransformRecordsByConversationID[conversationID] ?? [:]
        byToolCallID[toolCallID] = record
        pendingToolResultTransformRecordsByConversationID[conversationID] = byToolCallID
    }

    func takePendingToolResultTransforms(
        conversationID: UUID
    ) -> [String: PendingToolResultTransformRecord] {
        let records = pendingToolResultTransformRecordsByConversationID[conversationID] ?? [:]
        pendingToolResultTransformRecordsByConversationID[conversationID] = [:]
        return records
    }

    func recordProjectionApplyMetrics(
        metrics: ConversationProjection.ProjectionMetrics,
        projectedFrontierEventID: Int,
        currentFrontierEventID: Int,
        latencyMs: Int? = nil
    ) {
        causalityRejectedSummaryCount += metrics.causalityRejectedSummaryCount
        overlapConflictResolvedCount += metrics.overlapConflictResolvedCount
        decodeRejectedSummaryCount += metrics.decodeRejectedSummaryCount
        invalidStructuralSummaryCount += metrics.invalidStructuralSummaryCount
        unsuccessfulSummarySkippedCount += metrics.unsuccessfulSummarySkippedCount
        deduplicatedSummaryEventCount += metrics.deduplicatedSummaryEventCount
        if projectedFrontierEventID < currentFrontierEventID {
            staleProjectionDropCount += 1
        }
        if let latencyMs {
            projectionApplyLatencyMs.append(latencyMs)
            if projectionApplyLatencyMs.count > 512 {
                projectionApplyLatencyMs.removeFirst(projectionApplyLatencyMs.count - 512)
            }
        }
    }

    func projectionHardeningMetrics() -> ProjectionHardeningMetrics {
        let sorted = projectionApplyLatencyMs.sorted()
        func percentile(_ p: Double) -> Int {
            guard !sorted.isEmpty else { return 0 }
            let idx = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))
            return sorted[idx]
        }
        return ProjectionHardeningMetrics(
            staleProjectionDropCount: staleProjectionDropCount,
            causalityRejectedSummaryCount: causalityRejectedSummaryCount,
            overlapConflictResolvedCount: overlapConflictResolvedCount,
            decodeRejectedSummaryCount: decodeRejectedSummaryCount,
            invalidStructuralSummaryCount: invalidStructuralSummaryCount,
            unsuccessfulSummarySkippedCount: unsuccessfulSummarySkippedCount,
            deduplicatedSummaryEventCount: deduplicatedSummaryEventCount,
            projectionApplyLatencyMsP50: percentile(0.50),
            projectionApplyLatencyMsP95: percentile(0.95)
        )
    }

    private func invalidateMemorySnapshotIfStoreVersionDrift(
        conversationID: UUID,
        events: [CachedConversationEvent],
        frontierEventID: Int,
        currentMemoryStoreVersion: Int?
    ) async {
        guard let currentMemoryStoreVersion else { return }
        guard let latest = SuiteCheckpointSupport.latestValidMemoryInjectionSnapshot(
            events: events,
            frontierEventID: frontierEventID
        ) else { return }
        if latest.wire.memoryStoreVersion == currentMemoryStoreVersion {
            return
        }
        do {
            try await deps.persistenceDomain.routingAppendCheckpointInvalidationAsync(
                conversationID: conversationID,
                kinds: [HarnessCheckpointInvalidationKind.memoryInjectionSnapshot]
            )
            await topics.publishCheckpointInvalidationOnTopic(
                conversationID: conversationID,
                invalidatedKinds: [HarnessCheckpointInvalidationKind.memoryInjectionSnapshot]
            )
        } catch {
            deps.logger?.warning("[ContextProjectionService] memory snapshot auto-invalidation failed: \(error)")
        }
    }

    private func withCompactionCriticalSectionIfNeeded<T>(
        conversationID: UUID,
        phase: ContextTransformInvocationPhase,
        persistCompactionCheckpoint: Bool,
        onLockHeld: @autoclosure () -> T,
        operation: (_ lockHeldByCaller: Bool) async -> T
    ) async -> T {
        let requiresLock: Bool
        switch phase {
        case .initial:
            requiresLock = persistCompactionCheckpoint
        case .continuation:
            requiresLock = false
        }
        guard requiresLock else {
            return await operation(false)
        }
        let acquired = await deps.compactionCoordinator.tryAcquire(for: conversationID)
        guard acquired else {
            return onLockHeld()
        }
        let result = await operation(true)
        await deps.compactionCoordinator.release(for: conversationID)
        return result
    }
}
