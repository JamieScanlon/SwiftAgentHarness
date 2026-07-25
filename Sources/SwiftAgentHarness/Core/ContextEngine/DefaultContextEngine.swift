import CryptoKit
import Foundation
import Logging
import SwiftAgentKit

/// Default harness-aligned Context Engine: builds transform inputs via ``ContextCompactionInputBuilder``,
/// invokes the injected transformer, and emits checkpoint persistence specs for initial-phase compaction.
public struct DefaultContextEngine: ContextEngine, Sendable {
    private let compactionCoordinator: CompactionConcurrencyCoordinator?
    public let memoryService: DefaultMemoryService?
    private let preCompactionMemoryFlushRunner: any PreCompactionMemoryFlushRunning
    private let reinjectionSkillProvider: any CompactionReinjectionSkillProviding
    private let reinjectionInstructionProvider: any CompactionReinjectionInstructionProviding
    private let systemPromptAssemblyRenderer: (any SystemPromptAssemblyRendering)?
    private let logger: Logger?

    public init(
        compactionCoordinator: CompactionConcurrencyCoordinator? = nil,
        memoryService: DefaultMemoryService? = nil,
        logger: Logger? = nil
    ) {
        self.init(
            compactionCoordinator: compactionCoordinator,
            memoryService: memoryService,
            systemPromptAssemblyRenderer: nil,
            preCompactionMemoryFlushRunner: nil,
            reinjectionSkillProvider: nil,
            reinjectionInstructionProvider: nil,
            logger: logger
        )
    }

    init(
        compactionCoordinator: CompactionConcurrencyCoordinator? = nil,
        memoryService: DefaultMemoryService? = nil,
        systemPromptAssemblyRenderer: (any SystemPromptAssemblyRendering)? = nil,
        preCompactionMemoryFlushRunner: (any PreCompactionMemoryFlushRunning)? = nil,
        reinjectionSkillProvider: (any CompactionReinjectionSkillProviding)? = nil,
        reinjectionInstructionProvider: (any CompactionReinjectionInstructionProviding)? = nil,
        logger: Logger? = nil
    ) {
        self.compactionCoordinator = compactionCoordinator
        self.memoryService = memoryService
        self.systemPromptAssemblyRenderer = systemPromptAssemblyRenderer
        if let preCompactionMemoryFlushRunner {
            self.preCompactionMemoryFlushRunner = preCompactionMemoryFlushRunner
        } else if let memoryService {
            self.preCompactionMemoryFlushRunner = MemoryPreCompactionFlushRunner(memoryService: memoryService, logger: logger)
        } else {
            self.preCompactionMemoryFlushRunner = DefaultPreCompactionMemoryFlushRunner()
        }
        self.reinjectionSkillProvider = reinjectionSkillProvider
            ?? DefaultCompactionReinjectionSkillProvider(logger: logger)
        self.reinjectionInstructionProvider = reinjectionInstructionProvider
            ?? DefaultCompactionReinjectionInstructionProvider()
        self.logger = logger
    }

    public func bootstrap(request: ContextEngineBootstrapRequest) async -> ContextEngineBootstrapResult {
        _ = request
        return ContextEngineBootstrapResult(initialized: true)
    }

    public func ingest(request: ContextEngineIngestRequest) async -> ContextEngineIngestResult {
        _ = request
        return ContextEngineIngestResult(ingestedCount: 1)
    }

    /// Lifecycle hook for non-default `ContextEngine` slots: the pipeline awaits this before every
    /// `assemble` / `compact` so alternate implementations can inject per-turn state without forking
    /// `ContextAssemblyPipeline`. The default slot is a no-op.
    public func ingestBatch(request: ContextEngineIngestBatchRequest) async -> ContextEngineIngestResult {
        _ = request
        return ContextEngineIngestResult(ingestedCount: request.messages.count)
    }

    public func assemble(
        request: ContextEngineAssembleRequest,
        performTransform: @Sendable @escaping (ContextTransformInput) async throws -> ContextTransformOutput
    ) async -> ContextEngineAssembleResult {
        await ensureMemoryBootstrapped(conversation: request.conversation, policy: request.workspacePolicy)
        let memoryStoreVersion = await memoryService?.currentSnapshotGeneration(conversationID: request.conversation.id) ?? 0
        let modeSwitches = ContextSystemPromptModeSwitches.build(
            conversation: request.conversation,
            strictAgentHarnessPrompts: request.projectionPolicy?.systemPromptAssemblyPolicy?.strictAgentHarnessPrompts ?? true,
            resolvedProfile: request.projectionPolicy?.systemPromptAssemblyPolicy?.resolvedModeProfile
                ?? ResolvedModeProfile.syntheticSeed(
                    id: request.conversation.modeProfileID ?? request.conversation.interactionMode.rawValue,
                    interactionMode: request.conversation.interactionMode,
                    assemblyKind: request.conversation.interactionMode.harnessAssemblyKind
                )
        )
        let messagesForAssembly = request.messages
        var memorySnapshot: ContextMemoryInjectionSnapshotSpec?
        let sessionMemoryNote = sessionMemoryNoteForCompaction(
            memoryStoreVersion: memoryStoreVersion,
            config: request.compactionConfig
        )
        let preparedTurnRequest = ContextEngineAssembleRequest(
            messages: messagesForAssembly,
            conversation: request.conversation,
            phase: request.phase,
            gatingOverride: request.gatingOverride,
            compactionCustomInstructionsOverride: request.compactionCustomInstructionsOverride,
            enableContextTransform: request.enableContextTransform,
            compactionConfig: request.compactionConfig,
            transformMetadata: request.transformMetadata,
            lastContextLimitTokens: request.lastContextLimitTokens,
            lastPromptTokens: request.lastPromptTokens,
            events: request.events,
            eventLogFrontier: request.eventLogFrontier,
            lastModelRequestAtByConversationID: request.lastModelRequestAtByConversationID,
            lastCompactionLLMDateByConversationID: request.lastCompactionLLMDateByConversationID,
            persistCompactionCheckpoint: request.persistCompactionCheckpoint,
            allowProactiveCompactionTriggers: request.allowProactiveCompactionTriggers,
            compactionLockAlreadyHeldByCaller: request.compactionLockAlreadyHeldByCaller,
            derivedTailAtProjectionStart: request.derivedTailAtProjectionStart,
            projectionPolicy: request.projectionPolicy,
            preCompactionMemoryFlushPolicy: request.preCompactionMemoryFlushPolicy,
            sessionMemoryNoteForCompaction: request.sessionMemoryNoteForCompaction ?? sessionMemoryNote,
            preCompactionMemoryFlushSpec: request.preCompactionMemoryFlushSpec,
            workspacePolicy: request.workspacePolicy
        )
        let result = await executeTurnAssembly(request: preparedTurnRequest, performTransform: performTransform)
        let ttlPruned = applyCacheTTLPruningIfNeeded(messages: result.messages, request: preparedTurnRequest)
        if ttlPruned.transformationKind == .cacheEditing {
            logger?.debug(
                "[ContextEngine] cache TTL pruning substituted stale tool results conversation=\(request.conversation.id)"
            )
        }
        let selectorConfigFingerprint = await memoryService?.recallSelectorConfigFingerprint() ?? ""
        let tier2Result = await applyTier2MemoryRecallIfNeeded(
            into: ttlPruned.messages,
            conversation: request.conversation,
            phase: request.phase,
            modeMemoryInjection: modeSwitches.memoryInjectionMode,
            resolvedProfile: request.projectionPolicy?.systemPromptAssemblyPolicy?.resolvedModeProfile,
            compactionConfig: request.compactionConfig,
            lastContextLimitTokens: request.lastContextLimitTokens,
            lastPromptTokens: request.lastPromptTokens,
            memoryStoreVersion: memoryStoreVersion,
            tier1MemorySectionContent: Self.tier1ContentForCrossTierDedup(
                memoryTier1: result.projectionArtifact?.systemPromptAssembly?.tier1MemorySectionContent,
                workspace: result.projectionArtifact?.systemPromptAssembly?.workspaceSectionContent
            ),
            rawMessages: request.messages,
            events: request.events,
            eventLogFrontier: request.eventLogFrontier,
            selectorConfigFingerprint: selectorConfigFingerprint
        )
        if tier2Result.injected, memoryStoreVersion > 0 {
            memorySnapshot = ContextMemoryInjectionSnapshotSpec(
                conversationID: request.conversation.id,
                phase: request.phase,
                memoryStoreVersion: memoryStoreVersion,
                memoryStoreNamespaceKey: request.conversation.id.uuidString,
                injectedMemoryEntryIDs: [Self.recallEntryID(generation: memoryStoreVersion)],
                selectedSelectionKeys: tier2Result.selectedSelectionKeys,
                projectedSelectionKeys: tier2Result.projectedMemorySelectionKeys,
                selectionContextMessageIDs: request.messages.map(\.id),
                selectorConfigFingerprint: selectorConfigFingerprint
            )
        }
        return ContextEngineAssembleResult(
            messages: tier2Result.messages,
            transformOutput: result.transformOutput,
            checkpointPersistence: result.checkpointPersistence,
            memoryInjectionSnapshot: memorySnapshot,
            transformFailed: result.transformFailed,
            passthroughReason: result.passthroughReason,
            projectionArtifact: result.projectionArtifact,
            systemPromptCheckpoint: result.systemPromptCheckpoint,
            attachmentProjectionCheckpoint: result.attachmentProjectionCheckpoint,
            attachmentDigestCheckpoints: result.attachmentDigestCheckpoints,
            preCompactionMemoryFlush: result.preCompactionMemoryFlush,
            compactionLowSavings: result.compactionLowSavings,
            projectedMemorySelectionKeys: tier2Result.projectedMemorySelectionKeys,
            cacheExpiredHygieneWindow: result.cacheExpiredHygieneWindow
        )
    }

