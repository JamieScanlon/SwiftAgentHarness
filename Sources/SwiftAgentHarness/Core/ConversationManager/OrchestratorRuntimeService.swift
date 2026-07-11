import EasyJSON
import Foundation
import Logging
import SwiftAgentKit
import SwiftAgentKitMCP
import SwiftAgentKitA2A
import SwiftAgentKitOrchestrator
import SwiftAgentKitSkills

/// Orchestrator construction, tool-manager wiring, and MCP/A2A lifecycle (Slice G).
public actor OrchestratorRuntimeService {
    struct DispatchPrimaryModelResolution: Sendable {
        let model: Model
        let entry: ModelRegistryEntry?
        let usedModeFallback: Bool
        let modeProfileID: String?
    }

    internal let deps: ConversationRuntimeDependencies
    private let orchestrationCore: AgentRuntimeOrchestrationCore
    nonisolated(unsafe) private var startup: ConversationStartupService!
    private let skillActivation: SkillActivationService
    private let contextProjection: ContextProjectionService
    nonisolated(unsafe) private var spawn: (any SubAgentSpawnLifecycleServicing)!
    private let selection: ConversationSelectionAccessing
    nonisolated(unsafe) internal var modePolicy: (any OrchestratorModePolicyProviding)!
    nonisolated(unsafe) private var sessionCollaborator: (any OrchestratorSessionRuntimeCollaborating)!
    nonisolated(unsafe) private var agentRuntime: AgentRuntimeSessionService!
    nonisolated(unsafe) private var toolData: (any ConversationToolDataProviding)!
    internal let subAgentPool: any SubAgentPooling
    nonisolated(unsafe) private var toolApproval: (any ToolApprovalRuntimeServicing)!
    internal let toolSystemGateway: any ToolSystemGatewaying = DefaultToolSystemGateway()

    nonisolated(unsafe) private var additionalToolProviderFactory: HarnessToolProviderFactory?
    nonisolated(unsafe) private var channelRegistry: (any ChannelPluginLooking)?
    nonisolated(unsafe) private var topicPublication: ConversationTopicPublicationPort?

    init(
        deps: ConversationRuntimeDependencies,
        orchestrationCore: AgentRuntimeOrchestrationCore,
        skillActivation: SkillActivationService,
        contextProjection: ContextProjectionService,
        subAgentPool: any SubAgentPooling,
        selection: ConversationSelectionAccessing
    ) {
        self.deps = deps
        self.orchestrationCore = orchestrationCore
        self.skillActivation = skillActivation
        self.contextProjection = contextProjection
        self.subAgentPool = subAgentPool
        self.selection = selection
    }

    nonisolated func installStartup(_ startup: ConversationStartupService) {
        precondition(self.startup == nil, "ConversationStartupService already installed")
        self.startup = startup
    }

    nonisolated func installSpawn(_ spawn: any SubAgentSpawnLifecycleServicing) {
        precondition(self.spawn == nil, "SubAgentSpawnService already installed")
        self.spawn = spawn
    }

    nonisolated func installModePolicy(_ modePolicy: any OrchestratorModePolicyProviding) {
        precondition(self.modePolicy == nil, "OrchestratorModePolicyProviding already installed")
        self.modePolicy = modePolicy
    }

    nonisolated func installSessionCollaborator(_ sessionCollaborator: any OrchestratorSessionRuntimeCollaborating) {
        precondition(self.sessionCollaborator == nil, "OrchestratorSessionRuntimeCollaborating already installed")
        self.sessionCollaborator = sessionCollaborator
    }

    nonisolated func installAgentRuntime(_ agentRuntime: AgentRuntimeSessionService) {
        precondition(self.agentRuntime == nil, "AgentRuntimeSessionService already installed")
        self.agentRuntime = agentRuntime
    }

    nonisolated func installToolCollaborators(
        toolApproval: any ToolApprovalRuntimeServicing,
        toolData: any ConversationToolDataProviding
    ) {
        precondition(self.toolApproval == nil, "ToolApprovalRuntimeService already installed")
        precondition(self.toolData == nil, "ConversationToolDataService already installed")
        self.toolApproval = toolApproval
        self.toolData = toolData
    }

    nonisolated public func installAdditionalToolProviders(_ factory: @escaping HarnessToolProviderFactory) {
        precondition(self.additionalToolProviderFactory == nil, "Additional tool providers already installed")
        self.additionalToolProviderFactory = factory
    }

    nonisolated func installChannelRegistry(_ registry: any ChannelPluginLooking, holder: ChannelRegistryHolder? = nil) {
        precondition(self.channelRegistry == nil, "ChannelPluginLooking already installed")
        self.channelRegistry = registry
        holder?.assign(registry)
    }

    nonisolated public func installChannelRegistry(
        _ registry: ChannelListenerRegistry,
        holder: ChannelRegistryHolder? = nil,
        sessionLifecycleCoordinator: ChannelSessionLifecycleCoordinator? = nil
    ) {
        installChannelRegistry(registry as any ChannelPluginLooking, holder: holder)
        if let sessionLifecycleCoordinator {
            agentRuntime?.installChannelSessionLifecycle(
                coordinator: sessionLifecycleCoordinator,
                registry: registry
            )
        }
    }

    public func resolvedChannelRegistry() -> ChannelListenerRegistry? {
        channelRegistry as? ChannelListenerRegistry
    }

    nonisolated public func installTopicPublication(_ topics: ConversationTopicPublicationPort) {
        precondition(self.topicPublication == nil, "ConversationTopicPublicationPort already installed")
        self.topicPublication = topics
    }

    
    private var installedStartup: ConversationStartupService {
        guard let startup else {
            preconditionFailure("ConversationStartupService not installed; HarnessRuntimeSessionFactory incomplete")
        }
        return startup
    }

    private var installedSpawn: any SubAgentSpawnLifecycleServicing {
        guard let spawn else {
            preconditionFailure("SubAgentSpawnService not installed; HarnessRuntimeSessionFactory incomplete")
        }
        return spawn
    }

    internal var installedModePolicy: any OrchestratorModePolicyProviding {
        guard let modePolicy else {
            preconditionFailure("OrchestratorModePolicyProviding not installed; HarnessRuntimeSessionFactory incomplete")
        }
        return modePolicy
    }

    private var installedSessionCollaborator: any OrchestratorSessionRuntimeCollaborating {
        guard let sessionCollaborator else {
            preconditionFailure("OrchestratorSessionRuntimeCollaborating not installed; HarnessRuntimeSessionFactory incomplete")
        }
        return sessionCollaborator
    }

    func installTurnToolRegistryEntriesForRuntimeMiddleware(_ entries: [ToolRegistryEntry]) async {
        await installedSessionCollaborator.installTurnToolRegistryEntries(entries)
    }

    /// Mounts a host-supplied deterministic runtime-delivery tool-result middleware on the
    /// runtime-neutral interception seam (applied between the harness subdirectory-hint tracker and
    /// the external-content envelope, before the orchestrator forwards the result to the model).
    public func registerAgentToolResultMiddleware(_ middleware: AgentToolResultMiddleware) async {
        await installedSessionCollaborator.registerAgentToolResultMiddleware(middleware)
    }

    private func orchestratorBinding() async -> any AgentRuntimeOrchestratorBinding {
        if let agentRuntime { return agentRuntime }
        return orchestrationCore
    }

    internal var installedToolApproval: any ToolApprovalRuntimeServicing {
        guard let toolApproval else {
            preconditionFailure("ToolApprovalRuntimeService not installed; HarnessRuntimeSessionFactory incomplete")
        }
        return toolApproval
    }

    private func requireToolData() async -> ConversationToolDataService {
        guard let toolData else {
            preconditionFailure("ConversationToolDataService not installed; HarnessRuntimeSessionFactory incomplete")
        }
        return await toolData.conversationToolData()
    }

    private var logger: Logger? { deps.logger }

    func livePreDispatchPolicyEvaluator(conversationID: UUID) async -> ToolSystemLivePreDispatchPolicyEvaluator {
        makePreDispatchPolicyEvaluator { [self] in
            await self.orchestratorBinding().orchestrator(for: conversationID)
        }
    }

    func allToolRegistryEntriesForOrchestration(orchestrator: SwiftAgentKitOrchestrator) async -> [ToolRegistryEntry] {
        await toolSystemGateway.allRegisteredToolsForTurn(
            orchestrator: orchestrator,
            dataProvider: await requireToolData(),
            logger: logger
        )
    }

    func allToolDefinitionsForOrchestration(orchestrator: SwiftAgentKitOrchestrator) async -> [ToolDefinition] {
        (await allToolRegistryEntriesForOrchestration(orchestrator: orchestrator)).map(\.definition)
    }

    func invalidateOrchestrator(for conversationID: UUID? = nil) async {
        let bindingSource = await orchestratorBinding()
        let lifecycle = if let conversationID {
            await bindingSource.lifecycleSnapshot(for: conversationID)
        } else {
            await bindingSource.lifecycleSnapshot(for: nil)
        }
        logger?.info(
            "[OrchestratorRuntimeService] invalidateOrchestrator: cancelling listeners conversationID=\(conversationID?.uuidString ?? "nil") activeStreamingConversationID=\(lifecycle.activeStreamingConversationID?.uuidString ?? "nil") activeRunID=\(lifecycle.currentStreamingRunID?.uuidString ?? "nil")"
        )
        await installedSpawn.stopCompletionHandoffOwner()
        if let conversationID {
            await bindingSource.invalidateOrchestrator(for: conversationID)
        } else {
            await bindingSource.clearOrchestratorBinding()
        }
    }

    func acquireOrchestrator(
        conversation: ModelConversation,
        model: Model
    ) async -> OrchestratorAcquisition? {
        let bindingSource = await orchestratorBinding()
        let conversationID = conversation.id
        let contextSnapshotSink: @Sendable (LLMResponse, LLMRequestConfig) async -> Void = { response, config in
            if let agentRuntime = self.agentRuntime {
                await agentRuntime.recordContextSnapshot(
                    for: conversationID,
                    from: response,
                    requestConfig: config
                )
            } else {
                await self.orchestrationCore.recordContextSnapshot(
                    for: conversationID,
                    from: response,
                    requestConfig: config
                )
            }
        }
        let preDispatchEvaluator = await livePreDispatchPolicyEvaluator(conversationID: conversationID)
        return await bindingSource.acquireOrchestrator(
            conversationID: conversationID,
            modelName: model.modelName,
            buildIfMissing: { [self] in
                await self.buildOrchestrator(
                    model: model,
                    activeConversation: conversation,
                    contextSnapshotSink: contextSnapshotSink,
                    preDispatchEvaluator: preDispatchEvaluator
                )
            }
        )
    }

    func releaseOrchestrator(_ handle: OrchestratorHandle) async {
        let bindingSource = await orchestratorBinding()
        await bindingSource.releaseOrchestrator(handle)
        await orchestrationCore.evictIdleOrchestrators()
    }

    func buildTransientOrchestratorForCatalog(
        model: Model,
        conversation: ModelConversation?
    ) async -> SwiftAgentKitOrchestrator? {
        let preDispatchEvaluator = makePreDispatchPolicyEvaluator { nil }
        guard let built = await buildOrchestrator(
            model: model,
            activeConversation: conversation,
            contextSnapshotSink: { _, _ in },
            preDispatchEvaluator: preDispatchEvaluator
        ) else {
            return nil
        }
        return built.orchestrator
    }

    func setupOrchestrator(with selectedModel: Model, activeConversation preferredConversation: ModelConversation? = nil) async {
        let conversation: ModelConversation?
        if let preferredConversation {
            conversation = preferredConversation
        } else {
            conversation = await selection.currentConversation()
        }
        guard let conversation else {
            logger?.warning(
                "[OrchestratorRuntimeService] setupOrchestrator: no active conversation; skipping orchestrator warm-up model=\(selectedModel.modelName)"
            )
            return
        }
        guard let acquisition = await acquireOrchestrator(conversation: conversation, model: selectedModel) else {
            logger?.warning(
                "[OrchestratorRuntimeService] setupOrchestrator: failed to acquire orchestrator; skipping warm-up conversationID=\(conversation.id.uuidString) model=\(selectedModel.modelName)"
            )
            return
        }
        await installedSessionCollaborator.startOrchestratorStateListeners(for: conversation.id)
        await releaseOrchestrator(acquisition.handle)
    }

    func releasePooledOrchestrator(_ orchestrator: SwiftAgentKitOrchestrator?) async {
        await orchestrator?.endMessageStream()
    }

    func shutdownToolRuntimes(existingOrchestrator: SwiftAgentKitOrchestrator?) async {
        if let existingOrchestrator {
            await existingOrchestrator.shutdown()
        } else {
            await installedStartup.mcpManagerForOrchestration()?.shutdown()
            await installedStartup.a2aManagerForOrchestration()?.shutdown()
            await installedStartup.acpManagerForOrchestration()?.shutdown()
        }
    }

    func orchestratorAdditionalParameters(for conversation: ModelConversation?) async -> JSON? {
        let metadata: [String: String]
        if let conversation {
            let profile = await installedModePolicy.resolvedModeProfile(for: conversation)
            metadata = await installedModePolicy.systemPromptMetadata(for: conversation, resolvedProfile: profile)
        } else {
            metadata = [:]
        }
        let thinkingConfig: ThinkingConfig?
        if let conversation {
            let callContext: ThinkingCallContext = conversation.parentConversationID == nil ? .foreground : .subAgent
            var resolved = await installedModePolicy.resolvedThinkingConfig(for: conversation, callContext: callContext)
            if let runID = conversation.currentRunID,
               let turnConfig = await agentRuntime?.activeTurnConfiguration(
                   conversationID: conversation.id,
                   runID: runID
               ),
               let override = turnConfig.turnThinkingOverride {
                resolved = override
            }
            thinkingConfig = resolved
        } else {
            thinkingConfig = nil
        }
        var enrichedMetadata = metadata
        if let conversation,
           let entry = await deps.registryEntryProvider?(conversation.model.id),
           let binding = entry.primaryBinding,
           let contribution = ProviderRuntimeHooks.systemPromptContribution(binding: binding) {
            ProviderPromptContribution.applySectionOverrides(
                metadata: &enrichedMetadata,
                contribution: contribution
            )
        }
        if enrichedMetadata.isEmpty, thinkingConfig == nil {
            return nil
        }

        var payload: [String: JSON] = [:]
        if !enrichedMetadata.isEmpty {
            payload["systemPromptMetadata"] = .object(enrichedMetadata.mapValues { .string($0) })
            payload["contextEngineSystemPromptMetadata"] = .object(enrichedMetadata.mapValues { .string($0) })
        }
        if let conversationID = conversation?.id,
           let attachmentProjection = await contextProjection.cachedAttachmentProjection(conversationID: conversationID) {
            let decisions: [JSON] = attachmentProjection.decisions.map { decision in
                .object([
                    "attachmentID": .string(decision.attachmentID.uuidString),
                    "attachmentName": .string(decision.attachmentName),
                    "attachmentKind": .string(decision.attachmentKind),
                    "disposition": .string(decision.disposition.rawValue),
                    "reason": .string(decision.reason),
                ])
            }
            payload["contextEngineAttachmentProjection"] = .object([
                "projectionFingerprint": .string(attachmentProjection.projectionFingerprint),
                "decisions": .array(decisions),
            ])
        }
        if let thinkingConfig {
            payload["thinkingConfig"] = thinkingConfigJSON(thinkingConfig)
        }

        return .object(payload)
    }

    /// Per-`updateConversation` options merged with ``OrchestratorConfig`` in SwiftAgentKit.
    func orchestratorInvocationOptions(
        for conversation: ModelConversation?,
        toolTurnSnapshot: RuntimeToolTurnPolicySnapshot? = nil,
        effectiveToolEntries: [ToolRegistryEntry] = [],
        availabilitySnapshots: [RuntimeToolAvailabilitySnapshot] = [],
        forcedToolChoiceRequired: Bool = false
    ) async -> OrchestratorInvocationOptions {
        let additional = await orchestratorAdditionalParameters(for: conversation)
        let effectiveAvailabilitySnapshots = toolTurnSnapshot?.availabilitySnapshots ?? availabilitySnapshots
        let fallbackEffectiveEntriesFromSnapshots: [ToolRegistryEntry] = effectiveAvailabilitySnapshots
            .filter { $0.decision.isAdvertisedToModel }
            .map(\.entry)
            .sorted { $0.name < $1.name }
        let effectiveEntriesForDispatch = toolTurnSnapshot?.effectiveEntries
            ?? (fallbackEffectiveEntriesFromSnapshots.isEmpty ? effectiveToolEntries : fallbackEffectiveEntriesFromSnapshots)
        await installTurnToolRegistryEntriesForRuntimeMiddleware(effectiveEntriesForDispatch)
        let dispatchContract = toolTurnSnapshot?.dispatchContract
            ?? toolSystemGateway.dispatchContract(
                from: deps.toolPolicy,
                effectiveEntries: effectiveEntriesForDispatch
            )
        let parallelDispatchEnabled = dispatchContract.parallelDispatchEnabled
        let preDispatchEvaluator = if let conversation {
            await livePreDispatchPolicyEvaluator(conversationID: conversation.id)
        } else {
            makePreDispatchPolicyEvaluator { nil }
        }
        let plannerMode = orchestratorDispatchPlannerMode(dispatchContract.dispatchPlannerMode)
        let toolSchemaDispatch = toolSchemaDispatchMaps(
            for: conversation,
            effectiveEntries: effectiveEntriesForDispatch
        )
        guard let conversation else {
            return OrchestratorInvocationOptions(
                additionalParameters: additional,
                parallelToolDispatchEnabled: parallelDispatchEnabled,
                dispatchPlannerMode: plannerMode,
                preDispatchPolicyEvaluator: preDispatchEvaluator,
                toolParameterSchemasByName: toolSchemaDispatch.parameterSchemas,
                toolSchemaStrictByName: toolSchemaDispatch.strictByName
            )
        }
        let resolved = await installedModePolicy.resolvedModeProfile(for: conversation)
        let configuredMaxSteps = resolved.runtime.maxIterations ?? deps.agentHarness.maxAgenticStepsPerUpdate
        let hasAvailableToolsForTurn = !effectiveEntriesForDispatch.isEmpty
        let assistantPersistenceMode: AssistantPersistenceMode? = nil
        let terminationPolicy = resolved.runtime.termination?.policy.rawValue ?? "nil"
        let terminationRecovery = resolved.runtime.termination?.recovery.map { recovery in
            "\(recovery.strategy.rawValue),rollback=\(recovery.rollbackStalledTurn),maxAttempts=\(recovery.maxAttempts),reminder=\(recovery.reminder.rawValue)"
        } ?? "nil"
        let maxSteps: Int? = {
            guard let configuredMaxSteps else { return nil }
            guard hasAvailableToolsForTurn else { return configuredMaxSteps }
            return max(3, configuredMaxSteps)
        }()
        logger?.debug(
            "[OrchestratorRuntimeService] orchestratorInvocationOptions conversationID=\(conversation.id.uuidString) mode=\(conversation.interactionMode.rawValue) availableTools=\(effectiveEntriesForDispatch.count) allowedToolSnapshots=\(effectiveAvailabilitySnapshots.filter { $0.decision.allowed }.count) blockedToolSnapshots=\(effectiveAvailabilitySnapshots.filter { !$0.decision.allowed }.count) terminationPolicy=\(terminationPolicy) terminationRecovery=\(terminationRecovery) forcedToolChoice=\(forcedToolChoiceRequired) assistantPersistenceMode=\(assistantPersistenceMode.map { String(describing: $0) } ?? "nil") configuredMaxSteps=\(configuredMaxSteps.map(String.init) ?? "nil") effectiveMaxSteps=\(maxSteps.map(String.init) ?? "nil")"
        )
        if let configuredMaxSteps,
           let maxSteps,
           maxSteps != configuredMaxSteps {
            logger?.info(
                "[OrchestratorRuntimeService] Raised maxAgenticStepsPerUpdate from \(configuredMaxSteps) to \(maxSteps) for tool-capable turn conversationID=\(conversation.id.uuidString) mode=\(conversation.interactionMode.rawValue)"
            )
        }
        let appliesAgentBuildHarnessPolicy = resolved.appliesAgentBuildOrchestratorHarness
        guard appliesAgentBuildHarnessPolicy else {
            return OrchestratorInvocationOptions(
                additionalParameters: additional,
                assistantPersistenceMode: assistantPersistenceMode,
                parallelToolDispatchEnabled: parallelDispatchEnabled,
                dispatchPlannerMode: plannerMode,
                preDispatchPolicyEvaluator: preDispatchEvaluator,
                maxAgenticStepsPerUpdate: maxSteps,
                toolParameterSchemasByName: toolSchemaDispatch.parameterSchemas,
                toolSchemaStrictByName: toolSchemaDispatch.strictByName
            )
        }
        if forcedToolChoiceRequired {
            logger?.info(
                "[OrchestratorRuntimeService] required tool choice enabled conversationID=\(conversation.id.uuidString) mode=\(conversation.interactionMode.rawValue) reason=termination_recovery"
            )
            return OrchestratorInvocationOptions(
                additionalParameters: additional,
                toolInvocationPolicy: .required,
                assistantPersistenceMode: assistantPersistenceMode,
                parallelToolDispatchEnabled: parallelDispatchEnabled,
                dispatchPlannerMode: plannerMode,
                preDispatchPolicyEvaluator: preDispatchEvaluator,
                maxAgenticStepsPerUpdate: maxSteps,
                rejectAssistantTurnWithNoToolCallsWhenToolsAvailable: true,
                maxCorrectionRetries: deps.agentHarness.maxCorrectionRetries,
                toolParameterSchemasByName: toolSchemaDispatch.parameterSchemas,
                toolSchemaStrictByName: toolSchemaDispatch.strictByName
            )
        }
        return OrchestratorInvocationOptions(
            additionalParameters: additional,
            toolInvocationPolicy: deps.agentHarness.agentBuildToolInvocationPolicy,
            assistantPersistenceMode: assistantPersistenceMode,
            parallelToolDispatchEnabled: parallelDispatchEnabled,
            dispatchPlannerMode: plannerMode,
            preDispatchPolicyEvaluator: preDispatchEvaluator,
            maxAgenticStepsPerUpdate: maxSteps,
            rejectAssistantTurnWithNoToolCallsWhenToolsAvailable: deps.agentHarness.rejectAssistantTurnWithNoToolCallsWhenToolsAvailable,
            maxCorrectionRetries: deps.agentHarness.maxCorrectionRetries,
            toolParameterSchemasByName: toolSchemaDispatch.parameterSchemas,
            toolSchemaStrictByName: toolSchemaDispatch.strictByName
        )
    }

    private func toolSchemaDispatchMaps(
        for conversation: ModelConversation?,
        effectiveEntries: [ToolRegistryEntry]
    ) -> (parameterSchemas: [String: JSON], strictByName: [String: Bool]) {
        guard let conversation, !effectiveEntries.isEmpty else {
            return ([:], [:])
        }
        let binding = ProviderBinding(
            providerId: conversation.model.modelProtocol.rawValue,
            modelProtocol: conversation.model.modelProtocol,
            endpointModelId: conversation.model.modelName,
            serverURL: conversation.model.serverURL
        )
        let compat = ProviderRuntimeHooks.compatForBinding(binding)
        let batch = ProviderRuntimeHooks.normalizeToolSchemaBatch(
            entries: effectiveEntries,
            binding: binding,
            compat: compat
        )
        ProviderRuntimeHooks.logToolSchemaDiagnostics(batch.diagnostics, logger: logger)
        return (batch.parameterSchemasByName, batch.strictByName)
    }

    private func buildToolManager(
        systemPrompt: SystemPrompt,
        skillLoader: SkillLoader?,
        activeConversation: ModelConversation?
    ) async -> ToolManager {
        var providers: [any ToolProvider] = []
        if systemPrompt.includeAgentSkills, let skillLoader {
            let conv = activeConversation
            let policyCtx = if let conv {
                await installedModePolicy.modePolicyContext(for: conv)
            } else {
                await installedModePolicy.defaultSessionModePolicyContext()
            }
            let inner = SkillsToolProvider(loader: skillLoader, logger: logger)
            let routingConv = conv
            let gated = SkillPolicySkillsToolProvider(inner: inner) { skillName in
                policyCtx.resolvedProfile.skills.isSkillAllowed(name: skillName, context: policyCtx)
                    && (routingConv.map { ModeProfileSkillsSlice.isSkillAllowedByRoutingPolicy(name: skillName, conversation: $0) } ?? true)
            }
            let persisting = PersistingActivatedSkillsToolProvider(inner: gated) {
                if let conversationID = activeConversation?.id {
                    await self.installedSessionCollaborator.persistActivatedSkillsFromLoader(conversationID: conversationID)
                } else {
                    await self.installedSessionCollaborator.persistActivatedSkillsFromLoaderToCurrentConversation()
                }
            }
            providers.append(persisting)
        }
        let toolData = await requireToolData()
        providers.append(
            ConversationsToolProvider(
                dataProvider: toolData,
                logger: logger
            )
        )
        providers.append(
            AgentPlanToolProvider(
                dataProvider: toolData,
                logger: logger
            )
        )
        let messageConv = activeConversation
        providers.append(
            MessageToolProvider(
                resolveConversationID: {
                    if let scope = ConversationScope.current {
                        return scope.selfID
                    }
                    return messageConv?.id
                },
                resolveDeliveryMetadata: {
                    Self.messageDeliveryMetadata(from: messageConv)
                },
                logger: logger
            )
        )
        providers.append(
            TerminationToolProvider(
                dataProvider: toolData,
                logger: logger
            )
        )
        providers.append(
            ModeTransitionToolProvider(
                dataProvider: toolData,
                logger: logger
            )
        )
        let workspaceRoot = activeConversation?.harnessPersistenceCwd
            ?? FileManager.default.currentDirectoryPath
        if !workspaceRoot.isEmpty {
            let memoryService = (deps.contextEngine as? DefaultContextEngine)?.memoryService
            var memoryDirectory: URL?
            if let memoryService, let conv = activeConversation,
               let context = try? memoryService.makeSessionContext(conversationID: conv.id, cwd: workspaceRoot) {
                memoryDirectory = context.memoryDirectory
            }
            let memoryWriteOnly = ConversationLineageInference.isMemoryWriteScopedProfile(
                activeConversation?.modeProfileID
            )
            let sessionKey = activeConversation?.id.uuidString ?? UUID().uuidString
            let conversationID = activeConversation?.id
            let topics = topicPublication
            let execApprovalPending: @Sendable (ExecApprovalRequest) async -> Void = { request in
                guard let conversationID, let topics else { return }
                let intent = ClientSurfaceIntent(
                    kind: .execApprovalRequired,
                    label: request.title,
                    approvalID: request.id,
                    command: request.command,
                    presentation: request.presentation
                )
                guard let utf8 = try? String(data: JSONEncoder().encode(intent), encoding: .utf8) else { return }
                await topics.publishConversationTopicEventIfConfigured(
                    conversationID: conversationID,
                    payload: .surfaceIntentJSONUTF8(utf8)
                )
            }
            let execApprovalCleared: @Sendable (String) async -> Void = { approvalID in
                guard let conversationID, let topics else { return }
                let intent = ClientSurfaceIntent(
                    kind: .execApprovalCleared,
                    approvalID: approvalID
                )
                guard let utf8 = try? String(data: JSONEncoder().encode(intent), encoding: .utf8) else { return }
                await topics.publishConversationTopicEventIfConfigured(
                    conversationID: conversationID,
                    payload: .surfaceIntentJSONUTF8(utf8)
                )
            }
            let execApprovalScope: ExecApprovalScope? = activeConversation.map {
                ExecApprovalScope(conversationID: $0.id, ownerAccountID: $0.ownerAccountID)
            }
            let approvalDelivery = await ExecApprovalDeliveryFactory.make(
                scope: execApprovalScope ?? ExecApprovalScope(
                    conversationID: UUID(uuidString: sessionKey) ?? UUID(),
                    ownerAccountID: nil
                ),
                channelRegistry: channelRegistry,
                metadata: activeConversation?.metadata,
                onPending: execApprovalPending,
                onCleared: execApprovalCleared
            )
            let execRuntime = ExecRuntimeService(
                workspaceRoot: workspaceRoot,
                approvalDelivery: approvalDelivery,
                logger: logger
            )
            let skillsDirectory = (try? SystemPrompt.loadSkillsFolderPathFromConfig())
                .flatMap { SkillsDirectoryResolver.resolve(workspaceRoot: workspaceRoot, configuredPath: $0) }
            let runtimeContext = ExecRuntimeContext(
                sessionKey: sessionKey,
                agentID: sessionKey,
                isMainSession: true,
                memoryDirectory: memoryDirectory?.path,
                skillsDirectory: skillsDirectory?.path,
                memoryWriteOnly: memoryWriteOnly
            )
            let perCallElevationModes: [String: ElevatedMode] = Dictionary(
                uniqueKeysWithValues: [WorkspaceFilesystemToolProvider.bashToolName]
                    .compactMap { name in deps.toolPolicy.perCallElevationMode(name: name).map { (name, $0) } }
            )
            let elevatedAllowlist = deps.toolPolicy.elevatedAllowFrom
            let persistence = deps.persistenceDomain
            let runtime = agentRuntime
            let resolveSenderIdentity: @Sendable () async -> ExecSenderIdentity = {
                if let conversationID,
                   let conv = await persistence.modelConversation(id: conversationID) {
                    if let runID = conv.currentRunID,
                       let config = await runtime?.activeTurnConfiguration(conversationID: conversationID, runID: runID),
                       let surface = config.originSurface {
                        return ExecSenderIdentity(
                            surface: surface,
                            senderID: config.originSenderID ?? ""
                        )
                    }
                    if let trigger = TriggerHostConversationMetadata.triggerFromFingerprint(conv.metadata) {
                        return ExecSenderIdentity(
                            surface: trigger.sourceMetadata["channel"] ?? trigger.source.rawValue,
                            senderID: trigger.sourceMetadata["senderId"] ?? trigger.initiator.id ?? ""
                        )
                    }
                }
                return .cliDefault
            }
            providers.append(
                WorkspaceFilesystemToolProvider(
                    workspaceRoot: workspaceRoot,
                    execRuntime: execRuntime,
                    runtimeContext: runtimeContext,
                    perCallElevationModes: perCallElevationModes,
                    elevatedAllowlist: elevatedAllowlist,
                    resolveSenderIdentity: resolveSenderIdentity,
                    onMemoryWrite: { path in
                        guard let memoryService, let conv = activeConversation else { return }
                        if let parentID = conv.parentConversationID {
                            await memoryService.recordAuxiliaryMemoryWrite(path: path, conversationID: parentID)
                        } else {
                            await memoryService.recordMemoryWrite(path: path, conversationID: conv.id)
                        }
                    },
                    validatePreCompactionFlushWrite: { path, priorContent, newContent in
                        guard let memoryService, let conv = activeConversation else { return }
                        let guardConversationID = conv.parentConversationID ?? conv.id
                        if let message = await memoryService.validatePreCompactionFlushWrite(
                            conversationID: guardConversationID,
                            absolutePath: path,
                            priorContent: priorContent,
                            newContent: newContent
                        ) {
                            throw PreCompactionFlushWriteToolError(message: message)
                        }
                    },
                    logger: logger,
                    sessionStoreRoot: SessionPersistenceConfiguration.sessionStoreRoot,
                    sessionAgentId: SessionPersistenceConfiguration.sessionAgentId,
                    conversationID: conversationID
                )
            )
            if let memoryDirectory {
                if let memoryService, let conversationID,
                   let searchDependencies = await memoryService.memorySearchToolDependencies(conversationID: conversationID) {
                    providers.append(MemorySearchToolProvider(memoryDirectory: memoryDirectory, dependencies: searchDependencies))
                } else {
                    providers.append(MemorySearchToolProvider(memoryDirectory: memoryDirectory, search: HybridMemorySearch()))
                }
            }
            let workshopConfig = SkillWorkshopConfigurationLoader.loadFromPromptConfigBundle(logger: logger)
            if workshopConfig.enabled,
               let skillsPath = try? SystemPrompt.loadSkillsFolderPathFromConfig() {
                let gitRoot = GitRootResolver.canonicalGitRoot(for: workspaceRoot)
                let workspaceKey = AgentMemoryPathResolver.sanitizedProjectKey(
                    canonicalGitRoot: gitRoot,
                    cwd: workspaceRoot
                )
                let skillsRoot = URL(fileURLWithPath: skillsPath)
                let store = SkillWorkshopProposalStore(workspaceKey: workspaceKey, config: workshopConfig)
                let workshopService = SkillWorkshopService(
                    config: workshopConfig,
                    workspaceKey: workspaceKey,
                    skillsRoot: skillsRoot,
                    store: store,
                    onApplied: { [skillActivation] sessionID in
                        await skillActivation.invalidateSkillCatalog(for: sessionID ?? conversationID)
                    }
                )
                providers.append(
                    SkillWorkshopToolProvider(
                        service: workshopService,
                        conversationID: conversationID
                    )
                )
            }
        }
        if deps.conversationTransformConfiguration.contextCompaction.manualToolEnabled {
            providers.append(
                ContextCompactionToolProvider(
                    performer: ContextCompactionProjectionPerformer(projection: contextProjection),
                    logger: logger
                )
            )
        }
        if let additionalToolProviderFactory {
            let context = HarnessToolProviderContext(
                conversation: activeConversation,
                workspaceRoot: workspaceRoot.isEmpty ? nil : workspaceRoot,
                logger: logger,
                pluginGroupID: "plugins"
            )
            let hostProviders = additionalToolProviderFactory(context)
            providers.append(contentsOf: PluginGroupTaggingToolProvider.wrapHostProviders(
                hostProviders,
                pluginGroupID: context.pluginGroupID
            ))
        }
        let runtimePipeline = await installedSessionCollaborator.runtimeToolResultMiddlewarePipeline()
        providers = providers.map { provider in
            TransformingToolProvider(
                inner: provider,
                pipeline: runtimePipeline,
                stage: .runtimeDelivery,
                logger: logger
            )
        }
        return ToolManager(
            providers: providers,
            descriptorValidationMode: toolDescriptorValidationMode(deps.toolPolicy.descriptorValidationMode)
        )
    }

    internal func testing_buildToolManagerToolNames(
        systemPrompt: SystemPrompt,
        activeConversation: ModelConversation?
    ) async -> [String] {
        let manager = await buildToolManager(
            systemPrompt: systemPrompt,
            skillLoader: nil,
            activeConversation: activeConversation
        )
        return await manager.allRegisteredToolsAsync().map { $0.definition.name }
    }

    internal func resolveDispatchPrimaryModel(
        selectedModel: Model,
        primaryEntry: ModelRegistryEntry?,
        activeConversation: ModelConversation?
    ) async -> DispatchPrimaryModelResolution? {
        guard let activeConversation else {
            return DispatchPrimaryModelResolution(
                model: selectedModel,
                entry: primaryEntry,
                usedModeFallback: false,
                modeProfileID: nil
            )
        }
        let resolvedProfile = await installedModePolicy.resolvedModeProfile(for: activeConversation)
        let routingQueryJSON = activeConversation.routingPrefs?.queryJSON
        let waterfall = ModeProfileModelRouting.dispatchQueryWaterfall(
            routingQueryJSON: routingQueryJSON,
            resolvedProfile: resolvedProfile
        )
        guard let primaryQuery = waterfall.primaryQuery else {
            return DispatchPrimaryModelResolution(
                model: selectedModel,
                entry: primaryEntry,
                usedModeFallback: false,
                modeProfileID: resolvedProfile.id
            )
        }
        guard let rankedRegistryEntriesProvider = deps.rankedRegistryEntriesProvider else {
            logger?.error(
                "[OrchestratorRuntimeService] Dispatch model resolution requires ranked registry provider conversation=\(activeConversation.id.uuidString) source=\(String(describing: waterfall.primarySource))"
            )
            return nil
        }

        let primaryQueryRef = dispatchRoutingModelQueryReference(
            selectedModel: selectedModel,
            primaryEntry: primaryEntry,
            preferredUseClass: primaryQuery
        )
        let primaryCandidates = await rankedRegistryEntriesProvider(primaryQueryRef)
        if let selected = primaryCandidates.first {
            return DispatchPrimaryModelResolution(
                model: selected.toModel(),
                entry: selected,
                usedModeFallback: false,
                modeProfileID: resolvedProfile.id
            )
        }

        if waterfall.primarySource == .routingOverride {
            logger?.error(
                "[OrchestratorRuntimeService] Dispatch model routing override resolved no candidates conversation=\(activeConversation.id.uuidString)"
            )
            return nil
        }

        guard let fallbackQuery = waterfall.modeFallbackQuery else {
            logger?.error(
                "[OrchestratorRuntimeService] Dispatch mode query resolved no candidates and no mode fallback is configured conversation=\(activeConversation.id.uuidString) modeProfile=\(resolvedProfile.id)"
            )
            return nil
        }
        let fallbackQueryRef = dispatchRoutingModelQueryReference(
            selectedModel: selectedModel,
            primaryEntry: primaryEntry,
            preferredUseClass: fallbackQuery
        )
        let fallbackCandidates = await rankedRegistryEntriesProvider(fallbackQueryRef)
        guard let selectedFallback = fallbackCandidates.first else {
            logger?.error(
                "[OrchestratorRuntimeService] Dispatch mode query fallback resolved no candidates conversation=\(activeConversation.id.uuidString) modeProfile=\(resolvedProfile.id)"
            )
            return nil
        }
        return DispatchPrimaryModelResolution(
            model: selectedFallback.toModel(),
            entry: selectedFallback,
            usedModeFallback: true,
            modeProfileID: resolvedProfile.id
        )
    }

    private func dispatchRoutingModelQueryReference(
        selectedModel: Model,
        primaryEntry: ModelRegistryEntry?,
        preferredUseClass: String
    ) -> ModelReference {
        .query(
            ModelQuery(
                mustIncludeCapabilities: Set(selectedModel.capabilities),
                preferredUseClass: preferredUseClass,
                preferredFamily: primaryEntry?.family,
                allowSubstitution: true
            )
        )
    }

    private func schedulerCredentialKey(for bindings: [ProviderBinding]?) -> String? {
        guard let binding = bindings?.sorted(by: { $0.priority < $1.priority }).first else {
            return nil
        }
        let profile = binding.authProfile?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProfile = (profile?.isEmpty == false) ? profile! : "default"
        return "\(binding.providerId)#\(normalizedProfile)"
    }

    private func toolDescriptorValidationMode(
        _ mode: ToolPolicyConfiguration.DescriptorValidationMode
    ) -> ToolDescriptorValidationMode {
        switch mode {
        case .warning:
            return .warning
        case .strict:
            return .strict
        }
    }

    private func orchestratorDispatchPlannerMode(
        _ mode: ToolPolicyConfiguration.DispatchPlannerMode?
    ) -> ToolDispatchPlannerMode? {
        let normalized = ToolDispatchPlannerNormalization.effectivePlannerMode(mode)
        ToolDispatchPlannerNormalization.warnIfAllParallelRemapped(
            wasRemapped: normalized.wasAllParallelRemapped,
            fingerprint: "orchestrator:\(deps.toolPolicy.stableAllowlistSignature())",
            logger: logger
        )
        guard let effective = normalized.mode else { return nil }
        switch effective {
        case .serial:
            return .serial
        case .mixedDeterministic:
            return .mixedDeterministic
        case .allParallel:
            return .mixedDeterministic
        }
    }

    private func makeScheduledRuntimeLLM(
        model: Model,
        providerBindings: [ProviderBinding]?,
        conversationID: UUID?,
        ownerAccountID: UUID?,
        systemPrompt: SystemPrompt
    ) -> any LLMProtocol {
        let rawBaseLLM = deps.llmFactory.makeBaseLLM(
            model: model,
            providerBindings: providerBindings,
            conversationID: conversationID,
            ownerAccountID: ownerAccountID,
            systemPrompt: systemPrompt,
            logger: logger,
            attemptObserver: { [invocationCoordinator = deps.invocationCoordinator] observation in
                await invocationCoordinator.recordAttemptObservation(observation)
            }
        )
        let lifecycleLLM = LifecycleReportingLLM(
            baseLLM: rawBaseLLM,
            modelID: model.id,
            coordinator: deps.invocationCoordinator
        )
        return SchedulingLLM(
            baseLLM: lifecycleLLM,
            scheduler: deps.callScheduler,
            modelID: model.id,
            conversationID: conversationID,
            credentialKey: schedulerCredentialKey(for: providerBindings),
            coordinator: deps.invocationCoordinator
        )
    }

    private func makeSubstitutionCandidates(
        primaryModel: Model,
        primaryBindings: [ProviderBinding]?,
        fallbackEntries: [ModelRegistryEntry],
        activeConversationID: UUID?,
        ownerAccountID: UUID?,
        systemPrompt: SystemPrompt
    ) -> [RankedFallbackSubstitutionLLM.Candidate] {
        var candidates: [RankedFallbackSubstitutionLLM.Candidate] = [
            RankedFallbackSubstitutionLLM.Candidate(
                modelID: primaryModel.id,
                label: primaryModel.modelName,
                llm: makeScheduledRuntimeLLM(
                    model: primaryModel,
                    providerBindings: primaryBindings,
                    conversationID: activeConversationID,
                    ownerAccountID: ownerAccountID,
                    systemPrompt: systemPrompt
                )
            )
        ]
        for entry in fallbackEntries {
            let model = entry.toModel()
            candidates.append(
                RankedFallbackSubstitutionLLM.Candidate(
                    modelID: model.id,
                    label: entry.slug,
                    llm: makeScheduledRuntimeLLM(
                        model: model,
                        providerBindings: entry.providers,
                        conversationID: activeConversationID,
                        ownerAccountID: ownerAccountID,
                        systemPrompt: systemPrompt
                    )
                )
            )
        }
        return candidates
    }

    private func rankedSubstitutionEntries(
        selectedModel: Model,
        primaryEntry: ModelRegistryEntry?,
        activeConversation: ModelConversation?
    ) async -> [ModelRegistryEntry] {
        guard let rankedRegistryEntriesProvider = deps.rankedRegistryEntriesProvider else { return [] }
        let substitutionPolicy = deps.llmFactory.substitutionPolicy()
        guard case .enabled(let maxFallbackCandidates) = substitutionPolicy else { return [] }

        let routingQuery = activeConversation?.routingPrefs?.queryJSON?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredUseClass = (routingQuery?.isEmpty == false) ? routingQuery : primaryEntry?.useClasses.first
        let query = ModelQuery(
            mustIncludeCapabilities: Set(selectedModel.capabilities),
            preferredUseClass: preferredUseClass,
            preferredFamily: primaryEntry?.family,
            allowSubstitution: true
        )
        let ranked = await rankedRegistryEntriesProvider(.query(query))
        return ModelQuery.rankedSubstitutionCandidates(
            entries: ranked,
            query: query,
            excludingModelID: selectedModel.id,
            maxCandidates: maxFallbackCandidates
        )
    }

    private func thinkingConfigJSON(_ thinkingConfig: ThinkingConfig) -> JSON {
        switch thinkingConfig {
        case .disabled:
            return .string("disabled")
        case .adaptive:
            return .string("adaptive")
        case .level(let level, let budgetTokens):
            var object: [String: JSON] = ["level": .string(level.rawValue)]
            if let budgetTokens {
                object["budgetTokens"] = .integer(budgetTokens)
            }
            return .object(object)
        }
    }

    func makePreDispatchPolicyEvaluator(
        resolveOrchestrator: @escaping @Sendable () async -> SwiftAgentKitOrchestrator?
    ) -> ToolSystemLivePreDispatchPolicyEvaluator {
        ToolSystemLivePreDispatchPolicyEvaluator(
            gateway: toolSystemGateway,
            deps: deps,
            modePolicy: installedModePolicy,
            toolApproval: installedToolApproval,
            subAgentPool: subAgentPool,
            persistenceDomain: deps.persistenceDomain,
            resolveOrchestrator: resolveOrchestrator,
            resolveToolData: { await self.requireToolData() },
            resolveActiveTurnConfiguration: { conversationID, runID in
                await self.agentRuntime?.activeTurnConfiguration(
                    conversationID: conversationID,
                    runID: runID
                )
            },
            logger: logger
        )
    }

    func buildOrchestrator(
        model selectedModel: Model,
        activeConversation: ModelConversation?,
        contextSnapshotSink: @escaping @Sendable (LLMResponse, LLMRequestConfig) async -> Void,
        preDispatchEvaluator: ToolSystemLivePreDispatchPolicyEvaluator
    ) async -> BuiltOrchestrator? {
        let activeConversationID = activeConversation?.id
        let skillLoader = await skillActivation.skillLoader(for: activeConversationID)
        let systemPrompt: SystemPrompt
        do {
            let conv = activeConversation
            let interactionMode = conv?.interactionMode ?? .chat
            let modeCtx: ModePolicyContext? = if let conv { await installedModePolicy.modePolicyContext(for: conv) } else { nil }
            let resolvedAssembly: SystemPromptAssemblyKind? = if let conv {
                (await installedModePolicy.resolvedModeProfile(for: conv)).assemblyKind
            } else {
                nil
            }
            systemPrompt = try await SystemPrompt(
                skillLoader: skillLoader,
                logger: logger,
                interactionMode: interactionMode,
                assemblyKind: resolvedAssembly,
                routingPolicyConversation: conv,
                modePolicyContext: modeCtx
            )
        } catch {
            logger?.error("[OrchestratorRuntimeService] Failed to create SystemPrompt: \(error)")
            return nil
        }
        var effectivePrimaryModel = selectedModel
        var effectivePrimaryEntry = await deps.registryEntryProvider?(selectedModel.id)
        if let resolved = await resolveDispatchPrimaryModel(
            selectedModel: selectedModel,
            primaryEntry: effectivePrimaryEntry,
            activeConversation: activeConversation
        ) {
            effectivePrimaryModel = resolved.model
            effectivePrimaryEntry = resolved.entry
            if resolved.usedModeFallback {
                logger?.warning(
                    "[OrchestratorRuntimeService] Dispatch model fallback activated for conversation=\(activeConversationID?.uuidString ?? "none") modeProfile=\(resolved.modeProfileID ?? "none")"
                )
            }
        } else {
            return nil
        }
        let providerBindings = effectivePrimaryEntry?.providers
        let fallbackEntries = await rankedSubstitutionEntries(
            selectedModel: effectivePrimaryModel,
            primaryEntry: effectivePrimaryEntry,
            activeConversation: activeConversation
        )
        let substitutionCandidates = makeSubstitutionCandidates(
            primaryModel: effectivePrimaryModel,
            primaryBindings: providerBindings,
            fallbackEntries: fallbackEntries,
            activeConversationID: activeConversationID,
            ownerAccountID: activeConversation?.ownerAccountID,
            systemPrompt: systemPrompt
        )
        let baseRuntimeLLM: any LLMProtocol
        let attemptObserver: @Sendable (ModelCallAttemptObservation) async -> Void = { [invocationCoordinator = deps.invocationCoordinator] observation in
            await invocationCoordinator.recordAttemptObservation(observation)
        }
        if substitutionCandidates.count > 1 {
            baseRuntimeLLM = RankedFallbackSubstitutionLLM(
                candidates: substitutionCandidates,
                logger: logger,
                attemptObserver: attemptObserver
            )
        } else if let first = substitutionCandidates.first {
            baseRuntimeLLM = first.llm
        } else {
            let rawBaseLLM = deps.llmFactory.makeBaseLLM(
                model: effectivePrimaryModel,
                providerBindings: providerBindings,
                conversationID: activeConversationID,
                ownerAccountID: activeConversation?.ownerAccountID,
                systemPrompt: systemPrompt,
                logger: logger,
                attemptObserver: attemptObserver
            )
            let lifecycleLLM = LifecycleReportingLLM(
                baseLLM: rawBaseLLM,
                modelID: effectivePrimaryModel.id,
                coordinator: deps.invocationCoordinator
            )
            let credentialKey = schedulerCredentialKey(for: providerBindings)
            baseRuntimeLLM = SchedulingLLM(
                baseLLM: lifecycleLLM,
                scheduler: deps.callScheduler,
                modelID: effectivePrimaryModel.id,
                conversationID: activeConversationID,
                credentialKey: credentialKey,
                coordinator: deps.invocationCoordinator
            )
        }
        let trackedLLM = ContextTrackingLLM(baseLLM: baseRuntimeLLM, onCompleteResponse: contextSnapshotSink)
        let llm = QueuedLLM(baseLLM: StatefulLLM(baseLLM: trackedLLM))
        let mcpManager = await installedStartup.mcpManagerForOrchestration()
        let a2aManager = await installedStartup.a2aManagerForOrchestration()
        let acpManager = await installedStartup.acpManagerForOrchestration()
        let toolManager = await buildToolManager(
            systemPrompt: systemPrompt,
            skillLoader: skillLoader,
            activeConversation: activeConversation
        )
        let configuredAssistantPersistenceMode: AssistantPersistenceMode = .stagedCommit
        logger?.debug(
            "[OrchestratorRuntimeService] buildOrchestrator assistantPersistenceMode=\(String(describing: configuredAssistantPersistenceMode)) conversationID=\(activeConversation?.id.uuidString ?? "nil") interactionMode=\(activeConversation?.interactionMode.rawValue ?? "nil")"
        )
        let config = OrchestratorConfig(
            streamingEnabled: true,
            mcpEnabled: mcpManager != nil,
            a2aIntegration: a2aManager != nil ? .registrationOnly : .disabled,
            acpIntegration: acpManager != nil ? .registrationOnly : .disabled,
            mcpConnectionTimeout: 30.0,
            toolCallTimeout: 5 * 60,
            maxTokens: effectivePrimaryModel.maxContextLength,
            temperature: nil,
            topP: nil,
            additionalParameters: await orchestratorAdditionalParameters(for: activeConversation),
            assistantPersistenceMode: configuredAssistantPersistenceMode,
            parallelToolDispatchEnabled: false,
            toolDispatchPolicyEvaluator: DefaultToolDispatchPolicyEvaluator(
                orchestratorParallelModeEnabled: false
            ),
            dispatchPlannerMode: orchestratorDispatchPlannerMode(deps.toolPolicy.dispatchPlannerMode),
            preDispatchPolicyEvaluator: preDispatchEvaluator,
            pendingToolTimeout: deps.toolPolicy.pendingToolTimeoutSeconds
        )
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: llm,
            config: config,
            mcpManager: mcpManager,
            a2aManager: a2aManager,
            acpManager: acpManager,
            toolManager: toolManager,
            logger: logger
        )
        return BuiltOrchestrator(
            orchestrator: orchestrator,
            queuedLLM: llm,
            conversationID: activeConversationID
        )
    }

    static func messageDeliveryMetadata(from conversation: ModelConversation?) -> MessageOutputDeliveryMetadata {
        guard let conversation,
              let trigger = TriggerHostConversationMetadata.triggerFromFingerprint(conversation.metadata) else {
            return MessageOutputDeliveryMetadata()
        }
        return MessageOutputDeliveryMetadata(
            originSurface: trigger.sourceMetadata["channel"] ?? trigger.source.rawValue,
            originSenderID: trigger.sourceMetadata["senderId"] ?? trigger.initiator.id,
            chatId: trigger.sourceMetadata["chatId"],
            threadId: trigger.sourceMetadata["threadId"]
        )
    }
}
