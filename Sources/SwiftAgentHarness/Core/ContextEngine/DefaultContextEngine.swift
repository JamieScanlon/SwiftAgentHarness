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
    private let logger: Logger?

    public init(
        compactionCoordinator: CompactionConcurrencyCoordinator? = nil,
        memoryService: DefaultMemoryService? = nil,
        logger: Logger? = nil
    ) {
        self.init(
            compactionCoordinator: compactionCoordinator,
            memoryService: memoryService,
            preCompactionMemoryFlushRunner: nil,
            reinjectionSkillProvider: nil,
            reinjectionInstructionProvider: nil,
            logger: logger
        )
    }

    init(
        compactionCoordinator: CompactionConcurrencyCoordinator? = nil,
        memoryService: DefaultMemoryService? = nil,
        preCompactionMemoryFlushRunner: (any PreCompactionMemoryFlushRunning)? = nil,
        reinjectionSkillProvider: (any CompactionReinjectionSkillProviding)? = nil,
        reinjectionInstructionProvider: (any CompactionReinjectionInstructionProviding)? = nil,
        logger: Logger? = nil
    ) {
        self.compactionCoordinator = compactionCoordinator
        self.memoryService = memoryService
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
        await ensureMemoryBootstrapped(conversation: request.conversation)
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
            lastLLMDateByConversationID: request.lastLLMDateByConversationID,
            persistCompactionCheckpoint: request.persistCompactionCheckpoint,
            allowProactiveCompactionTriggers: request.allowProactiveCompactionTriggers,
            compactionLockAlreadyHeldByCaller: request.compactionLockAlreadyHeldByCaller,
            derivedTailAtProjectionStart: request.derivedTailAtProjectionStart,
            projectionPolicy: request.projectionPolicy,
            preCompactionMemoryFlushPolicy: request.preCompactionMemoryFlushPolicy,
            sessionMemoryNoteForCompaction: request.sessionMemoryNoteForCompaction ?? sessionMemoryNote,
            preCompactionMemoryFlushSpec: request.preCompactionMemoryFlushSpec
        )
        let result = await executeTurnAssembly(request: preparedTurnRequest, performTransform: performTransform)
        let tier2Result = await applyTier2MemoryRecallIfNeeded(
            into: result.messages,
            conversation: request.conversation,
            phase: request.phase,
            modeMemoryInjection: modeSwitches.memoryInjectionMode,
            resolvedProfile: request.projectionPolicy?.systemPromptAssemblyPolicy?.resolvedModeProfile,
            compactionConfig: request.compactionConfig,
            lastContextLimitTokens: request.lastContextLimitTokens,
            lastPromptTokens: request.lastPromptTokens,
            memoryStoreVersion: memoryStoreVersion,
            tier1MemorySectionContent: result.projectionArtifact?.systemPromptAssembly?.tier1MemorySectionContent
        )
        if tier2Result.injected, memoryStoreVersion > 0 {
            memorySnapshot = ContextMemoryInjectionSnapshotSpec(
                conversationID: request.conversation.id,
                phase: request.phase,
                memoryStoreVersion: memoryStoreVersion,
                memoryStoreNamespaceKey: request.conversation.id.uuidString,
                injectedMemoryEntryIDs: [Self.recallEntryID(generation: memoryStoreVersion)],
                projectedSelectionKeys: tier2Result.projectedMemorySelectionKeys
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
            preCompactionMemoryFlush: result.preCompactionMemoryFlush,
            compactionLowSavings: result.compactionLowSavings,
            projectedMemorySelectionKeys: tier2Result.projectedMemorySelectionKeys
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
        return ContextEnginePrepareSubagentSpawnResult(
            approvedToolNames: approved,
            handoffArtifact: handoff,
            checkpointInvalidation: invalidation
        )
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
        let cachePolicy = ContextCompactionPolicy.resolvedCachePolicy(config: request.compactionConfig)
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
            cacheStablePrefixMessageCount: cachePolicy.enabled ? cachePolicy.stablePrefixMessageCount : nil,
            cachePruningTTLSeconds: cachePolicy.ttlSeconds.map { Double($0) },
            compactionStrategy: strategy.rawValue
        )
    }

    private func executeTurnAssembly(
        request: ContextTurnAssemblyRequest,
        performTransform: @Sendable @escaping (ContextTransformInput) async throws -> ContextTransformOutput
    ) async -> ContextTurnAssemblyResult {
        let projected = await applyProjectionPolicy(
            messages: request.messages,
            conversation: request.conversation,
            policy: request.projectionPolicy
        )
        let policyAdjustedMessages = projected.messages
        let (compactionInjectedPrefix, compactionTranscript) =
            ContextCompactionCheckpointSupport.partitionForCompaction(policyAdjustedMessages)
        let projectionArtifact = projected.artifact
        let promptCheckpoint = projectionArtifact.systemPromptAssembly.map {
            ContextSystemPromptAssemblyCheckpointPersistenceSpec(
                conversationID: request.conversation.id,
                fingerprint: $0.fingerprint,
                assembledPromptDigest: nil
            )
        }
        let attachmentCheckpoint = projectionArtifact.attachmentProjection.map {
            ContextAttachmentProjectionCheckpointPersistenceSpec(
                conversationID: request.conversation.id,
                projectionFingerprint: $0.projectionFingerprint,
                decisions: $0.decisions
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
                preCompactionMemoryFlush: nil
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
            let cwd = request.conversation.harnessPersistenceCwd ?? FileManager.default.currentDirectoryPath
            let gitRoot = GitRootResolver.canonicalGitRoot(for: cwd)
            let postCompactionInstructionContext = await reinjectionInstructionProvider.postCompactionInstructionContext(
                cwd: cwd,
                canonicalGitRoot: gitRoot,
                config: request.compactionConfig
            )
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
                lastLLMDateByConversationID: request.lastLLMDateByConversationID,
                gating: request.gatingOverride ?? .production,
                allowProactiveCompactionTriggers: request.allowProactiveCompactionTriggers,
                sessionMemoryNoteForCompaction: request.sessionMemoryNoteForCompaction,
                compactionInjectedPrefix: compactionInjectedPrefix,
                reinjectableSkills: reinjectableSkills,
                postCompactionInstructionContext: postCompactionInstructionContext
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
                    preCompactionMemoryFlush: softFlush
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
                    preCompactionMemoryFlush: nil
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
                performTransform: performTransform,
                preCompactionMemoryFlush: preCompactionMemoryFlush
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
            performTransform: performTransform,
            preCompactionMemoryFlush: preCompactionMemoryFlush
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
        if segments.lastUserPinSkipped, !segments.middle.isEmpty {
            logger?.debug(
                "[ContextEngine] last-user pin skipped (outside tail window) conversation=\(request.conversation.id)"
            )
        }
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
        performTransform: @Sendable @escaping (ContextTransformInput) async throws -> ContextTransformOutput,
        preCompactionMemoryFlush: ContextPreCompactionMemoryFlushSpec?
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
                                cachePolicyFingerprint: cachePolicyFingerprint(for: input.compactionCachePolicy),
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
                preCompactionMemoryFlush: preCompactionMemoryFlush,
                compactionLowSavings: compactionLowSavings
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
                preCompactionMemoryFlush: preCompactionMemoryFlush
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

    private func ensureMemoryBootstrapped(conversation: ModelConversation) async {
        guard let memoryService else { return }
        let generation = await memoryService.currentSnapshotGeneration(conversationID: conversation.id)
        guard generation == 0 else { return }
        let cwd = conversation.harnessPersistenceCwd ?? FileManager.default.currentDirectoryPath
        do {
            let context = try memoryService.makeSessionContext(conversationID: conversation.id, cwd: cwd)
            _ = try await memoryService.bootstrapSession(context: context)
        } catch {
            logger?.error("[ContextEngine] memory bootstrap failed conversation=\(conversation.id): \(error)")
        }
    }

    private struct Tier2RecallApplicationResult: Sendable {
        let messages: [Message]
        let injected: Bool
        let projectedMemorySelectionKeys: [String]
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
        tier1MemorySectionContent: String?
    ) async -> Tier2RecallApplicationResult {
        guard case .initial = phase else {
            return Tier2RecallApplicationResult(messages: baseMessages, injected: false, projectedMemorySelectionKeys: [])
        }
        switch modeMemoryInjection {
        case "off":
            return Tier2RecallApplicationResult(messages: baseMessages, injected: false, projectedMemorySelectionKeys: [])
        case "skills-only":
            let includeSkills = resolvedProfile?.context.includeSkills ?? true
            guard includeSkills else {
                return Tier2RecallApplicationResult(messages: baseMessages, injected: false, projectedMemorySelectionKeys: [])
            }
        default:
            break
        }
        guard let memoryService else {
            return Tier2RecallApplicationResult(messages: baseMessages, injected: false, projectedMemorySelectionKeys: [])
        }
        guard let query = latestUserQuery(from: baseMessages),
              let session = await memoryService.sessionContext(for: conversation.id),
              let recall = try? await memoryService.recallForTurn(
                  request: MemoryRecallRequest(
                      session: session,
                      userQuery: query,
                      manifestEntries: await memoryService.manifestEntries(conversationID: conversation.id)
                  )
              ),
              !recall.hits.isEmpty else {
            return Tier2RecallApplicationResult(messages: baseMessages, injected: false, projectedMemorySelectionKeys: [])
        }
        let alreadyProjected = MemoryCrossTierDedupPolicy.bodyProjectedSelectionKeys(fromTier1Content: tier1MemorySectionContent)
        let dedupedHits = MemoryCrossTierDedupPolicy.filterTier2Hits(recall.hits, excluding: alreadyProjected)
        guard !dedupedHits.isEmpty else {
            return Tier2RecallApplicationResult(messages: baseMessages, injected: false, projectedMemorySelectionKeys: [])
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
            return Tier2RecallApplicationResult(messages: baseMessages, injected: false, projectedMemorySelectionKeys: [])
        }
        let projectedKeys = Array(MemoryCrossTierDedupPolicy.bodyProjectedSelectionKeys(fromTier2Hits: budgetedHits)).sorted()
        let withRecall = MemoryRecallInjectionPolicy.insertLateRecall(recallMessage, into: baseMessages)
        return Tier2RecallApplicationResult(
            messages: withRecall,
            injected: true,
            projectedMemorySelectionKeys: projectedKeys
        )
    }

    private func latestUserQuery(from messages: [Message]) -> String? {
        guard let content = messages.last(where: { $0.role == .user })?.content,
              !content.isEmpty else { return nil }
        return content
    }

    private func cachePolicyFingerprint(for policy: ContextCompactionCachePolicy?) -> String? {
        guard let policy else { return nil }
        return [
            policy.enabled ? "1" : "0",
            String(policy.stablePrefixMessageCount),
            policy.ttlSeconds.map { String(describing: $0) } ?? ""
        ].joined(separator: "|")
    }

    private func applyProjectionPolicy(
        messages: [Message],
        conversation: ModelConversation,
        policy: ContextEngineProjectionPolicyInput?
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
        let promptArtifact = if let assemblyPolicy = policy.systemPromptAssemblyPolicy {
            await buildSystemPromptAssemblyArtifact(
                conversation: conversation,
                policy: assemblyPolicy,
                modeMemoryInjection: ContextSystemPromptModeSwitches.build(
                    conversation: conversation,
                    strictAgentHarnessPrompts: assemblyPolicy.strictAgentHarnessPrompts,
                    resolvedProfile: assemblyPolicy.resolvedModeProfile
                ).memoryInjectionMode,
                resolvedProfile: assemblyPolicy.resolvedModeProfile
            )
        } else {
            nil as ContextEngineSystemPromptAssemblyArtifact?
        }
        let attachmentArtifact = ContextEngineAttachmentProjectionPolicyHelper.resolveAttachmentProjection(
            catalog: policy.attachmentCatalog,
            modelSupportsVision: policy.modelSupportsVision,
            policy: policy.attachmentProjectionPolicy
        )
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
        modeMemoryInjection: String,
        resolvedProfile: ResolvedModeProfile?
    ) async -> ContextEngineSystemPromptAssemblyArtifact {
        let metadata = ContextSystemPromptModeSwitches.build(
            conversation: conversation,
            strictAgentHarnessPrompts: policy.strictAgentHarnessPrompts,
            resolvedProfile: policy.resolvedModeProfile
        ).metadata
        let tier1 = await tier1MemorySectionContent(
            conversation: conversation,
            modeMemoryInjection: modeMemoryInjection,
            resolvedProfile: resolvedProfile
        )
        let fingerprint = SystemPromptAssemblyFingerprint.hexDigest(
            resolved: policy.resolvedModeProfile,
            strictAgentHarnessPrompts: policy.strictAgentHarnessPrompts,
            includeAgentSkills: policy.includeAgentSkills,
            includeDateTime: policy.includeDateTime,
            toolPolicySignature: policy.toolPolicySignature,
            routingPolicyTools: policy.routingPolicyTools,
            routingPolicySkills: policy.routingPolicySkills,
            memorySnapshotGeneration: tier1.generation,
            tier1MemorySectionContent: tier1.content
        )
        return ContextEngineSystemPromptAssemblyArtifact(
            metadata: metadata,
            fingerprint: fingerprint,
            tier1MemorySectionContent: tier1.content,
            memorySnapshotGeneration: tier1.generation
        )
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
        guard let blocks = await memoryService.systemPromptBlocks(conversationID: conversation.id) else {
            return Tier1MemorySectionContent(content: nil, generation: nil)
        }
        let stable = blocks.stableSystemPromptSection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stable.isEmpty else {
            return Tier1MemorySectionContent(content: nil, generation: nil)
        }
        return Tier1MemorySectionContent(content: stable, generation: blocks.snapshotGeneration)
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