    public func compact(
        request: ContextEngineCompactRequest,
        performTransform: @Sendable @escaping (ContextTransformInput) async throws -> ContextTransformOutput
    ) async -> ContextEngineCompactResult {
        await assemble(request: request.assemble, performTransform: performTransform)
    }

    public func afterTurn(request: ContextEngineAfterTurnRequest) async -> ContextEngineAfterTurnResult {
        if let memoryService,
           let session = await memoryService.sessionContext(for: request.conversationID) {
            let wrote = await memoryService.writeObserver().hadMainAgentWrites(conversationID: request.conversationID)
            await memoryService.onTurnEnded(
                request: MemoryTurnEndedRequest(
                    session: session,
                    mainAgentWroteMemory: wrote,
                    isMainREPLThread: true,
                    recentMessageCount: request.recentMessages.count,
                    anchorUserMessageID: request.anchorUserMessageID,
                    recentMessages: request.recentMessages
                )
            )
        }
        return ContextEngineAfterTurnResult(completed: true)
    }

    public func prepareSubagentSpawn(
        request: ContextEnginePrepareSubagentSpawnRequest
    ) async -> ContextEnginePrepareSubagentSpawnResult {
        let approved = request.candidateToolNames.filter { toolName in
            let permissionPolicy = request.permissionPolicyByToolName[toolName] ?? .auto
            switch permissionPolicy {
            case .auto:
                return true
            case .askUser, .askParent:
                return ToolNamePolicyNormalization.setContains(request.preApprovedToolNames, name: toolName)
            }
        }
        let approvedSet = Set(approved)
        let elevatedToolNames = request.candidateToolNames.filter { toolName in
            guard approvedSet.contains(toolName) else { return false }
            let trust = request.trustLevelByToolName[toolName] ?? .unknownParty
            return trust != .system
        }
        let handoff = ContextEngineSubagentHandoffArtifact(
            conversationID: request.conversationID,
            runID: request.runID,
            policyFingerprint: subagentPolicyFingerprint(
                conversationID: request.conversationID,
                runID: request.runID,
                toolName: nil,
                approvedToolNames: approved,
                permissionPolicyByToolName: request.permissionPolicyByToolName,
                trustLevelByToolName: request.trustLevelByToolName
            ),
            approvedToolNames: approved,
            elevatedToolNames: elevatedToolNames
        )
        let invalidationKinds = invalidationKindsForPrepare(
            approvedToolNames: approved,
            trustLevelByToolName: request.trustLevelByToolName
        )
        let invalidation = invalidationKinds.isEmpty ? nil : ContextEngineSubagentCheckpointInvalidationSpec(
            conversationID: request.conversationID,
            invalidatedKinds: invalidationKinds
        )
        let compositionArtifact = promptCompositionArtifact(for: request)
        return ContextEnginePrepareSubagentSpawnResult(
            approvedToolNames: approved,
            handoffArtifact: handoff,
            checkpointInvalidation: invalidation,
            promptCompositionArtifact: compositionArtifact
        )
    }

    private func promptCompositionArtifact(
        for request: ContextEnginePrepareSubagentSpawnRequest
    ) -> ContextEngineSubagentPromptCompositionArtifact? {
        guard let mode = request.compositionMode else { return nil }
        switch mode {
        case .fork:
            return ContextEngineSubagentPromptCompositionArtifact(
                mode: .fork,
                inheritedAssembledPromptText: nil,
                inheritedAssembledPromptDigest: nil,
                inheritedReplaySpecDigest: nil,
                spawnSectionSuppressions: nil,
                spawnTaskDirective: nil
            )
        case .spawn:
            let directive = SystemPromptSubagentComposition.spawnTaskDirective(
                taskDescription: request.taskDescription,
                prompt: request.spawnPrompt,
                userSystemPrompt: request.spawnUserSystemPrompt
            )
            return ContextEngineSubagentPromptCompositionArtifact(
                mode: .spawn,
                inheritedAssembledPromptText: nil,
                inheritedAssembledPromptDigest: nil,
                inheritedReplaySpecDigest: nil,
                spawnSectionSuppressions: SystemPromptSubagentComposition.spawnSectionSuppressions,
                spawnTaskDirective: directive
            )
        }
    }

    public func onSubagentEnded(
        request: ContextEngineSubagentEndedRequest
    ) async -> ContextEngineSubagentEndedResult {
        let fingerprint = subagentPolicyFingerprint(
            conversationID: request.conversationID,
            runID: request.runID,
            toolName: request.toolName,
            approvedToolNames: [],
            permissionPolicyByToolName: request.permissionPolicy.map { [request.toolName: $0] } ?? [:],
            trustLevelByToolName: request.trustLevel.map { [request.toolName: $0] } ?? [:]
        )
        let continuity = ContextEngineSubagentContinuationArtifact(
            conversationID: request.conversationID,
            runID: request.runID,
            toolName: request.toolName,
            policyFingerprint: fingerprint
        )
        let invalidationKinds = invalidationKindsForSubagentEnded(trustLevel: request.trustLevel)
        let invalidation = invalidationKinds.isEmpty ? nil : ContextEngineSubagentCheckpointInvalidationSpec(
            conversationID: request.conversationID,
            invalidatedKinds: invalidationKinds
        )
        return ContextEngineSubagentEndedResult(
            acknowledged: true,
            continuationArtifact: continuity,
            checkpointInvalidation: invalidation
        )
    }

    public func projectedContextBudget(
        request: ContextEngineProjectedContextBudgetRequest
    ) async -> ConversationContextBudget? {
        let projected = await applyProjectionPolicy(
            messages: request.messages,
            conversation: request.conversation,
            policy: request.projectionPolicy
        )
        let contextLimit = request.lastContextLimitTokens
            ?? request.conversation.model.maxContextLength
            ?? request.compactionConfig.fallbackContextLimitTokens
        let promptTokens = ContextCompactionPolicy.resolvedTotalPromptTokens(
            messages: projected.messages,
            lastActualPromptTokens: request.lastPromptTokens,
            charactersPerToken: request.compactionConfig.charactersPerToken
        )
        let remaining = max(0, contextLimit - promptTokens)
        let cachePolicy = ContextPruningPolicyResolver.resolve(config: request.compactionConfig)
        let focusQuery = request.compactionConfig.focusedCompactionQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let strategy = ContextCompactionPolicy.resolvedStrategy(
            config: request.compactionConfig,
            branchParentConversationID: request.conversation.parentConversationID,
            explicitFocusQuery: focusQuery.isEmpty ? nil : focusQuery
        )
        return ConversationContextBudget(
            contextLimitTokens: contextLimit,
            promptTokens: promptTokens,
            remainingTokens: remaining,
            cacheStablePrefixMessageCount: nil,
            cachePruningTTLSeconds: cachePolicy.ttlSeconds,
            compactionStrategy: strategy.rawValue
        )
    }

