import EasyJSON
import Foundation
import Logging
import SwiftAgentKit
import SwiftAgentKitOrchestrator
import SwiftAgentKitSkills

/// Orchestrator-facing session seam: mode policy, context recovery, listener lifecycle, and port surface.
public actor OrchestratorSessionRuntimeService {
    private enum ModeTransitionHookID {
        static let invalidateOrchestrator = "invalidate_orchestrator"
        static let restoreSkillLoader = "restore_skill_loader"
    }

    private let deps: ConversationRuntimeDependencies
    private let persistenceDomain: ConversationPersistenceDomain
    private let selection: ConversationSelectionAccessing
    private let sessionProjection: SessionProjectionAccessing
    private let messaging: ConversationMessagingPort
    private let topics: ConversationTopicPublicationPort
    private let agentRuntime: AgentRuntimeSessionService
    private let orchestratorRuntime: OrchestratorRuntimeService
    private let skillActivation: SkillActivationService
    private let spawn: SubAgentSpawnService
    private let subAgentCompletion: SubAgentCompletionRuntimeService
    private let subAgentPool: any SubAgentPooling
    private let slashCommand: SlashCommandDispatchService
    private let toolData: ConversationToolDataService
    private let toolSystemGateway: any ToolSystemGatewaying
    private var triggerDelegatedCompletionHandoff: TriggerDelegatedCompletionHandoff?

    init(
        deps: ConversationRuntimeDependencies,
        persistenceDomain: ConversationPersistenceDomain,
        selection: ConversationSelectionAccessing,
        sessionProjection: SessionProjectionAccessing,
        messaging: ConversationMessagingPort,
        topics: ConversationTopicPublicationPort,
        agentRuntime: AgentRuntimeSessionService,
        orchestratorRuntime: OrchestratorRuntimeService,
        skillActivation: SkillActivationService,
        spawn: SubAgentSpawnService,
        subAgentCompletion: SubAgentCompletionRuntimeService,
        subAgentPool: any SubAgentPooling,
        slashCommand: SlashCommandDispatchService,
        toolData: ConversationToolDataService
    ) {
        self.deps = deps
        self.persistenceDomain = persistenceDomain
        self.selection = selection
        self.sessionProjection = sessionProjection
        self.messaging = messaging
        self.topics = topics
        self.agentRuntime = agentRuntime
        self.orchestratorRuntime = orchestratorRuntime
        self.skillActivation = skillActivation
        self.spawn = spawn
        self.subAgentCompletion = subAgentCompletion
        self.subAgentPool = subAgentPool
        self.slashCommand = slashCommand
        self.toolData = toolData
        self.toolSystemGateway = DefaultToolSystemGateway(visibilityGrants: deps.visibilityGrants)
    }

    private var logger: Logger? { deps.logger }

    public func installTriggerDelegatedCompletionHandoff(_ handoff: TriggerDelegatedCompletionHandoff) {
        triggerDelegatedCompletionHandoff = handoff
    }

    func currentConversation() async -> ModelConversation? {
        await selection.currentConversation()
    }

    func makeModePolicyContext(for conversation: ModelConversation) async -> ModePolicyContext {
        ModePolicyContext(conversation: conversation, resolvedProfile: await makeResolvedModeProfile(for: conversation))
    }

    func makeResolvedModeProfile(for conversation: ModelConversation) async -> ResolvedModeProfile {
        (await deps.modeRegistry.resolveReportingFallback(
            modeId: conversation.modeProfileID ?? conversation.interactionMode.rawValue,
            logger: logger,
            fallbackModeId: InteractionMode.chat.rawValue
        )).profile
    }

    func makeDefaultSessionModePolicyContext() async -> ModePolicyContext {
        let resolved = try! await deps.modeRegistry.resolve(modeId: InteractionMode.chat.rawValue)
        return ModePolicyContext(interactionMode: .chat, resolvedProfile: resolved)
    }

    func makeSystemPromptMetadata(
        for conversation: ModelConversation?,
        resolvedProfile: ResolvedModeProfile
    ) -> [String: String] {
        _ = conversation
        _ = resolvedProfile
        return [:]
    }

    func makeResolvedThinkingConfig(
        for conversation: ModelConversation,
        callContext: ThinkingCallContext
    ) async -> ThinkingConfig {
        let resolvedProfile = await makeResolvedModeProfile(for: conversation)
        let conversationOverride = conversation.routingPrefs?.modelOptions?.thinkingConfig
        return ThinkingConfigResolver.resolve(
            settingsDefault: deps.thinkingPolicyConfiguration.defaultThinkingConfig,
            modeThinkingConfig: resolvedProfile.model.thinkingConfig,
            conversationThinkingConfig: conversationOverride,
            thinkingBudgets: deps.thinkingPolicyConfiguration.thinkingBudgets,
            callContext: callContext
        )
    }

    func setupOrchestrator(with model: Model, activeConversation: ModelConversation?) async {
        await orchestratorRuntime.setupOrchestrator(with: model, activeConversation: activeConversation)
    }

    func invalidateOrchestrator(for conversationID: UUID? = nil) async {
        await orchestratorRuntime.invalidateOrchestrator(for: conversationID)
    }

    func invalidateOrchestrator() async {
        await invalidateOrchestrator(for: nil)
    }

    func persistActivatedSkillsFromLoader(conversationID: UUID) async {
        await skillActivation.persistActivatedSkillsFromLoader(conversationID: conversationID)
    }

    func persistActivatedSkillsFromLoaderToCurrentConversation() async {
        guard let cid = await selection.currentConversationID() else { return }
        await skillActivation.persistActivatedSkillsFromLoader(conversationID: cid)
    }

    func runtimeToolResultMiddlewarePipeline() async -> ToolResultMiddlewarePipeline {
        await messaging.runtimeToolResultMiddlewarePipeline()
    }

    func installTurnToolRegistryEntries(_ entries: [ToolRegistryEntry]) async {
        await messaging.installTurnToolRegistryEntries(entries)
    }

    func registerAgentToolResultMiddleware(_ middleware: AgentToolResultMiddleware) async {
        await messaging.registerAgentToolResultMiddleware(middleware)
    }

    func recordContextSnapshot(from response: LLMResponse, requestConfig: LLMRequestConfig) async {
        await agentRuntime.recordContextSnapshot(from: response, requestConfig: requestConfig)
    }

    func snapshotOrchestrationState(for conversationID: UUID) async -> ConversationOrchestrationState? {
        await agentRuntime.snapshotOrchestrationState(for: conversationID)
    }

    func startOrchestratorStateListeners(for conversationID: UUID) async {
        await agentRuntime.cancelAgenticOrchestrationSnapshotListeners(for: conversationID)
        guard let orchestrator = await agentRuntime.orchestrator(for: conversationID) else {
            await spawn.stopCompletionHandoffOwner()
            return
        }
        await agentRuntime.installAgenticOrchestrationSnapshotListeners(on: self, conversationID: conversationID)
        await spawn.startCompletionHandoffOwner(
            orchestrator: orchestrator,
            resolveConversationID: { [subAgentCompletion] toolCallID, handleID in
                await subAgentCompletion.resolvePendingCompletionConversationID(
                    toolCallID: toolCallID,
                    handleID: handleID
                )
            },
            onCompletion: { [self] event in
                await self.ingestSubAgentPendingCompletionEvent(event)
            }
        )
    }

    func applySubagentCheckpointInvalidationIfNeeded(_ spec: ContextEngineSubagentCheckpointInvalidationSpec?) async {
        guard let spec else { return }
        let kinds = Array(Set(spec.invalidatedKinds)).sorted()
        guard !kinds.isEmpty else { return }
        do {
            try await persistenceDomain.routingAppendCheckpointInvalidationAsync(
                conversationID: spec.conversationID,
                kinds: kinds
            )
            await topics.publishCheckpointInvalidationOnTopic(
                conversationID: spec.conversationID,
                invalidatedKinds: kinds
            )
        } catch {
            logger?.warning("[OrchestratorSessionRuntimeService] sub-agent checkpoint invalidation persistence failed: \(error)")
        }
    }

    func isHaltingToolCallForRuntime(toolName: String, effectiveEntries: [ToolRegistryEntry]) -> Bool {
        toolSystemGateway.isHaltingToolCall(toolName: toolName, effectiveEntries: effectiveEntries)
    }

    func generateFullSystemPrompt(conversationID: UUID?, withUserSystemPrompt userSystemPrompt: String?) async throws -> String {
        let conv: ModelConversation?
        if let conversationID {
            conv = await persistenceDomain.modelConversation(id: conversationID)
        } else {
            conv = nil
        }
        let interactionMode = conv?.interactionMode ?? .chat
        let resolved = if let conv {
            await makeResolvedModeProfile(for: conv)
        } else {
            (await deps.modeRegistry.resolveReportingFallback(
                modeId: InteractionMode.chat.rawValue,
                logger: logger,
                fallbackModeId: InteractionMode.chat.rawValue
            )).profile
        }
        guard let conv else {
            let modeCtx = ModePolicyContext(interactionMode: interactionMode, resolvedProfile: resolved)
            let skillLoader = await skillActivation.skillLoader(for: conversationID)
            let referenceDate = Date()
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime]
            let context = SystemPromptAssemblyContext(
                conversationID: "preview",
                conversationStartDate: isoFormatter.string(from: referenceDate),
                referenceDate: referenceDate,
                userSystemPrompt: userSystemPrompt ?? ""
            )
            let systemPrompt = try await SystemPrompt(
                skillLoader: skillLoader,
                logger: logger,
                interactionMode: interactionMode,
                assemblyKind: resolved.assemblyKind,
                routingPolicyConversation: nil,
                modePolicyContext: modeCtx
            )
            return try await systemPrompt.generateSystemPrompt(
                context: context,
                resolved: ResolvedSystemPromptSections(),
                stablePrefix: nil
            )
        }

        var providerContribution: SystemPromptContribution?
        if let entry = await deps.registryEntryProvider?(conv.model.id),
           let binding = entry.primaryBinding,
           let wire = ProviderRuntimeHooks.systemPromptContribution(binding: binding) {
            providerContribution = ProviderPromptContribution.systemPromptContribution(from: wire)
        }
        let routingNames = ConversationRoutingPolicyNames.names(for: conv)
        let policy = ContextEngineSystemPromptAssemblyPolicyInput(
            resolvedModeProfile: resolved,
            strictAgentHarnessPrompts: deps.agentHarness.strictAgentHarnessPrompts,
            includeAgentSkills: resolved.context.includeSkills ?? deps.configurationSet.promptAssembly.includeAgentSkills,
            includeDateTime: deps.configurationSet.promptAssembly.includeCurrentDateTime,
            toolPolicySignature: deps.toolPolicy.stableAllowlistSignature(),
            routingPolicyTools: routingNames.tools,
            routingPolicySkills: routingNames.skills,
            providerContribution: providerContribution
        )
        let referenceDate = Date()
        let memoryBlocks: MemorySystemPromptBlocks?
        let memoryGeneration: Int?
        if let defaultEngine = deps.contextEngine as? DefaultContextEngine,
           let memoryService = defaultEngine.memoryService,
           let blocks = await memoryService.systemPromptBlocks(conversationID: conv.id) {
            memoryBlocks = blocks
            memoryGeneration = await memoryService.currentSnapshotGeneration(conversationID: conv.id)
        } else {
            memoryBlocks = nil
            memoryGeneration = nil
        }
        let modeMemoryInjection = ContextSystemPromptModeSwitches.build(
            conversation: conv,
            strictAgentHarnessPrompts: policy.strictAgentHarnessPrompts,
            resolvedProfile: policy.resolvedModeProfile,
            referenceDate: referenceDate
        ).memoryInjectionMode
        let bundle = SystemPromptAssemblyContributionCollector.collect(
            conversation: conv,
            policy: policy,
            userSystemPrompt: userSystemPrompt,
            memoryBlocks: memoryBlocks,
            memorySnapshotGeneration: memoryGeneration,
            modeMemoryInjection: modeMemoryInjection,
            engineDynamicAddition: nil,
            referenceDate: referenceDate
        )

        let renderer = DefaultSystemPromptAssemblyRenderer(
            skillLoaderProvider: { [skillActivation] conversationID in
                await skillActivation.skillLoader(for: conversationID)
            },
            logger: logger
        )
        let text = try await renderer.render(
            conversation: conv,
            policy: policy,
            userSystemPrompt: userSystemPrompt,
            assemblyContext: bundle.assemblyContext,
            contributions: bundle.contributions,
            referenceDate: referenceDate,
            fullOverrideText: bundle.fullOverrideText
        )
        do {
            let fingerprint = SystemPromptAssemblyFingerprint.hexDigest(
                resolved: resolved,
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
                systemPromptFullOverride: conv.systemPromptFullOverride
            )
            try await persistenceDomain.persistSystemPromptAssemblyCheckpointIfNeededAsync(
                conversationID: conv.id,
                fingerprint: fingerprint,
                assembledPromptDigest: SystemPromptDispatchCodec.sha256Digest(of: text)
            )
        } catch {
            logger?.warning("[OrchestratorSessionRuntimeService] system prompt assembly checkpoint (generateFullSystemPrompt): \(error)")
        }
        return text
    }

    func adoptPersistedNewConversationSelection(_ conversation: ModelConversation) async throws {
        let conversationID = conversation.id
        let journalMessages = try await persistenceDomain.messagesNeedingTranscriptMessageAppendedJournal(
            conversationID: conversationID,
            messages: conversation.messages
        )
        if !journalMessages.isEmpty {
            try await persistenceDomain.routingAppendMessageJournalEntriesAsync(
                conversationID: conversationID,
                messages: journalMessages
            )
        }
        await sessionProjection.syncFromRegistry(conversationID: conversationID, conversation: conversation)
        try await selection.selectConversation(conversationID: conversationID)
    }

    func runTransitionHookIDs(_ hookIDs: [String], context: ModeTransitionContext) async throws {
        for hookID in hookIDs {
            try await runTransitionHook(id: hookID, context: context)
        }
    }

    func rollbackMetadataTransition(
        conversationID: UUID,
        prior: ModelConversation,
        transitionContext: ModeTransitionContext,
        didPersistTransitionState: Bool,
        didRunExitHooks: Bool,
        didRunEnterHooks: Bool
    ) async {
        guard didPersistTransitionState else { return }
        do {
            _ = try await persistenceDomain.updateConversationMetadata(
                conversationID: conversationID,
                topic: prior.topic,
                description: prior.description,
                metadata: prior.metadata,
                interactionMode: prior.interactionMode,
                modeProfileID: prior.modeProfileID,
                skipControlPlaneRevisionBump: true
            )
        } catch {
            logger?.error("[OrchestratorSessionRuntimeService] Mode transition rollback persistence failed: \(error)")
            return
        }

        guard didRunExitHooks else { return }
        if didRunEnterHooks {
            try? await runTransitionHookIDs(transitionContext.toProfile.hooks.onExit, context: transitionContext)
        }
        try? await runTransitionHookIDs(transitionContext.fromProfile.hooks.onEnter, context: transitionContext)
    }

    func listSubAgentRegistryEntriesForAPI(conversationID: UUID) async throws -> [SubAgentRegistryEntry] {
        guard let conversation = await persistenceDomain.modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        let modeSubAgentAllowList = (await makeResolvedModeProfile(for: conversation)).subAgents.allow
        let preFetched = await apiRegistryEntriesForListing(preferredConversation: conversation)
        let entries = await subAgentPool.refreshSubAgentCatalog(conversationID: conversation.id) { _ in preFetched }
        let context = SubAgentRoutingContext(
            hostPersonaID: stringMetadataValue(conversation: conversation, key: "subAgentHostPersonaID"),
            authScopeTags: stringArrayMetadataValue(conversation: conversation, key: "subAgentAuthScopeTags"),
            routingDomain: stringMetadataValue(conversation: conversation, key: "subAgentRoutingDomain"),
            tenantScope: stringMetadataValue(conversation: conversation, key: "subAgentTenantScope")
        )
        let listed = await subAgentPool.listSubAgents(from: entries, routingContext: context, conversationID: conversation.id)
        return listed.filter { entry in
            modeSubAgentAllowListAllows(
                modeAllowList: modeSubAgentAllowList,
                delegateToolName: entry.delegateToolName
            )
        }
    }

    func listSubAgentRegistryEntriesForAPI() async throws -> [SubAgentRegistryEntry] {
        let preFetched = await apiRegistryEntriesForListing(preferredConversation: nil)
        let entries = await subAgentPool.refreshSubAgentCatalog(conversationID: nil) { _ in preFetched }
        return await subAgentPool.listSubAgents(from: entries, routingContext: nil, conversationID: nil)
    }

    private func runTransitionHook(id hookID: String, context: ModeTransitionContext) async throws {
        switch hookID {
        case ModeTransitionHookID.invalidateOrchestrator:
            await invalidateOrchestrator(for: context.conversationID)
        case ModeTransitionHookID.restoreSkillLoader:
            try await skillActivation.restoreSkillLoader(for: context.conversationID)
        default:
            throw ConversationServiceError.modeTransitionHookUnavailable(hookID: hookID)
        }
    }

    private func apiRegistryEntriesForListing(preferredConversation: ModelConversation?) async -> [ToolRegistryEntry] {
        let conversation: ModelConversation?
        if let preferredConversation {
            conversation = preferredConversation
        } else {
            conversation = await currentConversation()
        }
        let orchestrator: SwiftAgentKitOrchestrator?
        if let conversation {
            orchestrator = await orchestratorRuntime.buildTransientOrchestratorForCatalog(
                model: conversation.model,
                conversation: conversation
            )
        } else {
            orchestrator = nil
        }
        // Do not call orchestrator.shutdown() — managers are session-owned / shared.
        if let orchestrator {
            return await OrchestrationToolCatalog.registryEntriesForListing(
                orchestrator: orchestrator,
                dataProvider: toolData,
                logger: logger,
                executionEnvironmentAdapter: SandboxToolExecutionEnvironmentAdapter()
            )
        }
        return await OrchestrationToolCatalog.registryEntriesForListing(
            orchestrator: nil,
            dataProvider: toolData,
            logger: logger,
            executionEnvironmentAdapter: SandboxToolExecutionEnvironmentAdapter()
        )
    }

    private func stringMetadataValue(conversation: ModelConversation, key: String) -> String? {
        guard let metadata = conversation.metadata,
              case .object(let object) = metadata,
              let value = object[key] else { return nil }
        guard case .string(let text) = value else { return nil }
        return text
    }

    private func stringArrayMetadataValue(conversation: ModelConversation, key: String) -> [String] {
        guard let metadata = conversation.metadata,
              case .object(let object) = metadata,
              let value = object[key] else { return [] }
        guard case .array(let array) = value else { return [] }
        return array.compactMap {
            guard case .string(let text) = $0 else { return nil }
            return text
        }
    }

    private func modeSubAgentAllowListAllows(modeAllowList: [String]?, delegateToolName: String) -> Bool {
        guard let modeAllowList else { return true }
        let normalized = Set(modeAllowList.map { $0.lowercased() })
        if normalized.contains("*") { return true }
        return normalized.contains(delegateToolName.lowercased())
    }
}

