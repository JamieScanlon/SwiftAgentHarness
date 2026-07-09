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
            logger: logger
        )
    }

    init(
        compactionCoordinator: CompactionConcurrencyCoordinator? = nil,
        memoryService: DefaultMemoryService? = nil,
        preCompactionMemoryFlushRunner: (any PreCompactionMemoryFlushRunning)? = nil,
        reinjectionSkillProvider: (any CompactionReinjectionSkillProviding)? = nil,
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
        let messagesWithMemory = await injectingMemoryLayerMessages(
            into: request.messages,
            conversation: request.conversation,
            phase: request.phase,
            modeMemoryInjection: modeSwitches.memoryInjectionMode,
            resolvedProfile: request.projectionPolicy?.systemPromptAssemblyPolicy?.resolvedModeProfile
        )
        let memorySnapshot = memoryStoreVersion > 0 ? ContextMemoryInjectionSnapshotSpec(
            conversationID: request.conversation.id,
            phase: request.phase,
            memoryStoreVersion: memoryStoreVersion,
            memoryStoreNamespaceKey: request.conversation.id.uuidString,
            injectedMemoryEntryIDs: [Self.snapshotEntryID(generation: memoryStoreVersion)]
        ) : nil
        let sessionMemoryNote = sessionMemoryNoteForCompaction(
            memoryStoreVersion: memoryStoreVersion,
            config: request.compactionConfig
        )
        let preparedTurnRequest = ContextEngineAssembleRequest(
            messages: messagesWithMemory,
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
        return ContextEngineAssembleResult(
            messages: result.messages,
            transformOutput: result.transformOutput,
            checkpointPersistence: result.checkpointPersistence,
            memoryInjectionSnapshot: memorySnapshot,
            transformFailed: result.transformFailed,
            passthroughReason: result.passthroughReason,
            projectionArtifact: result.projectionArtifact,
            systemPromptCheckpoint: result.systemPromptCheckpoint,
            attachmentProjectionCheckpoint: result.attachmentProjectionCheckpoint,
            preCompactionMemoryFlush: result.preCompactionMemoryFlush,
            compactionLowSavings: result.compactionLowSavings
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
        let projected = applyProjectionPolicy(
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
        let projected = applyProjectionPolicy(
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
                fingerprint: $0.fingerprint
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
                reinjectableSkills: reinjectableSkills
            )
            switch initial {
            case .passthrough(let reason):
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
                    preCompactionMemoryFlush: nil
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
                compactionSplitBaseMessages: input.compactionSplitBaseMessages,
                compactionInjectedPrefixMessages: input.compactionInjectedPrefixMessages
            )
        } else {
            inputWithManualOverride = input
        }

        var preCompactionMemoryFlush: ContextPreCompactionMemoryFlushSpec?
        if request.preCompactionMemoryFlushPolicy?.enabled == true,
           request.persistCompactionCheckpoint,
           case .initial = request.phase,
           request.enableContextTransform,
           request.compactionConfig.enabled {
            let memoryStoreVersion = await memoryService?.currentSnapshotGeneration(conversationID: request.conversation.id) ?? 0
            if memoryStoreVersion > 0 {
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
                if !middle.isEmpty {
                    let timeoutMs = await memoryService?.preCompactionFlushTimeoutMs() ?? 30_000
                    let flushContext = PreCompactionMemoryFlushContext(
                        conversationID: request.conversation.id,
                        middleMessages: middle,
                        maxFlushedMemoryEntries: request.preCompactionMemoryFlushPolicy?.maxFlushedMemoryEntries ?? 64,
                        timeoutMs: timeoutMs
                    )
                    let flushResult = await preCompactionMemoryFlushRunner.runSilentFlushIfNeeded(
                        context: flushContext,
                        logger: logger
                    )
                    if flushResult.succeeded {
                        preCompactionMemoryFlush = ContextPreCompactionMemoryFlushSpec(
                            conversationID: request.conversation.id,
                            phase: request.phase,
                            memoryStoreVersion: flushResult.memoryStoreVersion,
                            memoryStoreNamespaceKey: request.conversation.id.uuidString,
                            flushedMemoryEntryIDs: flushResult.flushedMemoryEntryIDs
                        )
                    }
                }
            }
        }

        if acquiredCompactionLock, let coordinator = compactionCoordinator {
            let conversationID = request.conversation.id
            let result = await runTransformStep(
                request: request,
                fallbackMessages: policyAdjustedMessages,
                input: inputWithManualOverride,
                projectionArtifact: projectionArtifact,
                systemPromptCheckpoint: promptCheckpoint,
                attachmentProjectionCheckpoint: attachmentCheckpoint,
                performTransform: performTransform,
                preCompactionMemoryFlush: preCompactionMemoryFlush
            )
            await coordinator.release(for: conversationID)
            return result
        }

        return await runTransformStep(
            request: request,
            fallbackMessages: policyAdjustedMessages,
            input: inputWithManualOverride,
            projectionArtifact: projectionArtifact,
            systemPromptCheckpoint: promptCheckpoint,
            attachmentProjectionCheckpoint: attachmentCheckpoint,
            performTransform: performTransform,
            preCompactionMemoryFlush: preCompactionMemoryFlush
        )
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

    private static func snapshotEntryID(generation: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", generation)) ?? UUID()
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

    private func injectingMemoryLayerMessages(
        into baseMessages: [Message],
        conversation: ModelConversation,
        phase: ContextTransformInvocationPhase,
        modeMemoryInjection: String,
        resolvedProfile: ResolvedModeProfile?
    ) async -> [Message] {
        switch modeMemoryInjection {
        case "off":
            return baseMessages
        case "skills-only":
            let includeSkills = resolvedProfile?.context.includeSkills ?? true
            guard includeSkills else { return baseMessages }
        default:
            break
        }
        guard let memoryService else { return baseMessages }
        guard let blocks = await memoryService.systemPromptBlocks(conversationID: conversation.id) else {
            return baseMessages
        }
        var recalledText = ""
        if case .initial = phase,
           let query = latestUserQuery(from: baseMessages),
           let session = await memoryService.sessionContext(for: conversation.id),
           let recall = try? await memoryService.recallForTurn(
               request: MemoryRecallRequest(
                   session: session,
                   userQuery: query,
                   manifestEntries: await memoryService.manifestEntries(conversationID: conversation.id)
               )
           ),
           !recall.recalledBodiesText.isEmpty {
            recalledText = recall.recalledBodiesText
        }
        let stable = blocks.stableSystemPromptSection
        guard !stable.isEmpty || !recalledText.isEmpty else { return baseMessages }
        var injected: [Message] = []
        if !stable.isEmpty {
            injected.append(HarnessInjectedMessageMetadata.systemMessage(
                id: Self.snapshotEntryID(generation: blocks.snapshotGeneration),
                content: """
\(HarnessInjectedMessagePrefixes.memoryContext)
\(stable)
"""
            ))
        }
        if !recalledText.isEmpty {
            injected.append(HarnessInjectedMessageMetadata.systemMessage(
                id: Self.recallEntryID(generation: blocks.snapshotGeneration),
                content: """
\(HarnessInjectedMessagePrefixes.memoryRecall)
\(recalledText)
"""
            ))
        }
        return injected + baseMessages
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
    ) -> (messages: [Message], artifact: ContextEngineProjectionArtifact) {
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
        let promptArtifact = policy.systemPromptAssemblyPolicy.map {
            buildSystemPromptAssemblyArtifact(
                conversation: conversation,
                policy: $0
            )
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
        policy: ContextEngineSystemPromptAssemblyPolicyInput
    ) -> ContextEngineSystemPromptAssemblyArtifact {
        let metadata = ContextSystemPromptModeSwitches.build(
            conversation: conversation,
            strictAgentHarnessPrompts: policy.strictAgentHarnessPrompts,
            resolvedProfile: policy.resolvedModeProfile
        ).metadata
        let fingerprint = SystemPromptAssemblyFingerprint.hexDigest(
            resolved: policy.resolvedModeProfile,
            strictAgentHarnessPrompts: policy.strictAgentHarnessPrompts,
            includeAgentSkills: policy.includeAgentSkills,
            includeDateTime: policy.includeDateTime,
            toolPolicySignature: policy.toolPolicySignature,
            routingPolicyTools: policy.routingPolicyTools,
            routingPolicySkills: policy.routingPolicySkills
        )
        return ContextEngineSystemPromptAssemblyArtifact(metadata: metadata, fingerprint: fingerprint)
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