    private func executeTurnAssembly(
        request: ContextTurnAssemblyRequest,
        performTransform: @Sendable @escaping (ContextTransformInput) async throws -> ContextTransformOutput
    ) async -> ContextTurnAssemblyResult {
        let cacheExpiredHygieneWindow = resolveCacheExpiredHygieneWindow(request: request)
        let projected = await applyProjectionPolicy(
            messages: request.messages,
            conversation: request.conversation,
            policy: request.projectionPolicy,
            events: request.events,
            frontierEventID: request.eventLogFrontier
        )
        let policyAdjustedMessages = projected.messages
        let (compactionInjectedPrefix, compactionTranscript) =
            ContextCompactionCheckpointSupport.partitionForCompaction(policyAdjustedMessages)
        let projectionArtifact = projected.artifact
        let promptCheckpoint = projectionArtifact.systemPromptAssembly.map {
            let checkpointConfig: (mode: SystemPromptAssemblyCheckpointMode, maxFullTextBytes: Int)
            if let snapshot = $0.replaySpec?.promptConfigSnapshot {
                checkpointConfig = SystemPromptAssemblyCheckpointConfiguration.load(from: snapshot)
            } else {
                checkpointConfig = SystemPromptAssemblyCheckpointConfiguration.load()
            }
            let sectionJSON = $0.sectionProvenance.flatMap { map -> String? in
                let sectionMap = Dictionary(
                    uniqueKeysWithValues: map.compactMap { key, value -> (SystemPromptSectionName, String)? in
                        guard let section = SystemPromptSectionName(rawValue: key) else { return nil }
                        return (section, value)
                    }
                )
                return SystemPromptSectionProvenanceFormatter.encodeSectionProvenanceJSON(sectionMap)
            }
            var assembledPrompt: String?
            if checkpointConfig.mode == .fullText,
               let text = $0.assembledSystemPromptText,
               text.utf8.count <= checkpointConfig.maxFullTextBytes {
                assembledPrompt = text
            }
            return ContextSystemPromptAssemblyCheckpointPersistenceSpec(
                conversationID: request.conversation.id,
                fingerprint: $0.fingerprint,
                assembledPromptDigest: $0.assembledPromptDigest,
                replaySpecDigest: $0.replaySpecDigest,
                assembledPrompt: assembledPrompt,
                sectionProvenanceJSON: sectionJSON
            )
        }
        let attachmentCheckpoint = projectionArtifact.attachmentProjection.map {
            ContextAttachmentProjectionCheckpointPersistenceSpec(
                conversationID: request.conversation.id,
                projectionFingerprint: $0.projectionFingerprint,
                decisions: $0.decisions,
                targetDecisions: $0.targetDecisions,
                materializedBlocks: $0.materializedBlocks,
                accessWatermarkTurnIndex: $0.accessWatermarkTurnIndex
            )
        }
        let attachmentDigestCheckpoints = projectionArtifact.attachmentProjection.flatMap { artifact -> ContextAttachmentDigestCheckpointPersistenceSpec? in
            guard !artifact.newDigestCheckpoints.isEmpty else { return nil }
            return ContextAttachmentDigestCheckpointPersistenceSpec(
                conversationID: request.conversation.id,
                checkpoints: artifact.newDigestCheckpoints
            )
        }

        guard request.enableContextTransform else {
            return ContextTurnAssemblyResult(
                messages: policyAdjustedMessages,
                transformOutput: Optional<ContextTransformOutput>.none,
                checkpointPersistence: Optional<ContextCompactionCheckpointPersistenceSpec>.none,
                memoryInjectionSnapshot: nil,
                transformFailed: false,
                passthroughReason: "context_transform_disabled",
                projectionArtifact: projectionArtifact,
                systemPromptCheckpoint: promptCheckpoint,
                attachmentProjectionCheckpoint: attachmentCheckpoint,
                attachmentDigestCheckpoints: attachmentDigestCheckpoints,
                preCompactionMemoryFlush: nil,
                cacheExpiredHygieneWindow: cacheExpiredHygieneWindow
            )
        }

        let input: ContextTransformInput
        if case .initial = request.phase {
            let activatedSkillNames = ConversationMetadataActivatedSkills.activatedAgentSkillNames(
                from: request.conversation.metadata
            )
            let reinjectableSkills = await reinjectionSkillProvider.reinjectableSkillContent(
                activatedSkillNames: activatedSkillNames
            )
            let promptCwd = HarnessWorkspaceResolver.resolveForPromptContext(conversation: request.conversation)
            let postCompactionInstructionContext: String?
            if let promptCwd {
                let gitRoot = GitRootResolver.canonicalGitRoot(for: promptCwd)
                postCompactionInstructionContext = await reinjectionInstructionProvider.postCompactionInstructionContext(
                    cwd: promptCwd,
                    canonicalGitRoot: gitRoot,
                    config: request.compactionConfig
                )
            } else {
                postCompactionInstructionContext = nil
            }
            let initial = ContextCompactionInputBuilder.buildInitialPhaseInput(
                messages: compactionTranscript,
                conversation: request.conversation,
                transformMetadata: request.transformMetadata,
                compactionConfig: request.compactionConfig,
                enableContextTransform: true,
                lastContextLimitTokens: request.lastContextLimitTokens,
                lastPromptTokens: request.lastPromptTokens,
                events: request.events,
                eventLogFrontier: request.eventLogFrontier,
                lastCompactionLLMDateByConversationID: request.lastCompactionLLMDateByConversationID,
                gating: request.gatingOverride ?? .production,
                allowProactiveCompactionTriggers: request.allowProactiveCompactionTriggers,
                sessionMemoryNoteForCompaction: request.sessionMemoryNoteForCompaction,
                compactionInjectedPrefix: compactionInjectedPrefix,
                reinjectableSkills: reinjectableSkills,
                postCompactionInstructionContext: postCompactionInstructionContext,
                cacheExpiredHygieneWindow: cacheExpiredHygieneWindow
            )
            switch initial {
            case .passthrough(let reason):
                let softFlush = await softFlushOnlyIfEligible(
                    request: request,
                    compactionTranscript: compactionTranscript,
                    compactionInjectedPrefix: compactionInjectedPrefix,
                    passthroughReason: reason
                )
                return ContextTurnAssemblyResult(
                    messages: policyAdjustedMessages,
                    transformOutput: Optional<ContextTransformOutput>.none,
                    checkpointPersistence: Optional<ContextCompactionCheckpointPersistenceSpec>.none,
                    memoryInjectionSnapshot: nil,
                    transformFailed: false,
                    passthroughReason: reason,
                    projectionArtifact: projectionArtifact,
                    systemPromptCheckpoint: promptCheckpoint,
                    attachmentProjectionCheckpoint: attachmentCheckpoint,
                attachmentDigestCheckpoints: attachmentDigestCheckpoints,
                    preCompactionMemoryFlush: softFlush,
                    cacheExpiredHygieneWindow: cacheExpiredHygieneWindow
                )
            case .transform(let built):
                input = built
            }
        } else {
            input = ContextCompactionInputBuilder.buildNonInitialPhaseInput(
                messages: policyAdjustedMessages,
                conversation: request.conversation,
                transformMetadata: request.transformMetadata,
                phase: request.phase,
                compactionConfig: request.compactionConfig,
                lastContextLimitTokens: request.lastContextLimitTokens
            )
        }

        var acquiredCompactionLock = false
        if compactionCoordinator != nil,
           request.persistCompactionCheckpoint,
           !request.compactionLockAlreadyHeldByCaller,
           case .initial = request.phase,
           let coordinator = compactionCoordinator {
            acquiredCompactionLock = await coordinator.tryAcquire(for: request.conversation.id)
            if !acquiredCompactionLock {
                logger?.debug(
                    "[ContextEngine] Skipping compaction transform; lock held for conversation \(request.conversation.id)"
                )
                return ContextTurnAssemblyResult(
                    messages: policyAdjustedMessages,
                    transformOutput: Optional<ContextTransformOutput>.none,
                    checkpointPersistence: Optional<ContextCompactionCheckpointPersistenceSpec>.none,
                    memoryInjectionSnapshot: nil,
                    transformFailed: false,
                    passthroughReason: "compaction_lock_held",
                    projectionArtifact: projectionArtifact,
                    systemPromptCheckpoint: promptCheckpoint,
                    attachmentProjectionCheckpoint: attachmentCheckpoint,
                attachmentDigestCheckpoints: attachmentDigestCheckpoints,
                    preCompactionMemoryFlush: nil,
                    cacheExpiredHygieneWindow: cacheExpiredHygieneWindow
                )
            }
        }

        let inputWithManualOverride: ContextTransformInput
        if let custom = request.compactionCustomInstructionsOverride {
            inputWithManualOverride = ContextTransformInput(
                messages: input.messages,
                conversation: input.conversation,
                phase: input.phase,
                compactionEffectiveMiddle: input.compactionEffectiveMiddle,
                compactionRawMiddleMessages: input.compactionRawMiddleMessages,
                effectiveContextLimitTokens: input.effectiveContextLimitTokens,
                compactionSummarizerDebugOutputPath: input.compactionSummarizerDebugOutputPath,
                compactionCustomInstructionsOverride: custom,
                compactionCheckpointKind: input.compactionCheckpointKind,
                compactionCheckpointPrefixCount: input.compactionCheckpointPrefixCount,
                compactionModelContextLimitTokens: input.compactionModelContextLimitTokens,
                compactionLastPromptTokens: input.compactionLastPromptTokens,
                compactionStrategy: input.compactionStrategy,
                compactionFocusQuery: input.compactionFocusQuery,
                branchParentConversationID: input.branchParentConversationID,
                compactionCachePolicy: input.compactionCachePolicy,
                compactionDeterministicHygienePolicy: input.compactionDeterministicHygienePolicy,
                compactionIdentifierPreservationPolicy: input.compactionIdentifierPreservationPolicy,
                compactionPreviousSummaryText: input.compactionPreviousSummaryText,
                compactionSessionMemoryNote: input.compactionSessionMemoryNote,
                compactionProviderPreCompressNotes: input.compactionProviderPreCompressNotes,
                compactionSplitBaseMessages: input.compactionSplitBaseMessages,
                compactionInjectedPrefixMessages: input.compactionInjectedPrefixMessages,
                compactionReinjectableSkills: input.compactionReinjectableSkills,
                compactionPostCompactionInstructionContext: input.compactionPostCompactionInstructionContext,
                compactionProtectedToolNames: input.compactionProtectedToolNames
            )
        } else {
            inputWithManualOverride = input
        }

        let (preCompactionMemoryFlush, novelMiddleForProvider) = await runPreCompactionFlushIfEligible(
            request: request,
            compactionTranscript: compactionTranscript,
            skipIfSoftAlreadyFlushed: false
        )

        let providerNotes = novelMiddleForProvider.isEmpty
            ? ""
            : await memoryService?.collectProviderPreCompressNotes(
                messages: novelMiddleForProvider.map(\.content)
            ) ?? ""
        let inputForTransform = inputWithManualOverride.withCompactionProviderPreCompressNotes(
            providerNotes.isEmpty ? nil : providerNotes
        )

        if acquiredCompactionLock, let coordinator = compactionCoordinator {
            let conversationID = request.conversation.id
            let result = await runTransformStep(
                request: request,
                fallbackMessages: policyAdjustedMessages,
                input: inputForTransform,
                projectionArtifact: projectionArtifact,
                systemPromptCheckpoint: promptCheckpoint,
                attachmentProjectionCheckpoint: attachmentCheckpoint,
                attachmentDigestCheckpoints: attachmentDigestCheckpoints,
                performTransform: performTransform,
                preCompactionMemoryFlush: preCompactionMemoryFlush,
                cacheExpiredHygieneWindow: cacheExpiredHygieneWindow
            )
            if result.checkpointPersistence != nil {
                await memoryService?.clearPreCompactionFlushCycle(conversationID: conversationID)
            }
            await coordinator.release(for: conversationID)
            return result
        }

        let result = await runTransformStep(
            request: request,
            fallbackMessages: policyAdjustedMessages,
            input: inputForTransform,
            projectionArtifact: projectionArtifact,
            systemPromptCheckpoint: promptCheckpoint,
            attachmentProjectionCheckpoint: attachmentCheckpoint,
            attachmentDigestCheckpoints: attachmentDigestCheckpoints,
            performTransform: performTransform,
            preCompactionMemoryFlush: preCompactionMemoryFlush,
            cacheExpiredHygieneWindow: cacheExpiredHygieneWindow
        )
        if result.checkpointPersistence != nil {
            await memoryService?.clearPreCompactionFlushCycle(conversationID: request.conversation.id)
        }
        return result
    }