extension OrchestratorSessionRuntimeService: OrchestratorListenerServicing {
    func runAgenticLoopListener(conversationID: UUID) async {
        guard let orchestrator = await agentRuntime.orchestrator(for: conversationID) else { return }
        let stream = await orchestrator.agenticLoopUpdates
        for await (_, state) in stream {
            if Task.isCancelled { return }
            await applyAgenticLoopState(state, conversationID: conversationID)
        }
    }

    func runOrchestrationSnapshotListener(conversationID: UUID) async {
        guard let orchestrator = await agentRuntime.orchestrator(for: conversationID) else { return }
        let stream = await orchestrator.orchestrationSnapshotUpdates
        for await event in stream {
            if Task.isCancelled { return }
            await agentRuntime.emitOrchestrationStateFromLiveSources(
                swiftAgentKitGeneration: event.generation,
                preferredConversationID: conversationID
            )
        }
    }

    private func applyAgenticLoopState(_ state: AgenticLoopState, conversationID: UUID) async {
        let mapped = OrchestrationStateMapping.mapConversationAgenticPhase(state)
        let targetID = conversationID
        guard var conv = await persistenceDomain.modelConversation(id: targetID) else { return }
        if case .completed = state {
            await messaging.applyTurnSummaryTransformIfNeeded(conversationID: conv.id)
            if let refreshed = await persistenceDomain.modelConversation(id: conv.id) {
                conv = refreshed
            }
        }
        conv.agenticPhase = mapped
        switch state {
        case .started, .llmCall, .llmGenerationCompleted, .waitingForToolExecution, .executingTools, .betweenIterations:
            conv.state = .generating
        case .completed, .cancelled, .failed, .maxIterationsReached:
            conv.state = .idle
            conv.agenticPhase = .idle
        }
        await messaging.update(conversation: conv)
        if conv.state == .idle {
            await slashCommand.drainPendingSlashCommandsIfNeeded(conversationID: conv.id)
        }
    }

    private func ingestSubAgentPendingCompletionEvent(_ event: SubAgentPendingCompletionEvent) async {
        if let handoff = triggerDelegatedCompletionHandoff, await handoff.handle(event) {
            return
        }
        await subAgentCompletion.ingestPendingCompletionEvent(event)
        await resumeConversationAfterPendingCompletionIfNeeded(conversationID: event.conversationID)
    }

    private func resumeConversationAfterPendingCompletionIfNeeded(conversationID: UUID) async {
        await resumeConversationAfterParkIfNeeded(
            conversationID: conversationID,
            allowedModes: [.agent],
            origin: .pendingCompletionResume,
            logLabel: "pending completion"
        )
    }

    /// After stop-on-approval park, rewrite pending tool results and resume (deny) or apply exit (approve).
    func handlePlanExitApprovalPostResolve(
        conversationID: UUID,
        runID: UUID?,
        status: ToolApprovalResolutionStatus,
        reason: String?,
        toolCallId: String?,
        binding: ToolCallApprovalBinding
    ) async {
        _ = (runID, binding)
        switch status {
        case .denied:
            await rewritePendingApprovalToolResults(
                conversationID: conversationID,
                toolCallId: toolCallId,
                content: PlanApprovalFeedback.deniedToolResultContent(reason: reason)
            )
            await resumeConversationAfterParkIfNeeded(
                conversationID: conversationID,
                allowedModes: [.plan],
                origin: .planExitDenialResume,
                logLabel: "plan exit denial"
            )
        case .approved:
            let targetMode = InteractionMode.agent
            do {
                _ = try await toolData.transitionConversationMode(
                    conversationID: conversationID,
                    targetMode: targetMode,
                    initiatedBy: "tool",
                    reason: ModeTransitionToolProvider.exitPlanModeToolName
                )
            } catch {
                logger?.warning(
                    "[OrchestratorSessionRuntimeService] plan exit approve transition failed: \(error)"
                )
            }
            await rewritePendingApprovalToolResults(
                conversationID: conversationID,
                toolCallId: toolCallId,
                content: PlanApprovalFeedback.approvedAfterParkToolResultContent(targetMode: targetMode)
            )
        case .pending:
            break
        }
    }