    /// Soft-threshold flush-only path: when under the hard proactive threshold but above soft,
    /// await a silent flush and return uncompacted context (no summarizer).
    private func softFlushOnlyIfEligible(
        request: ContextTurnAssemblyRequest,
        compactionTranscript: [Message],
        compactionInjectedPrefix: [Message],
        passthroughReason: String
    ) async -> ContextPreCompactionMemoryFlushSpec? {
        guard passthroughReason == "context_compaction_noop_under_token_threshold" else { return nil }
        guard request.preCompactionMemoryFlushPolicy?.enabled == true else { return nil }
        guard request.persistCompactionCheckpoint else { return nil }
        guard case .initial = request.phase else { return nil }
        guard request.enableContextTransform, request.compactionConfig.enabled else { return nil }
        guard request.allowProactiveCompactionTriggers else { return nil }
        guard request.compactionConfig.softThresholdTokens > 0 else { return nil }

        let modelLimit = request.lastContextLimitTokens
            ?? request.conversation.model.maxContextLength
            ?? request.compactionConfig.fallbackContextLimitTokens
        let softFires = ContextCompactionPolicy.softProactiveTriggerFires(
            messages: compactionInjectedPrefix + compactionTranscript,
            modelContextLimitTokens: modelLimit,
            lastActualPromptTokens: request.lastPromptTokens,
            config: request.compactionConfig
        )
        guard softFires else { return nil }

        return (await runPreCompactionFlushIfEligible(
            request: request,
            compactionTranscript: compactionTranscript,
            skipIfSoftAlreadyFlushed: true
        )).0
    }

    /// Shared silent flush used by soft flush-only and hard flush-then-transform paths.
    private func runPreCompactionFlushIfEligible(
        request: ContextTurnAssemblyRequest,
        compactionTranscript: [Message],
        skipIfSoftAlreadyFlushed: Bool
    ) async -> (ContextPreCompactionMemoryFlushSpec?, [Message]) {
        guard request.preCompactionMemoryFlushPolicy?.enabled == true,
              request.persistCompactionCheckpoint,
              case .initial = request.phase,
              request.enableContextTransform,
              request.compactionConfig.enabled
        else { return (nil, []) }

        if skipIfSoftAlreadyFlushed,
           await memoryService?.hasCompletedSoftPreCompactionFlush(conversationID: request.conversation.id) == true {
            return (nil, [])
        }

        let memoryStoreVersion = await memoryService?.currentSnapshotGeneration(conversationID: request.conversation.id) ?? 0
        guard memoryStoreVersion > 0 else { return (nil, []) }

        let modelLimit = request.lastContextLimitTokens
            ?? request.conversation.model.maxContextLength
            ?? request.compactionConfig.fallbackContextLimitTokens
        let segments = ContextCompactionCheckpointSupport.splitForCompaction(
            compactionTranscript,
            config: request.compactionConfig,
            modelContextLimitTokens: modelLimit
        )
        let middle = segments.middle
        guard !middle.isEmpty else { return (nil, []) }

        let novelMiddle = await memoryService?.filterPreCompactionFlushMiddle(
            conversationID: request.conversation.id,
            middle: middle
        ) ?? middle
        guard !novelMiddle.isEmpty else {
            logger?.debug(
                "[PreCompactionMemoryFlush] skipped: no novel middle messages conversation=\(request.conversation.id)"
            )
            return (nil, [])
        }

        let fingerprint = PreCompactionFlushMiddleFingerprint.of(messages: novelMiddle)
        if await memoryService?.shouldSkipPreCompactionFlushFingerprint(
            conversationID: request.conversation.id,
            fingerprint: fingerprint
        ) == true {
            logger?.debug(
                "[PreCompactionMemoryFlush] skipped: duplicate middle fingerprint conversation=\(request.conversation.id)"
            )
            return (nil, [])
        }

        let timeoutMs = await memoryService?.preCompactionFlushTimeoutMs() ?? 30_000
        let flushContext = PreCompactionMemoryFlushContext(
            conversationID: request.conversation.id,
            middleMessages: novelMiddle,
            maxFlushedMemoryEntries: request.preCompactionMemoryFlushPolicy?.maxFlushedMemoryEntries ?? 64,
            timeoutMs: timeoutMs
        )
        let flushResult = await preCompactionMemoryFlushRunner.runSilentFlushIfNeeded(
            context: flushContext,
            logger: logger
        )
        guard flushResult.succeeded else { return (nil, novelMiddle) }

        await memoryService?.recordPreCompactionFlushMiddle(
            conversationID: request.conversation.id,
            middle: novelMiddle
        )

        if skipIfSoftAlreadyFlushed {
            await memoryService?.markSoftPreCompactionFlushCompleted(conversationID: request.conversation.id)
        }

        let spec = ContextPreCompactionMemoryFlushSpec(
            conversationID: request.conversation.id,
            phase: request.phase,
            memoryStoreVersion: flushResult.memoryStoreVersion,
            memoryStoreNamespaceKey: request.conversation.id.uuidString,
            flushedMemoryEntryIDs: flushResult.flushedMemoryEntryIDs
        )
        return (spec, novelMiddle)
    }

    private func runTransformStep(
        request: ContextTurnAssemblyRequest,
        fallbackMessages: [Message],
        input: ContextTransformInput,
        projectionArtifact: ContextEngineProjectionArtifact,
        systemPromptCheckpoint: ContextSystemPromptAssemblyCheckpointPersistenceSpec?,
        attachmentProjectionCheckpoint: ContextAttachmentProjectionCheckpointPersistenceSpec?,
        attachmentDigestCheckpoints: ContextAttachmentDigestCheckpointPersistenceSpec?,
        performTransform: @Sendable @escaping (ContextTransformInput) async throws -> ContextTransformOutput,
        preCompactionMemoryFlush: ContextPreCompactionMemoryFlushSpec?,
        cacheExpiredHygieneWindow: Bool
    ) async -> ContextTurnAssemblyResult {
        do {
            let output = try await performTransform(input)
            var persistence: ContextCompactionCheckpointPersistenceSpec?
            var compactionLowSavings = false
            if request.persistCompactionCheckpoint,
               case .initial = request.phase,
               let kind = ContextCompactionCheckpointKind.fromDiagnostic(output.diagnostics) {
                let modelLimit = request.lastContextLimitTokens
                    ?? request.conversation.model.maxContextLength
                    ?? request.compactionConfig.fallbackContextLimitTokens
                let splitBase = input.compactionSplitBaseMessages
                    ?? ContextCompactionCheckpointSupport.transcriptForCompactionCoverage(input.messages)
                let before = ContextCompactionCheckpointSupport.splitForCompaction(
                    splitBase,
                    config: request.compactionConfig,
                    modelContextLimitTokens: modelLimit
                )
                let injectedCount = input.compactionInjectedPrefixMessages?.count ?? 0
                let layoutSlice = ContextCompactionCheckpointSupport.compactedPortionInOutput(
                    output.messages,
                    headCount: injectedCount + before.head.count,
                    tailCount: before.tail.count
                )
                let compactedMiddleRaw: [Message] = {
                    if layoutSlice.isEmpty,
                       let persisted = output.compactionPersistedMiddle,
                       !persisted.isEmpty {
                        return persisted
                    }
                    return layoutSlice
                }()
                let compactedMiddle = ContextCompactionCheckpointSupport.durableCompactedMiddleForPersistence(
                    compactedMiddle: compactedMiddleRaw,
                    messageProvenance: output.messageProvenance
                )
                let durableCompactedMiddle: [Message] = {
                    if compactedMiddle.isEmpty,
                       let persisted = output.compactionPersistedMiddle,
                       !persisted.isEmpty {
                        return persisted
                    }
                    return compactedMiddle
                }()
                if durableCompactedMiddle.isEmpty {
                    logger?.warning(
                        "[ContextEngine] compaction diagnostic=\(kind) but middle slice empty conversation=\(request.conversation.id)"
                    )
                } else {
                    let cpt = request.compactionConfig.charactersPerToken
                    let tokensBefore = ContextCompactionPolicy.estimatedTotalPromptTokens(
                        messages: input.messages,
                        charactersPerToken: cpt
                    )
                    let tokensAfter = ContextCompactionPolicy.estimatedTotalPromptTokens(
                        messages: output.messages,
                        charactersPerToken: cpt
                    )
                    if ContextCompactionCheckpointSupport.meetsPromptTokenSavingsThreshold(
                        tokensBefore: tokensBefore,
                        tokensAfter: tokensAfter,
                        config: request.compactionConfig
                    ) {
                        let passesSizeGuards = ContextCompactionCheckpointSupport.compactionCheckpointPersistencePassesSizeGuards(
                            compactedMiddle: durableCompactedMiddle,
                            config: request.compactionConfig,
                            previousSummaryText: input.compactionPreviousSummaryText,
                            kind: kind
                        )
                        if passesSizeGuards {
                            let summaryBody = durableCompactedMiddle.first?.content
                            persistence = ContextCompactionCheckpointPersistenceSpec(
                                conversationID: request.conversation.id,
                                rawMiddleMessageIDs: before.middle.map(\Message.id),
                                compactedMiddleMessages: durableCompactedMiddle,
                                coveredRawMiddle: before.middle,
                                kind: kind,
                                config: request.compactionConfig,
                                strategyRawValue: input.compactionStrategy.rawValue,
                                cachePolicyFingerprint: contextPruningPolicyFingerprint(
                                    for: ContextPruningPolicyResolver.resolve(config: request.compactionConfig)
                                ),
                                expectedDerivedSequence: request.derivedTailAtProjectionStart,
                                firstKeptTailMessageID: before.tail.first?.id,
                                summaryBodyForTranscript: summaryBody,
                                promptTokensBeforeCompaction: request.lastPromptTokens
                            )
                        } else {
                            compactionLowSavings = true
                            logger?.warning(
                                "[ContextEngine] skipping compaction checkpoint: compacted middle exceeds size or growth guards conversation=\(request.conversation.id)"
                            )
                        }
                    } else {
                        compactionLowSavings = true
                        logger?.info(
                            "[ContextEngine] skipping compaction checkpoint: savings \(tokensBefore - tokensAfter) below threshold conversation=\(request.conversation.id)"
                        )
                    }
                }
            }
            return ContextTurnAssemblyResult(
                messages: output.messages,
                transformOutput: output,
                checkpointPersistence: persistence,
                memoryInjectionSnapshot: nil,
                transformFailed: false,
                passthroughReason: nil,
                projectionArtifact: projectionArtifact,
                systemPromptCheckpoint: systemPromptCheckpoint,
                attachmentProjectionCheckpoint: attachmentProjectionCheckpoint,
                attachmentDigestCheckpoints: attachmentDigestCheckpoints,
                preCompactionMemoryFlush: preCompactionMemoryFlush,
                compactionLowSavings: compactionLowSavings,
                cacheExpiredHygieneWindow: cacheExpiredHygieneWindow
            )
        } catch {
            return ContextTurnAssemblyResult(
                messages: fallbackMessages,
                transformOutput: Optional<ContextTransformOutput>.none,
                checkpointPersistence: Optional<ContextCompactionCheckpointPersistenceSpec>.none,
                memoryInjectionSnapshot: nil,
                transformFailed: true,
                passthroughReason: nil,
                projectionArtifact: projectionArtifact,
                systemPromptCheckpoint: systemPromptCheckpoint,
                attachmentProjectionCheckpoint: attachmentProjectionCheckpoint,
                attachmentDigestCheckpoints: attachmentDigestCheckpoints,
                preCompactionMemoryFlush: preCompactionMemoryFlush,
                cacheExpiredHygieneWindow: cacheExpiredHygieneWindow
            )
        }
    }

    private func sessionMemoryNoteForCompaction(
        memoryStoreVersion: Int,
        config: ContextCompactionConfiguration
    ) -> String? {
        guard config.sessionMemorySwapBeforeCompactionEnabled, memoryStoreVersion > 0 else { return nil }
        return """
[Session Memory Note]
Durable memory snapshot generation \(memoryStoreVersion) is active for this session.
"""
    }

    private static func recallEntryID(generation: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-9000-%012x", generation)) ?? UUID()
    }

    private func ensureMemoryBootstrapped(conversation: ModelConversation, policy: HarnessWorkspacePolicy) async {
        guard let memoryService else { return }
        let generation = await memoryService.currentSnapshotGeneration(conversationID: conversation.id)
        guard generation == 0 else { return }
        let cwd: String
        if let recorded = HarnessWorkspaceResolver.recordedCwd(on: conversation) {
            cwd = recorded
        } else if policy.allowAmbientWorkspaceFallback,
                  let ambient = HarnessWorkspaceResolver.ambientIfKnown() {
            cwd = ambient
        } else {
            return
        }
        do {
            let context = try memoryService.makeSessionContext(
                conversationID: conversation.id,
                cwd: cwd,
                ownerAccountID: conversation.ownerAccountID
            )
            _ = try await memoryService.bootstrapSession(context: context)
        } catch {
            logger?.error("[ContextEngine] memory bootstrap failed conversation=\(conversation.id): \(error)")
        }
    }