    private func rewritePendingApprovalToolResults(
        conversationID: UUID,
        toolCallId: String?,
        content: String
    ) async {
        guard var conversation = await persistenceDomain.modelConversation(id: conversationID) else {
            return
        }
        let pending = AgentLoopToolDispatch.approvalPendingToolResultContent
        _ = pending
        let rewritten = PlanExitApprovalTranscript.rewritingPendingApprovalToolResults(
            in: conversation.messages,
            toolCallId: toolCallId,
            content: content
        )
        guard rewritten.changed else { return }
        conversation.messages = rewritten.messages
        await messaging.update(conversation: conversation)
    }

    private func resumeConversationAfterParkIfNeeded(
        conversationID: UUID,
        allowedModes: Set<InteractionMode>,
        origin: RunLaneOriginKind,
        logLabel: String
    ) async {
        let runtimeLifecycle = await agentRuntime.lifecycleSnapshot(for: conversationID)
        guard runtimeLifecycle.generationTask == nil else { return }
        guard var conversation = await persistenceDomain.modelConversation(id: conversationID) else { return }
        guard allowedModes.contains(conversation.interactionMode) else { return }
        let runID = UUID()
        let sessionLaneKey = await selection.runtimeSessionLaneKey(conversationID: conversationID)
        let admissionContext = RunLaneResolver.resolve(
            RunLaneOriginContext(
                sessionKey: sessionLaneKey,
                runID: runID,
                origin: origin
            )
        )
        if let admission = await deps.runtimeLaneCoordinator.tryAcquire(admissionContext) {
            let admissionError = await selection.runtimeSessionError(
                for: admission,
                conversationID: conversationID,
                fallbackRunID: runID,
                activeRuntimeRunIDOverride: nil
            )
            logger?.warning(
                "[OrchestratorSessionRuntimeService] \(logLabel) resume skipped: lane admission failed \(admissionError)"
            )
            return
        }

        conversation.state = .generating
        conversation.agenticPhase = .started
        conversation.llmRequestPhase = .queued
        conversation.lastActiveAt = Date()
        await agentRuntime.updateLifecycle(for: conversationID) { lifecycle in
            lifecycle.currentStreamingRunID = runID
        }
        conversation.currentRunID = runID
        await messaging.update(conversation: conversation)

        guard let acquisition = await orchestratorRuntime.acquireOrchestrator(
            conversation: conversation,
            model: conversation.model
        ) else {
            logger?.warning("[OrchestratorSessionRuntimeService] \(logLabel) resume skipped: orchestrator unavailable")
            await deps.runtimeLaneCoordinator.release(runID: runID)
            return
        }
        await agentRuntime.storeRunOrchestratorHandle(runID: runID, handle: acquisition.handle)
        await startOrchestratorStateListeners(for: conversationID)
        guard let orchestrator = await agentRuntime.orchestrator(for: conversationID) else {
            logger?.warning("[OrchestratorSessionRuntimeService] \(logLabel) resume skipped: orchestrator unavailable")
            await agentRuntime.releaseRunOrchestrator(runID: runID)
            await deps.runtimeLaneCoordinator.release(runID: runID)
            return
        }
        await agentRuntime.startStreamingOrchestrationTask(
            sendingConversationID: conversationID,
            turnLoopAnchorUserMessageID: nil,
            configuration: HarnessRuntimeSession.Configuration(),
            orchestrator: orchestrator
        )
    }
}

extension OrchestratorSessionRuntimeService: OrchestratorModePolicyProviding {
    func modePolicyContext(for conversation: ModelConversation) async -> ModePolicyContext {
        await makeModePolicyContext(for: conversation)
    }

    func resolvedModeProfile(for conversation: ModelConversation) async -> ResolvedModeProfile {
        await makeResolvedModeProfile(for: conversation)
    }

    func defaultSessionModePolicyContext() async -> ModePolicyContext {
        await makeDefaultSessionModePolicyContext()
    }

    func systemPromptMetadata(for conversation: ModelConversation?, resolvedProfile: ResolvedModeProfile) async -> [String: String] {
        makeSystemPromptMetadata(for: conversation, resolvedProfile: resolvedProfile)
    }

    func resolvedThinkingConfig(for conversation: ModelConversation, callContext: ThinkingCallContext) async -> ThinkingConfig {
        await makeResolvedThinkingConfig(for: conversation, callContext: callContext)
    }
}

extension OrchestratorSessionRuntimeService: OrchestratorSessionRuntimeCollaborating {}