    private struct Tier2RecallApplicationResult: Sendable {
        let messages: [Message]
        let injected: Bool
        let selectedSelectionKeys: [String]
        let projectedMemorySelectionKeys: [String]

        static func unchanged(_ messages: [Message]) -> Self {
            Tier2RecallApplicationResult(
                messages: messages,
                injected: false,
                selectedSelectionKeys: [],
                projectedMemorySelectionKeys: []
            )
        }
    }

    @discardableResult
    private func applyTier2MemoryRecallIfNeeded(
        into baseMessages: [Message],
        conversation: ModelConversation,
        phase: ContextTransformInvocationPhase,
        modeMemoryInjection: String,
        resolvedProfile: ResolvedModeProfile?,
        compactionConfig: ContextCompactionConfiguration,
        lastContextLimitTokens: Int?,
        lastPromptTokens: Int?,
        memoryStoreVersion: Int,
        tier1MemorySectionContent: String?,
        rawMessages: [Message],
        events: [CachedConversationEvent],
        eventLogFrontier: Int,
        selectorConfigFingerprint: String
    ) async -> Tier2RecallApplicationResult {
        guard case .initial = phase else {
            return .unchanged(baseMessages)
        }
        switch modeMemoryInjection {
        case "off":
            return .unchanged(baseMessages)
        case "skills-only":
            let includeSkills = resolvedProfile?.context.includeSkills ?? true
            guard includeSkills else {
                return .unchanged(baseMessages)
            }
        default:
            break
        }
        guard let memoryService else {
            return .unchanged(baseMessages)
        }
        guard let query = latestUserQuery(from: baseMessages),
              let session = await memoryService.sessionContext(for: conversation.id) else {
            return .unchanged(baseMessages)
        }
        let recall: MemoryRecallResult?
        if let cached = await recallFromInjectionSnapshotIfValid(
            memoryService: memoryService,
            session: session,
            rawMessages: rawMessages,
            events: events,
            eventLogFrontier: eventLogFrontier,
            memoryStoreVersion: memoryStoreVersion,
            selectorConfigFingerprint: selectorConfigFingerprint
        ) {
            recall = cached
        } else {
            recall = try? await memoryService.recallForTurn(
                request: MemoryRecallRequest(
                    session: session,
                    userQuery: query,
                    manifestEntries: await memoryService.manifestEntries(conversationID: conversation.id),
                    activeToolNames: MemoryRecallSelectionPolicy.activeToolNames(from: baseMessages)
                )
            )
        }
        guard let recall, !recall.hits.isEmpty else {
            return .unchanged(baseMessages)
        }
        let selectedKeys = recall.selectedFilenames
        let alreadyProjected = MemoryCrossTierDedupPolicy.bodyProjectedSelectionKeys(fromTier1Content: tier1MemorySectionContent)
        let dedupedHits = MemoryCrossTierDedupPolicy.filterTier2Hits(recall.hits, excluding: alreadyProjected)
        guard !dedupedHits.isEmpty else {
            return .unchanged(baseMessages)
        }
        let modelLimit = lastContextLimitTokens
            ?? conversation.model.maxContextLength
            ?? compactionConfig.fallbackContextLimitTokens
        let recallEntryID = Self.recallEntryID(generation: max(memoryStoreVersion, 1))
        let budgetedHits = MemoryRecallInjectionPolicy.hitsFittingCompactionGuard(
            hits: dedupedHits,
            baseMessages: baseMessages,
            recallEntryID: recallEntryID,
            modelLimit: modelLimit,
            lastPromptTokens: lastPromptTokens,
            config: compactionConfig
        )
        guard let recallMessage = MemoryRecallInjectionPolicy.makeRecallMessage(
            hits: budgetedHits,
            entryID: recallEntryID
        ) else {
            return .unchanged(baseMessages)
        }
        let projectedKeys = Array(MemoryCrossTierDedupPolicy.bodyProjectedSelectionKeys(fromTier2Hits: budgetedHits)).sorted()
        let withRecall = MemoryRecallInjectionPolicy.insertLateRecall(recallMessage, into: baseMessages)
        return Tier2RecallApplicationResult(
            messages: withRecall,
            injected: true,
            selectedSelectionKeys: selectedKeys,
            projectedMemorySelectionKeys: projectedKeys
        )
    }

    private func recallFromInjectionSnapshotIfValid(
        memoryService: DefaultMemoryService,
        session: MemorySessionContext,
        rawMessages: [Message],
        events: [CachedConversationEvent],
        eventLogFrontier: Int,
        memoryStoreVersion: Int,
        selectorConfigFingerprint: String
    ) async -> MemoryRecallResult? {
        let rawIDs = rawMessages.map(\.id)
        guard !selectorConfigFingerprint.isEmpty else { return nil }
        guard let latest = SuiteCheckpointSupport.latestValidMemoryInjectionSnapshot(
            events: events,
            frontierEventID: eventLogFrontier,
            rawMessageIDs: rawIDs,
            expectedMemoryStoreVersion: memoryStoreVersion,
            expectedSelectorConfigFingerprint: selectorConfigFingerprint
        ) else { return nil }
        guard MemoryInjectionSnapshotProjectionPolicy.isProjectionCacheHit(
            wire: latest.wire,
            currentRawMessageIDs: rawIDs,
            expectedMemoryStoreVersion: memoryStoreVersion,
            expectedSelectorConfigFingerprint: selectorConfigFingerprint
        ) else { return nil }
        guard let keys = MemoryInjectionSnapshotProjectionPolicy.cachedSelectedSelectionKeys(from: latest.wire) else {
            return nil
        }
        return try? await memoryService.recallHits(selectionKeys: keys, session: session)
    }

    private func latestUserQuery(from messages: [Message]) -> String? {
        guard let content = messages.last(where: { $0.role == .user })?.content,
              !content.isEmpty else { return nil }
        return content
    }

    private func applyCacheTTLPruningIfNeeded(
        messages: [Message],
        request: ContextEngineAssembleRequest
    ) -> (messages: [Message], transformationKind: CacheProjectionTransformationKind) {
        guard let policy = request.projectionPolicy?.contextPruningPolicy else {
            return (messages, .cacheNeutral)
        }
        return ContextCacheTTLPruning.applyIfNeeded(
            messages: messages,
            policy: policy,
            lastLLMDate: request.lastModelRequestAtByConversationID[request.conversation.id],
            referenceInstant: ContextCacheTTLPruning.deterministicReferenceInstant(from: request.messages),
            toolCallResolutionContext: request.messages
        )
    }

    private func resolveCacheExpiredHygieneWindow(request: ContextEngineAssembleRequest) -> Bool {
        guard request.persistCompactionCheckpoint else { return false }
        guard let policy = request.projectionPolicy?.contextPruningPolicy,
              policy.mode == .cacheTTL
        else { return false }
        let eligibility: ProviderCacheTTLEligibility = .short
        guard let threshold = CacheExpiryInference.resolvedThresholdSeconds(
            config: request.compactionConfig,
            providerEligibility: eligibility
        ) else { return false }
        let referenceInstant = ContextCacheTTLPruning.deterministicReferenceInstant(from: request.messages)
        let lastModelRequestAt = request.lastModelRequestAtByConversationID[request.conversation.id]
        let expired = CacheExpiryInference.isCacheExpired(
            lastModelRequestAt: lastModelRequestAt,
            referenceInstant: referenceInstant,
            providerEligibility: eligibility,
            thresholdSeconds: threshold
        )
        if expired, let lastModelRequestAt {
            let gap = referenceInstant.timeIntervalSince(lastModelRequestAt)
            logger?.info(
                "[ContextEngine] cache expired; hygiene window conversation=\(request.conversation.id) gap=\(Int(gap))s threshold=\(Int(threshold))s"
            )
        }
        return expired
    }

    private func contextPruningPolicyFingerprint(for policy: ContextPruningPolicy) -> String? {
        guard policy.mode != .off else { return nil }
        return [
            policy.mode.rawValue,
            policy.ttlSeconds.map { String(describing: $0) } ?? "",
            String(policy.keepRecentToolResults),
            policy.targetTools?.sorted().joined(separator: ",") ?? ""
        ].joined(separator: "|")
    }

    private func applyProjectionPolicy(
        messages: [Message],
        conversation: ModelConversation,
        policy: ContextEngineProjectionPolicyInput?,
        events: [CachedConversationEvent] = [],
        frontierEventID: Int? = nil
    ) async -> (messages: [Message], artifact: ContextEngineProjectionArtifact) {
        guard let policy else {
            return (
                messages,
                ContextEngineProjectionArtifact(
                    resolvedRequestTrustClass: nil,
                    systemPromptAssembly: nil,
                    attachmentProjection: nil
                )
            )
        }
        let resolvedTrust = MessageInputTrustCodec.safePolicyClass(
            raw: policy.requestInputTrustRaw,
            unknownFallback: policy.safeDefaultTrustClass
        )
        var projected = messages
        if policy.useSessionTreeProjection,
           let entries = policy.sessionTranscriptEntries,
           !entries.isEmpty {
            projected = SessionTranscriptContextProjector.projectMessages(
                entries: entries,
                fallbackMessages: projected
            )
            // Transcript replay is ref-only; restore bytes before attachment projection.
            projected = SessionBlobMessageHydration.hydrateBlobImages(
                in: projected,
                blobReader: policy.attachmentBlobReader,
                conversationID: conversation.id
            )
        }
        if policy.downgradeLowTrustContext, resolvedTrust == .lowTrust, let lastID = projected.last?.id {
            projected = projected.filter { message in
                guard message.role == .user, message.id != lastID else { return true }
                let klass = MessageInputTrustCodec.safePolicyClass(
                    raw: message.inputTrustRaw,
                    unknownFallback: policy.safeDefaultTrustClass
                )
                return klass != .lowTrust
            }
        }
        projected = ContextEngineAttachmentProjectionPolicyHelper.applyingDeterministicHygiene(
            messages: projected,
            policy: policy.deterministicAttachmentHygiene
        )
        let attachmentArtifact = ContextEngineAttachmentProjectionPolicyHelper.resolveAttachmentProjectionArtifact(
            catalog: policy.attachmentCatalog,
            modelSupportsVision: policy.modelSupportsVision,
            policy: policy.attachmentProjectionPolicy,
            blobReader: policy.attachmentBlobReader,
            conversationID: conversation.id,
            messages: projected,
            priorAttachmentProjection: policy.priorAttachmentProjection,
            pendingCacheBreakEvents: policy.pendingCacheBreakEvents,
            events: events,
            frontierEventID: frontierEventID
        )
        if let attachmentArtifact {
            let sanitizationPolicy = policy.attachmentProjectionPolicy.map {
                CatalogVisionImageProjector.SanitizationPolicy(from: $0)
            } ?? .default
            projected = CatalogVisionImageProjector.apply(
                messages: projected,
                catalog: policy.attachmentCatalog,
                effectiveDecisions: attachmentArtifact.decisions,
                blobReader: policy.attachmentBlobReader,
                conversationID: conversation.id,
                modelSupportsVision: policy.modelSupportsVision ?? false,
                sanitizationPolicy: sanitizationPolicy,
                logger: logger
            )
        }
        let attachmentSectionContent = attachmentArtifact.flatMap {
            AttachmentRepresentationMaterializer.attachmentsSectionBody(blocks: $0.materializedBlocks)
        }
        let promptArtifact = if let assemblyPolicy = policy.systemPromptAssemblyPolicy {
            await buildSystemPromptAssemblyArtifact(
                conversation: conversation,
                policy: assemblyPolicy,
                projectedMessages: projected,
                modeMemoryInjection: ContextSystemPromptModeSwitches.build(
                    conversation: conversation,
                    strictAgentHarnessPrompts: assemblyPolicy.strictAgentHarnessPrompts,
                    resolvedProfile: assemblyPolicy.resolvedModeProfile
                ).memoryInjectionMode,
                resolvedProfile: assemblyPolicy.resolvedModeProfile,
                attachmentSectionContent: attachmentSectionContent
            )
        } else {
            nil as ContextEngineSystemPromptAssemblyArtifact?
        }
        if let assembledText = promptArtifact?.assembledSystemPromptText {
            projected = SystemPromptAssemblyApplicator.apply(assembledText: assembledText, to: projected)
        }
        return (
            projected,
            ContextEngineProjectionArtifact(
                resolvedRequestTrustClass: resolvedTrust,
                systemPromptAssembly: promptArtifact,
                attachmentProjection: attachmentArtifact
            )
        )
    }

    private func buildSystemPromptAssemblyArtifact(
        conversation: ModelConversation,
        policy: ContextEngineSystemPromptAssemblyPolicyInput,
        projectedMessages: [Message],
        modeMemoryInjection: String,
        resolvedProfile: ResolvedModeProfile?,
        attachmentSectionContent: String? = nil
    ) async -> ContextEngineSystemPromptAssemblyArtifact {
        if ConversationMetadataSubagentPromptComposition.promptCompositionMode(from: conversation.metadata) == .fork,
           let inheritedText = ConversationMetadataSubagentPromptComposition.inheritedAssembledPromptText(
               from: conversation.metadata
           ) {
            let expectedDigest = ConversationMetadataSubagentPromptComposition.inheritedParentPromptDigest(
                from: conversation.metadata
            )
            let actualDigest = SystemPromptDispatchCodec.sha256Digest(of: inheritedText)
            if let expectedDigest, expectedDigest != actualDigest {
                logger?.warning(
                    "[DefaultContextEngine] fork inherited prompt digest mismatch for conversation \(conversation.id)"
                )
            }
            var dispatchMetadata: [String: String] = [:]
            dispatchMetadata[SystemPromptAssemblyMetadataKeys.assembledPromptDigest] = actualDigest
            if let replayDigest = ConversationMetadataSubagentPromptComposition.inheritedReplaySpecDigest(
                from: conversation.metadata
            ) {
                dispatchMetadata[SystemPromptAssemblyMetadataKeys.replaySpecDigest] = replayDigest
            }
            dispatchMetadata[SystemPromptAssemblyMetadataKeys.assembleReferenceDateISO] =
                SystemPrompt.assembleReferenceDateISOString(from: Date())
            return ContextEngineSystemPromptAssemblyArtifact(
                metadata: dispatchMetadata,
                fingerprint: "fork-inherited",
                tier1MemorySectionContent: nil,
                workspaceSectionContent: nil,
                memorySnapshotGeneration: nil,
                assembledSystemPromptText: inheritedText,
                assembledPromptDigest: actualDigest,
                replaySpec: nil,
                replaySpecDigest: ConversationMetadataSubagentPromptComposition.inheritedReplaySpecDigest(
                    from: conversation.metadata
                ),
                sectionProvenance: nil,
                frozenSkillsIndexXML: ConversationMetadataFrozenSkillsIndex.frozenSkillsIndexXML(
                    from: conversation.metadata
                )
            )
        }
        let referenceDate = Date()
        let memoryBlocks = await loadMemoryBlocks(
            conversation: conversation,
            modeMemoryInjection: modeMemoryInjection,
            resolvedProfile: resolvedProfile
        )
        let userSystemPrompt = SystemPromptAssemblyApplicator.userSystemPrompt(from: projectedMessages)
        let bundle = SystemPromptAssemblyContributionCollector.collect(
            conversation: conversation,
            policy: policy,
            userSystemPrompt: userSystemPrompt,
            memoryBlocks: memoryBlocks?.blocks,
            memorySnapshotGeneration: memoryBlocks?.generation,
            modeMemoryInjection: modeMemoryInjection,
            engineDynamicAddition: nil,
            attachmentSectionContent: attachmentSectionContent,
            referenceDate: referenceDate
        )

        let fingerprint = SystemPromptAssemblyFingerprint.hexDigest(
            resolved: policy.resolvedModeProfile,
            strictAgentHarnessPrompts: policy.strictAgentHarnessPrompts,
            includeAgentSkills: policy.includeAgentSkills,
            includeDateTime: policy.includeDateTime,
            toolPolicySignature: policy.toolPolicySignature,
            routingPolicyTools: policy.routingPolicyTools,
            routingPolicySkills: policy.routingPolicySkills,
            memorySnapshotGeneration: bundle.memorySlice.snapshotGeneration,
            workspaceSectionContent: bundle.memorySlice.workspaceContent,
            memoryTier1SectionContent: bundle.memorySlice.tier1Content,
            providerContributionSignature: bundle.providerContributionSignature,
            systemPromptFullOverride: conversation.systemPromptFullOverride
        )
        let assembleReferenceDateISO = SystemPrompt.assembleReferenceDateISOString(from: referenceDate)
        var renderContext = bundle.assemblyContext
        if policy.includeAgentSkills {
            renderContext.frozenSkillsIndexXML = ConversationMetadataFrozenSkillsIndex.frozenSkillsIndexXML(
                from: conversation.metadata
            )
        }
        var assembledSystemPromptText: String?
        var renderAudit: SystemPromptAssemblyRenderAudit?
        if let renderer = systemPromptAssemblyRenderer {
            do {
                renderAudit = try await renderer.renderWithAudit(
                    conversation: conversation,
                    policy: policy,
                    userSystemPrompt: userSystemPrompt,
                    assemblyContext: renderContext,
                    contributions: bundle.contributions,
                    referenceDate: referenceDate,
                    fullOverrideText: bundle.fullOverrideText
                )
                assembledSystemPromptText = renderAudit?.text
            } catch {
                logger?.warning("[DefaultContextEngine] system prompt assembly render failed: \(error)")
            }
        }
        let assembledPromptDigest = assembledSystemPromptText.map { SystemPromptDispatchCodec.sha256Digest(of: $0) }
        let replaySpec = renderAudit.map {
            SystemPromptAssemblyReplayer.buildReplaySpec(
                assemblyFingerprint: fingerprint,
                assembleReferenceDateISO: assembleReferenceDateISO,
                audit: $0,
                contributions: bundle.contributions,
                policy: policy
            )
        }
        let replaySpecDigest = replaySpec?.replaySpecDigest
        let sectionProvenance = renderAudit.map {
            SystemPromptSectionProvenanceFormatter.stringSectionProvenanceMap(from: $0.product)
        }
        var dispatchMetadata: [String: String] = [:]
        dispatchMetadata[SystemPromptAssemblyMetadataKeys.assembleReferenceDateISO] = assembleReferenceDateISO
        if let assembledPromptDigest {
            dispatchMetadata[SystemPromptAssemblyMetadataKeys.assembledPromptDigest] = assembledPromptDigest
        }
        if let replaySpecDigest {
            dispatchMetadata[SystemPromptAssemblyMetadataKeys.replaySpecDigest] = replaySpecDigest
        }
        if let json = SystemPromptSectionProvenanceFormatter.encodeSectionProvenanceJSON(
            renderAudit?.product.sectionProvenance ?? [:]
        ) {
            dispatchMetadata[SystemPromptAssemblyMetadataKeys.sectionProvenanceJSON] = json
        }
        if let generation = bundle.memorySlice.snapshotGeneration {
            dispatchMetadata[SystemPromptAssemblyMetadataKeys.memorySnapshotGeneration] = String(generation)
        }
        if conversation.systemPromptFullOverride {
            dispatchMetadata[SystemPromptAssemblyMetadataKeys.systemPromptFullOverrideActive] = "true"
        }
        if let stablePrefix = renderAudit?.providerStablePrefix?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stablePrefix.isEmpty {
            dispatchMetadata[SystemPromptAssemblyMetadataKeys.providerStablePrefix] = stablePrefix
        }
        return ContextEngineSystemPromptAssemblyArtifact(
            metadata: dispatchMetadata,
            fingerprint: fingerprint,
            tier1MemorySectionContent: bundle.memorySlice.tier1Content,
            workspaceSectionContent: bundle.memorySlice.workspaceContent,
            memorySnapshotGeneration: bundle.memorySlice.snapshotGeneration,
            assembledSystemPromptText: assembledSystemPromptText,
            assembledPromptDigest: assembledPromptDigest,
            replaySpec: replaySpec,
            replaySpecDigest: replaySpecDigest,
            sectionProvenance: sectionProvenance,
            frozenSkillsIndexXML: renderAudit?.product.frozenSkillsIndexXML
        )
    }

    private static func tier1ContentForCrossTierDedup(memoryTier1: String?, workspace: String?) -> String? {
        let parts = [workspace, memoryTier1]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }

    private struct LoadedMemoryBlocks: Sendable {
        let blocks: MemorySystemPromptBlocks
        let generation: Int?
    }

    private func loadMemoryBlocks(
        conversation: ModelConversation,
        modeMemoryInjection: String,
        resolvedProfile: ResolvedModeProfile?
    ) async -> LoadedMemoryBlocks? {
        switch modeMemoryInjection {
        case "off":
            return nil
        case "skills-only":
            let includeSkills = resolvedProfile?.context.includeSkills ?? true
            guard includeSkills else { return nil }
        default:
            break
        }
        guard let memoryService else { return nil }
        if let frozen = ConversationMetadataFrozenMemoryTier1.frozenSlice(from: conversation.metadata) {
            return LoadedMemoryBlocks(
                blocks: ConversationMetadataFrozenMemoryTier1.memorySystemPromptBlocks(from: frozen),
                generation: frozen.snapshotGeneration
            )
        }
        guard let blocks = await memoryService.systemPromptBlocks(conversationID: conversation.id) else {
            return nil
        }
        let hasContent = !blocks.workspaceInstructionSection.isEmpty || !blocks.memoryTier1Content.isEmpty
        guard hasContent else { return nil }
        let generation = await memoryService.currentSnapshotGeneration(conversationID: conversation.id)
        return LoadedMemoryBlocks(blocks: blocks, generation: generation)
    }

    private struct Tier1MemorySectionContent: Sendable {
        let content: String?
        let generation: Int?
    }

    private func tier1MemorySectionContent(
        conversation: ModelConversation,
        modeMemoryInjection: String,
        resolvedProfile: ResolvedModeProfile?
    ) async -> Tier1MemorySectionContent {
        switch modeMemoryInjection {
        case "off":
            return Tier1MemorySectionContent(content: nil, generation: nil)
        case "skills-only":
            let includeSkills = resolvedProfile?.context.includeSkills ?? true
            guard includeSkills else {
                return Tier1MemorySectionContent(content: nil, generation: nil)
            }
        default:
            break
        }
        guard let memoryService else {
            return Tier1MemorySectionContent(content: nil, generation: nil)
        }
        if let frozen = ConversationMetadataFrozenMemoryTier1.frozenSlice(from: conversation.metadata) {
            let tier1 = frozen.tier1Content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tier1.isEmpty else {
                return Tier1MemorySectionContent(content: nil, generation: frozen.snapshotGeneration)
            }
            return Tier1MemorySectionContent(content: tier1, generation: frozen.snapshotGeneration)
        }
        guard let blocks = await memoryService.systemPromptBlocks(conversationID: conversation.id) else {
            return Tier1MemorySectionContent(content: nil, generation: nil)
        }
        let memoryOnly = blocks.memoryTier1Content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !memoryOnly.isEmpty else {
            return Tier1MemorySectionContent(content: nil, generation: nil)
        }
        return Tier1MemorySectionContent(content: memoryOnly, generation: blocks.snapshotGeneration)
    }


    private func invalidationKindsForPrepare(
        approvedToolNames: [String],
        trustLevelByToolName: [String: SubAgentTrustLevel]
    ) -> [String] {
        let hasElevatedTrustDelegation = approvedToolNames.contains { toolName in
            let trust = trustLevelByToolName[toolName] ?? .unknownParty
            return trust != .system
        }
        guard hasElevatedTrustDelegation else { return [] }
        return [
            HarnessCheckpointInvalidationKind.systemPromptAssembly,
            HarnessCheckpointInvalidationKind.attachmentProjection,
        ]
    }

    private func invalidationKindsForSubagentEnded(trustLevel: SubAgentTrustLevel?) -> [String] {
        var kinds: [String] = [HarnessCheckpointInvalidationKind.memoryInjectionSnapshot]
        if let trustLevel, trustLevel != .system {
            kinds.append(HarnessCheckpointInvalidationKind.attachmentProjection)
        }
        return Array(Set(kinds)).sorted()
    }

    private func subagentPolicyFingerprint(
        conversationID: UUID,
        runID: UUID?,
        toolName: String?,
        approvedToolNames: [String],
        permissionPolicyByToolName: [String: SubAgentPermissionPolicy],
        trustLevelByToolName: [String: SubAgentTrustLevel]
    ) -> String {
        let approved = approvedToolNames.sorted().joined(separator: ",")
        let permissionPairs = permissionPolicyByToolName
            .map { "\($0.key.lowercased())=\($0.value.rawValue)" }
            .sorted()
            .joined(separator: ",")
        let trustPairs = trustLevelByToolName
            .map { "\($0.key.lowercased())=\($0.value.rawValue)" }
            .sorted()
            .joined(separator: ",")
        let material = [
            "v1",
            conversationID.uuidString,
            runID?.uuidString ?? "",
            toolName?.lowercased() ?? "",
            approved,
            permissionPairs,
            trustPairs,
        ].joined(separator: "|")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
