import CryptoKit
import EasyJSON
import Foundation
import Logging
import SwiftData
import SwiftAgentKit
import SwiftAgentKitMCP
import SwiftAgentKitA2A
import SwiftAgentKitACP
import SwiftAgentKitOrchestrator
import SwiftAgentKitSkills
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Thin session coordinator: selection mirror, injected service refs, domain bundle access.
///
/// Public contract: ``HarnessRuntimeSessionCoordinating`` + ``HarnessRuntimeSessionWiring``.
/// Behavior lives in colocated harness services (`AgentRuntimeSessionService`, `ContextProjectionService`,
/// `OrchestratorRuntimeService`, domain `*ServiceImpl`, etc.). REST/WebSocket clients use the Communication Layer.
public actor HarnessRuntimeSession {
    
    struct Configuration {
        var enableTools: Bool = true
        var enableAgents: Bool = true
        /// When true, tools marked as requiring escalation are eligible for model dispatch.
        var allowEscalatedTools: Bool = false
        /// Per-run pre-approvals used by Tool System hide-from-model policy.
        var preApprovedToolNames: Set<String> = []
        /// When set, ``saveMessage`` verifies the active transcript ends with this harness-visible message id before appending.
        var expectedPreviousTailHarnessMessageID: UUID? = nil
        /// Optional trust class for user input (SwiftAgentKit ``Message/inputTrustRaw`` / JSON `inputTrust`).
        var inputTrustRaw: String? = nil
        /// Optional resolved trust policy class supplied by the transport boundary.
        var resolvedInputTrustClass: TrustPolicyClass? = nil
        /// Ephemeral provenance reminder injected at turn head (not persisted in user message).
        var ephemeralSystemReminder: String? = nil
        /// Originating surface for elevated exec allowlist (e.g. cli, slack, discord).
        var originSurface: String? = nil
        /// Originating sender id on the surface.
        var originSenderID: String? = nil
    }

    typealias ToolAvailabilitySnapshot = RuntimeToolAvailabilitySnapshot
    typealias ToolTurnPolicySnapshot = RuntimeToolTurnPolicySnapshot
    
    /// Shared infrastructure bag for extracted harness services (Step 8 migration).
    internal let runtimeDependencies: ConversationRuntimeDependencies
    public let services: HarnessRuntimeSessionFactory.Services
    public var agentRuntimeSessionService: AgentRuntimeSessionService { services.agentRuntimeSessionService }
    internal var contextProjectionService: ContextProjectionService { services.contextProjectionService }
    internal var toolApprovalRuntimeService: ToolApprovalRuntimeService { services.toolApprovalRuntimeService }
    internal var skillActivationService: SkillActivationService { services.skillActivationService }
    internal var slashCommandDispatchService: SlashCommandDispatchService { services.slashCommandDispatchService }
    public var subAgentSpawnService: SubAgentSpawnService { services.subAgentSpawnService }
    public var subAgentCompletionRuntimeService: SubAgentCompletionRuntimeService { services.subAgentCompletionRuntimeService }
    internal var runtimeLifecyclePublicationService: RuntimeLifecyclePublicationService { services.runtimeLifecyclePublicationService }
    public var conversationStartupService: ConversationStartupService { services.conversationStartupService }

    public func setMCPManager(_ mcpManager: MCPManager) async {
        await conversationStartupService.setMCPManager(mcpManager)
    }

    public func setResourceManager(_ resourceManager: ResourceManager) async {
        await conversationStartupService.setResourceManager(resourceManager)
    }

    public func setA2AManager(_ a2aManager: A2AManager) async {
        await conversationStartupService.setA2AManager(a2aManager)
    }

    public var orchestratorRuntimeService: OrchestratorRuntimeService { services.orchestratorRuntimeService }

    public func setACPManager(_ acpManager: ACPManager, delegateBoxes: [String: SubAgentACPClientDelegateBox]) async {
        await conversationStartupService.setACPManager(acpManager, delegateBoxes: delegateBoxes)
    }

    internal var conversationMessagingRuntimeService: ConversationMessagingRuntimeService { services.conversationMessagingRuntimeService }
    public var orchestratorSessionRuntimeService: OrchestratorSessionRuntimeService { services.orchestratorSessionRuntimeService }
    var conversationTopicPublicationRuntimeService: ConversationTopicPublicationRuntimeService {
        services.conversationTopicPublicationRuntimeService
    }
    public var conversationReplayService: ConversationReplayService { services.conversationReplayService }
    var conversationToolDataService: ConversationToolDataService { services.conversationToolDataService }
    var conversationToolModePolicyRuntimeService: ConversationToolModePolicyRuntimeService { services.conversationToolModePolicyRuntimeService }
    private var subAgentPool: any SubAgentPooling { services.subAgentPool }

    /// Conversation-plane persistence (**Strategy A** — ``ConversationPersistenceDomain``).
    internal let persistenceDomain: ConversationPersistenceDomain
    var conversationDomainServices: ConversationDomainServiceBundle { services.conversationDomainServices }
    /// Optional fan-out for `conversation/{id}/events` checkpoint envelopes (wired from ``CommunicationLayer`` at startup).
    internal var conversationTopicPublisher: (any ConversationTopicPublishing)?
    /// Optional fan-out for `subagent/{conversationId}/{path}/{events|state}` lifecycle publications.
    internal var subAgentLifecyclePublisher: (any SubAgentPoolResourceTopicPublishing)?
    private let compactionCoordinator: CompactionConcurrencyCoordinator
    /// Projection-input construction + assemble-request shaping for **`ContextEngine`** (see **`CONTEXT_ASSEMBLY_BOUNDARY`**).
    private let contextAssemblyRuntime: ContextAssemblyRuntimeFacade
    let runtimeLaneCoordinator: RuntimeLaneCoordinator
    public let contextEngine: any ContextEngine

    var currentConversationID: UUID? {
        get async { await services.conversationSelectionRuntimeService.currentConversationID }
    }

    var currentMessages: [Message] {
        get async { await services.conversationSelectionRuntimeService.currentMessages }
    }

    var conversationSelectionRuntimeService: ConversationSelectionRuntimeService {
        services.conversationSelectionRuntimeService
    }

    var sessionProjectionRuntimeService: SessionProjectionRuntimeService {
        services.sessionProjectionRuntimeService
    }
    
    init(
        logger: Logger? = nil,
        dataStoreURL: URL? = nil,
        allowsSwiftDataSave: Bool = true,
        trustPolicyConfiguration: TrustPolicyConfiguration? = nil,
        llmFactory: (any ModelLLMFactoring)? = nil,
        registryEntryProvider: (@Sendable (UUID) async -> ModelRegistryEntry?)? = nil,
        rankedRegistryEntriesProvider: (@Sendable (ModelReference) async -> [ModelRegistryEntry])? = nil,
        delegateCostTracker: (any DelegateCostTracking)? = nil,
        callScheduler: any ModelCallScheduling = ModelCallScheduler(),
        invocationCoordinator: any ModelInvocationLifecycleTracking = ModelInvocationCoordinator(),
        runtimeExecutorFactory: @escaping AgentRuntimeExecutorFactory = AgentRuntimeExecutorFactories.defaultInternal,
        contextEngineSlotID: String = "default",
        runtimeLaneConfiguration: RuntimeLaneConfiguration = .default,
        compactionProviderFactory: (any ContextCompactionProviderFactoring)? = nil,
        modeRegistry: any ModeRegistryAccessing = ModeRegistryPortAdapter(service: ModeRegistryService())
    ) {
        let (resolvedFactory, resolvedTracker) = ModelPoolRuntimeWiring.resolve(
            llmFactory: llmFactory,
            delegateCostTracker: delegateCostTracker,
            logger: logger
        )
        let transformConfig = ConversationTransformConfiguration.loadFromPromptConfigBundle(logger: logger)
        let resolvedTrustPolicy = trustPolicyConfiguration
            ?? TrustPolicyConfiguration.loadFromPromptConfigBundle(logger: logger)
        let persistenceDomain = ConversationPersistenceDomain.makeProduction(
            logger: logger,
            dataStoreURL: dataStoreURL,
            allowsSwiftDataSave: allowsSwiftDataSave
        )
        let compactionCoordinator = CompactionConcurrencyCoordinator()
        let resolvedContextEngine = ContextEngineSlotResolver.resolve(
            slotID: contextEngineSlotID,
            compactionCoordinator: compactionCoordinator,
            logger: logger
        )
        let compactionScheduling = ContextCompactionLLMScheduling(
            scheduler: callScheduler,
            modelID: ContextCompactionLLMScheduling.modelID(
                model: transformConfig.contextCompaction.model,
                ollamaServerURL: transformConfig.contextCompaction.ollamaServerURL
            )
        )
        self.init(
            persistenceDomain: persistenceDomain,
            logger: logger,
            toolPolicy: ToolPolicyConfiguration.loadFromPromptConfigBundle(logger: logger),
            trustPolicyConfiguration: resolvedTrustPolicy,
            agentHarness: AgentHarnessConfiguration.loadFromPromptConfigBundle(logger: logger),
            thinkingPolicyConfiguration: ThinkingPolicyConfiguration.loadFromPromptConfigBundle(logger: logger),
            conversationTransformConfiguration: transformConfig,
            conversationTransformer: ContextCompactionTransformer.makeProduction(
                config: transformConfig.contextCompaction,
                toolResultFormattingConfiguration: transformConfig.toolResultFormatting,
                logger: logger,
                providerFactory: compactionProviderFactory,
                scheduling: compactionScheduling
            ),
            llmFactory: resolvedFactory,
            registryEntryProvider: registryEntryProvider,
            rankedRegistryEntriesProvider: rankedRegistryEntriesProvider,
            delegateCostTracker: resolvedTracker,
            callScheduler: callScheduler,
            invocationCoordinator: invocationCoordinator,
            compactionCoordinator: compactionCoordinator,
            contextEngine: resolvedContextEngine,
            modeRegistry: modeRegistry,
            runtimeLaneConfiguration: runtimeLaneConfiguration,
            runtimeExecutorFactory: runtimeExecutorFactory
        )
    }

    public static func makeProduction(
        persistenceDomain: ConversationPersistenceDomain,
        logger: Logger?,
        toolPolicy: ToolPolicyConfiguration,
        trustPolicyConfiguration: TrustPolicyConfiguration,
        agentHarness: AgentHarnessConfiguration,
        thinkingPolicyConfiguration: ThinkingPolicyConfiguration,
        conversationTransformConfiguration: ConversationTransformConfiguration,
        conversationTransformer: any ConversationTransforming,
        llmFactory: any ModelLLMFactoring,
        registryEntryProvider: (@Sendable (UUID) async -> ModelRegistryEntry?)?,
        rankedRegistryEntriesProvider: (@Sendable (ModelReference) async -> [ModelRegistryEntry])?,
        delegateCostTracker: (any DelegateCostTracking)?,
        callScheduler: any ModelCallScheduling,
        invocationCoordinator: any ModelInvocationLifecycleTracking,
        compactionCoordinator: CompactionConcurrencyCoordinator,
        contextEngine: any ContextEngine,
        modeRegistry: any ModeRegistryAccessing,
        runtimeLaneConfiguration: RuntimeLaneConfiguration = .default
    ) -> (session: HarnessRuntimeSession, services: HarnessRuntimeSessionFactory.Services) {
        makeProduction(
            persistenceDomain: persistenceDomain,
            logger: logger,
            toolPolicy: toolPolicy,
            trustPolicyConfiguration: trustPolicyConfiguration,
            agentHarness: agentHarness,
            thinkingPolicyConfiguration: thinkingPolicyConfiguration,
            conversationTransformConfiguration: conversationTransformConfiguration,
            conversationTransformer: conversationTransformer,
            llmFactory: llmFactory,
            registryEntryProvider: registryEntryProvider,
            rankedRegistryEntriesProvider: rankedRegistryEntriesProvider,
            delegateCostTracker: delegateCostTracker,
            callScheduler: callScheduler,
            invocationCoordinator: invocationCoordinator,
            compactionCoordinator: compactionCoordinator,
            contextEngine: contextEngine,
            modeRegistry: modeRegistry,
            runtimeLaneConfiguration: runtimeLaneConfiguration,
            runtimeExecutorFactory: AgentRuntimeExecutorFactories.defaultInternal
        )
    }

    static func makeProduction(
        persistenceDomain: ConversationPersistenceDomain,
        logger: Logger?,
        toolPolicy: ToolPolicyConfiguration,
        trustPolicyConfiguration: TrustPolicyConfiguration,
        agentHarness: AgentHarnessConfiguration,
        thinkingPolicyConfiguration: ThinkingPolicyConfiguration,
        conversationTransformConfiguration: ConversationTransformConfiguration,
        conversationTransformer: any ConversationTransforming,
        llmFactory: any ModelLLMFactoring,
        registryEntryProvider: (@Sendable (UUID) async -> ModelRegistryEntry?)?,
        rankedRegistryEntriesProvider: (@Sendable (ModelReference) async -> [ModelRegistryEntry])?,
        delegateCostTracker: (any DelegateCostTracking)?,
        callScheduler: any ModelCallScheduling,
        invocationCoordinator: any ModelInvocationLifecycleTracking,
        compactionCoordinator: CompactionConcurrencyCoordinator,
        contextEngine: any ContextEngine,
        modeRegistry: any ModeRegistryAccessing,
        runtimeLaneConfiguration: RuntimeLaneConfiguration,
        runtimeExecutorFactory: @escaping AgentRuntimeExecutorFactory
    ) -> (session: HarnessRuntimeSession, services: HarnessRuntimeSessionFactory.Services) {
        let contextAssemblyRuntime = ContextAssemblyRuntimeFacade(
            persistenceDomain: persistenceDomain,
            conversationTransformConfiguration: conversationTransformConfiguration
        )
        let runtimeLaneCoordinator = RuntimeLaneCoordinator(configuration: runtimeLaneConfiguration)
        let alignedFactory = StandardModelLLMFactory.aligningAccounting(
            factory: llmFactory,
            delegateCostTracker: delegateCostTracker
        )
        let runtimeDependencies = ConversationRuntimeDependencies(
            persistenceDomain: persistenceDomain,
            compactionCoordinator: compactionCoordinator,
            contextEngine: contextEngine,
            contextAssemblyRuntime: contextAssemblyRuntime,
            modeRegistry: modeRegistry,
            llmFactory: alignedFactory,
            callScheduler: callScheduler,
            invocationCoordinator: invocationCoordinator,
            runtimeLaneCoordinator: runtimeLaneCoordinator,
            toolPolicy: toolPolicy,
            trustPolicyConfiguration: trustPolicyConfiguration,
            agentHarness: agentHarness,
            thinkingPolicyConfiguration: thinkingPolicyConfiguration,
            conversationTransformConfiguration: conversationTransformConfiguration,
            conversationTransformer: conversationTransformer,
            registryEntryProvider: registryEntryProvider,
            rankedRegistryEntriesProvider: rankedRegistryEntriesProvider,
            delegateCostTracker: delegateCostTracker,
            runtimeExecutorFactory: runtimeExecutorFactory,
            logger: logger
        )
        let (session, services) = HarnessRuntimeSessionFactory.makeSession(
            persistenceDomain: persistenceDomain,
            runtimeDependencies: runtimeDependencies,
            logger: logger,
            toolPolicy: toolPolicy,
            trustPolicyConfiguration: trustPolicyConfiguration,
            agentHarness: agentHarness,
            thinkingPolicyConfiguration: thinkingPolicyConfiguration,
            conversationTransformConfiguration: conversationTransformConfiguration,
            conversationTransformer: conversationTransformer,
            llmFactory: alignedFactory,
            registryEntryProvider: registryEntryProvider,
            rankedRegistryEntriesProvider: rankedRegistryEntriesProvider,
            delegateCostTracker: delegateCostTracker,
            callScheduler: callScheduler,
            invocationCoordinator: invocationCoordinator,
            compactionCoordinator: compactionCoordinator,
            contextEngine: contextEngine,
            runtimeExecutorFactory: runtimeExecutorFactory,
            wireMemorySubAgents: true
        )
        return (session, services)
    }

    /// Designated initializer: persistence domain is built at the composition root or via ``ConversationPersistenceDomain/makeForTesting(container:logger:derivedEventStore:)``.
    init(
        persistenceDomain: ConversationPersistenceDomain,
        logger: Logger?,
        toolPolicy: ToolPolicyConfiguration,
        trustPolicyConfiguration: TrustPolicyConfiguration = .disabled,
        agentHarness: AgentHarnessConfiguration,
        thinkingPolicyConfiguration: ThinkingPolicyConfiguration = .default,
        conversationTransformConfiguration: ConversationTransformConfiguration,
        conversationTransformer: any ConversationTransforming,
        llmFactory: any ModelLLMFactoring,
        registryEntryProvider: (@Sendable (UUID) async -> ModelRegistryEntry?)? = nil,
        rankedRegistryEntriesProvider: (@Sendable (ModelReference) async -> [ModelRegistryEntry])? = nil,
        delegateCostTracker: (any DelegateCostTracking)? = nil,
        callScheduler: any ModelCallScheduling,
        invocationCoordinator: any ModelInvocationLifecycleTracking,
        compactionCoordinator: CompactionConcurrencyCoordinator,
        contextEngine: (any ContextEngine)?,
        modeRegistry: any ModeRegistryAccessing = ModeRegistryPortAdapter(service: ModeRegistryService()),
        runtimeLaneConfiguration: RuntimeLaneConfiguration = .default,
        runtimeExecutorFactory: @escaping AgentRuntimeExecutorFactory = AgentRuntimeExecutorFactories.defaultInternal
    ) {
        let alignedFactory = StandardModelLLMFactory.aligningAccounting(
            factory: llmFactory,
            delegateCostTracker: delegateCostTracker
        )
        let contextAssemblyRuntime = ContextAssemblyRuntimeFacade(
            persistenceDomain: persistenceDomain,
            conversationTransformConfiguration: conversationTransformConfiguration
        )
        let runtimeLaneCoordinator = RuntimeLaneCoordinator(configuration: runtimeLaneConfiguration)
        let memoryConfig = MemoryConfigurationLoader.loadFromPromptConfigBundle(logger: logger)
        let memoryRecallSelector = ModelPoolMemoryLLMRecallSelector(
            scheduler: callScheduler,
            modelName: memoryConfig.recallSelectorModel,
            serverURL: memoryConfig.recallSelectorOllamaServerURL,
            logger: logger
        )
        let memoryService = DefaultMemoryService(
            config: memoryConfig,
            logger: logger,
            llmRecallSelector: memoryRecallSelector
        )
        let resolvedContextEngine = contextEngine ?? DefaultContextEngine(
            compactionCoordinator: compactionCoordinator,
            memoryService: memoryService,
            logger: logger
        )
        let runtimeDependencies = ConversationRuntimeDependencies(
            persistenceDomain: persistenceDomain,
            compactionCoordinator: compactionCoordinator,
            contextEngine: resolvedContextEngine,
            contextAssemblyRuntime: contextAssemblyRuntime,
            modeRegistry: modeRegistry,
            llmFactory: alignedFactory,
            callScheduler: callScheduler,
            invocationCoordinator: invocationCoordinator,
            runtimeLaneCoordinator: runtimeLaneCoordinator,
            toolPolicy: toolPolicy,
            trustPolicyConfiguration: trustPolicyConfiguration,
            agentHarness: agentHarness,
            thinkingPolicyConfiguration: thinkingPolicyConfiguration,
            conversationTransformConfiguration: conversationTransformConfiguration,
            conversationTransformer: conversationTransformer,
            registryEntryProvider: registryEntryProvider,
            rankedRegistryEntriesProvider: rankedRegistryEntriesProvider,
            delegateCostTracker: delegateCostTracker,
            runtimeExecutorFactory: runtimeExecutorFactory,
            logger: logger
        )
        let services = HarnessRuntimeSessionFactory.makeServices(
            deps: runtimeDependencies,
            persistenceDomain: persistenceDomain
        )
        self.init(
            persistenceDomain: persistenceDomain,
            runtimeDependencies: runtimeDependencies,
            services: services,
            logger: logger,
            toolPolicy: toolPolicy,
            trustPolicyConfiguration: trustPolicyConfiguration,
            agentHarness: agentHarness,
            thinkingPolicyConfiguration: thinkingPolicyConfiguration,
            conversationTransformConfiguration: conversationTransformConfiguration,
            conversationTransformer: conversationTransformer,
            llmFactory: alignedFactory,
            registryEntryProvider: registryEntryProvider,
            rankedRegistryEntriesProvider: rankedRegistryEntriesProvider,
            delegateCostTracker: delegateCostTracker,
            callScheduler: callScheduler,
            invocationCoordinator: invocationCoordinator,
            compactionCoordinator: compactionCoordinator,
            contextEngine: resolvedContextEngine,
            runtimeExecutorFactory: runtimeExecutorFactory
        )
    }

    init(
        persistenceDomain: ConversationPersistenceDomain,
        runtimeDependencies: ConversationRuntimeDependencies,
        services: HarnessRuntimeSessionFactory.Services,
        logger: Logger?,
        toolPolicy: ToolPolicyConfiguration,
        trustPolicyConfiguration: TrustPolicyConfiguration,
        agentHarness: AgentHarnessConfiguration,
        thinkingPolicyConfiguration: ThinkingPolicyConfiguration,
        conversationTransformConfiguration: ConversationTransformConfiguration,
        conversationTransformer: any ConversationTransforming,
        llmFactory: any ModelLLMFactoring,
        registryEntryProvider: (@Sendable (UUID) async -> ModelRegistryEntry?)?,
        rankedRegistryEntriesProvider: (@Sendable (ModelReference) async -> [ModelRegistryEntry])?,
        delegateCostTracker: (any DelegateCostTracking)?,
        callScheduler: any ModelCallScheduling,
        invocationCoordinator: any ModelInvocationLifecycleTracking,
        compactionCoordinator: CompactionConcurrencyCoordinator,
        contextEngine: any ContextEngine,
        runtimeExecutorFactory: @escaping AgentRuntimeExecutorFactory
    ) {
        self.logger = logger
        self.llmFactory = llmFactory
        self.registryEntryProvider = registryEntryProvider
        self.rankedRegistryEntriesProvider = rankedRegistryEntriesProvider
        self.callScheduler = callScheduler
        self.invocationCoordinator = invocationCoordinator
        self.persistenceDomain = persistenceDomain
        self.toolPolicy = toolPolicy
        self.trustPolicyConfiguration = trustPolicyConfiguration
        self.agentHarness = agentHarness
        self.thinkingPolicyConfiguration = thinkingPolicyConfiguration
        self.conversationTransformConfiguration = conversationTransformConfiguration
        self.conversationTransformer = conversationTransformer
        self.compactionCoordinator = compactionCoordinator
        self.contextAssemblyRuntime = runtimeDependencies.contextAssemblyRuntime
        self.runtimeLaneCoordinator = runtimeDependencies.runtimeLaneCoordinator
        self.contextEngine = contextEngine
        self.runtimeExecutorFactory = runtimeExecutorFactory
        self.delegateCostTracker = delegateCostTracker
        self.runtimeDependencies = runtimeDependencies
        self.services = services
    }

    /// Initializer for testing with an in-memory container.
    init(
        container: ModelContainer,
        logger: Logger? = nil,
        toolPolicy: ToolPolicyConfiguration = .unrestricted,
        trustPolicyConfiguration: TrustPolicyConfiguration = .disabled,
        agentHarness: AgentHarnessConfiguration = .default,
        thinkingPolicyConfiguration: ThinkingPolicyConfiguration = .default,
        conversationTransformConfiguration: ConversationTransformConfiguration = .default,
        conversationTransformer: any ConversationTransforming = NoOpConversationTransformer(),
        llmFactory: any ModelLLMFactoring = StandardModelLLMFactory(accounting: AlwaysAllowBudgetAccounting()),
        registryEntryProvider: (@Sendable (UUID) async -> ModelRegistryEntry?)? = nil,
        rankedRegistryEntriesProvider: (@Sendable (ModelReference) async -> [ModelRegistryEntry])? = nil,
        delegateCostTracker: (any DelegateCostTracking)? = nil,
        callScheduler: any ModelCallScheduling = ModelCallScheduler(),
        invocationCoordinator: any ModelInvocationLifecycleTracking = ModelInvocationCoordinator(),
        compactionCoordinator: CompactionConcurrencyCoordinator = CompactionConcurrencyCoordinator(),
        contextEngine: (any ContextEngine)? = nil,
        derivedEventStore: (any DerivedEventStore)? = nil,
        harnessSessionPersistenceOverride: (any HarnessSessionPersistence)? = nil,
        modeRegistry: any ModeRegistryAccessing = ModeRegistryPortAdapter(service: ModeRegistryService()),
        runtimeLaneConfiguration: RuntimeLaneConfiguration = .default,
        runtimeExecutorFactory: @escaping AgentRuntimeExecutorFactory = AgentRuntimeExecutorFactories.defaultInternal
    ) {
        let stack = ConversationPersistenceStack.makeForTesting(
            container: container,
            logger: logger,
            derivedEventStore: derivedEventStore,
            harnessSessionPersistenceOverride: harnessSessionPersistenceOverride
        )
        let domain = ConversationPersistenceDomain(stack: stack)
        self.init(
            persistenceDomain: domain,
            logger: logger,
            toolPolicy: toolPolicy,
            trustPolicyConfiguration: trustPolicyConfiguration,
            agentHarness: agentHarness,
            thinkingPolicyConfiguration: thinkingPolicyConfiguration,
            conversationTransformConfiguration: conversationTransformConfiguration,
            conversationTransformer: conversationTransformer,
            llmFactory: llmFactory,
            registryEntryProvider: registryEntryProvider,
            rankedRegistryEntriesProvider: rankedRegistryEntriesProvider,
            delegateCostTracker: delegateCostTracker,
            callScheduler: callScheduler,
            invocationCoordinator: invocationCoordinator,
            compactionCoordinator: compactionCoordinator,
            contextEngine: contextEngine,
            modeRegistry: modeRegistry,
            runtimeLaneConfiguration: runtimeLaneConfiguration,
            runtimeExecutorFactory: runtimeExecutorFactory
        )
    }

    // MARK: Setup
    
    public func resetConversationsFromCatalog(availableModels: [Model]) async throws {
        try await conversationStartupService.resetConversationsFromCatalog(availableModels: availableModels)
    }
    
    public func setConversationTopicPublisher(_ publisher: (any ConversationTopicPublishing)?) async {
        conversationTopicPublisher = publisher
        await conversationStartupService.setConversationTopicPublisher(publisher)
        await runtimeLifecyclePublicationService.setConversationTopicPublisher(publisher)
    }

    public func setTraceTopicPublisher(_ publisher: (any TraceTopicPublishing)?) async {
        await runtimeLifecyclePublicationService.setTraceTopicPublisher(publisher)
    }

    public func setSubAgentLifecyclePublisher(_ publisher: (any SubAgentPoolResourceTopicPublishing)?) {
        subAgentLifecyclePublisher = publisher
    }

    public func setActivePolicy(_ policy: BudgetPolicy) async {
        await delegateCostTracker?.setActivePolicy(policy)
    }

    public func drainPendingWork(timeoutMs: Int) async {
        guard let defaultEngine = contextEngine as? DefaultContextEngine,
              let memoryService = defaultEngine.memoryService else {
            return
        }
        await memoryService.drainPendingWork(timeoutMs: timeoutMs)
    }

    internal func setDelegateCostTracker(_ tracker: (any DelegateCostTracking)?) {
        delegateCostTracker = tracker
    }

    public func refreshTranscriptIntegrityFlagsAfterMaintenance(report: SessionTranscriptIntegrityReport) async {
        await conversationStartupService.refreshTranscriptIntegrityFlagsAfterMaintenance(report: report)
    }

    public func shutdown() async {
        if let defaultEngine = contextEngine as? DefaultContextEngine,
           let memoryService = defaultEngine.memoryService {
            await memoryService.shutdown()
        }
        await conversationStartupService.shutdown(
            agentRuntime: agentRuntimeSessionService,
            conversationReplay: conversationReplayService,
            orchestratorRuntime: orchestratorRuntimeService
        )
    }

    /// Stops MCP stdio subprocesses and A2A boot processes via ``SwiftAgentKitOrchestrator/shutdown()`` when an orchestrator exists; otherwise shuts down managers directly.
    internal func shutdownOrchestratorAndToolRuntimes() async {
        await conversationStartupService.shutdownOrchestratorAndToolRuntimes(
            agentRuntime: agentRuntimeSessionService,
            conversationReplay: conversationReplayService,
            orchestratorRuntime: orchestratorRuntimeService
        )
    }
    
    // MARK: Conversations

    func currentConversation() async -> ModelConversation? {
        await services.conversationSelectionRuntimeService.currentConversation()
    }

    func selectConversation(conversationID: UUID) async throws {
        try await services.conversationSelectionRuntimeService.selectConversation(conversationID: conversationID)
    }

    internal func configurationApplyingTrustPolicy(_ configuration: Configuration) async -> Configuration {
        await services.conversationSelectionRuntimeService.configurationApplyingTrustPolicy(configuration)
    }

    internal func projectedMessages(for conversation: ModelConversation) async -> [Message] {
        await services.sessionProjectionRuntimeService.projectedMessages(for: conversation)
    }

    internal func syncSessionProjectionFromRegistry(conversationID: UUID, convo: ModelConversation) async {
        await services.sessionProjectionRuntimeService.syncFromRegistry(conversationID: conversationID, conversation: convo)
    }

    internal func runtimeSessionLaneKey(conversationID: UUID) async -> String {
        await services.conversationSelectionRuntimeService.runtimeSessionLaneKey(conversationID: conversationID)
    }

    internal func runtimeSessionError(
        for admissionError: RuntimeLaneAdmissionError,
        conversationID: UUID,
        fallbackRunID: UUID,
        activeRuntimeRunIDOverride: UUID? = nil
    ) async -> ConversationServiceError {
        await services.conversationSelectionRuntimeService.runtimeSessionError(
            for: admissionError,
            conversationID: conversationID,
            fallbackRunID: fallbackRunID,
            activeRuntimeRunIDOverride: activeRuntimeRunIDOverride
        )
    }

    /// Raw `plan.md` for the conversation, or empty string if the file is missing (used by REST plan viewer).
    internal func readPlanMarkdown(for conversationID: UUID) async throws -> String {
        try await persistenceDomain.readPlanMarkdown(for: conversationID)
    }

    public func serviceHarnessDedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool {
        try await persistenceDomain.dedupeCheckAndSet(key: key, ttlSeconds: ttlSeconds)
    }

    public func serviceHarnessDedupePeek(key: String) async throws -> Bool {
        try await persistenceDomain.dedupePeek(key: key)
    }

    internal func serviceHarnessAppendTaskRun(jobId: String, payload: Data, idempotencyKey: String?) async throws -> UUID {
        try await persistenceDomain.appendTaskRun(jobId: jobId, payload: payload, idempotencyKey: idempotencyKey)
    }

    internal func serviceHarnessLatestUndeliveredTaskRun(jobId: String) async throws -> SessionHarnessTaskRunRecord? {
        try await persistenceDomain.latestUndeliveredTaskRun(jobId: jobId)
    }

    internal func serviceHarnessMarkTaskRunDelivered(runId: UUID) async throws {
        try await persistenceDomain.markTaskRunDelivered(runId: runId)
    }

    public func serviceResolveConversationByTitle(_ title: String) async throws -> UUID? {
        try await persistenceDomain.resolveConversationByTitle(title)
    }

    internal func serviceRuntimeMessageStream(for conversationID: UUID?) async throws -> AsyncStream<[Message]> {
        try await agentRuntimeSessionService.serviceRuntimeMessageStream(for: conversationID)
    }

    internal func messageStream(for conversationID: UUID? = nil) async throws -> AsyncStream<[Message]> {
        try await agentRuntimeSessionService.messageStream(for: conversationID)
    }

    internal func cancelMessageStream() async {
        await agentRuntimeSessionService.cancelMessageStream()
    }

    public func createConversation(
        with selectedModel: Model,
        userSystemPrompt: String,
        topic: String? = nil,
        description: String? = nil,
        metadata: JSON? = nil,
        interactionMode: InteractionMode = .chat,
        modeProfileID: String? = nil,
        cwd: String? = nil,
        lineageKind: ConversationLineageKind = .root,
        origin: ConversationOrigin = .user
    ) async throws -> UUID {
        try await conversationDomainServices.controlPlane.createConversation(
            with: selectedModel,
            userSystemPrompt: userSystemPrompt,
            topic: topic,
            description: description,
            metadata: metadata,
            interactionMode: interactionMode,
            modeProfileID: modeProfileID,
            cwd: cwd,
            lineageKind: lineageKind,
            origin: origin
        )
    }

    public func stampTriggerHostConversation(
        conversationID: UUID,
        trigger: HarnessTrigger,
        sessionKey: String
    ) async throws {
        try await persistenceDomain.stampTriggerHostConversation(
            conversationID: conversationID,
            trigger: trigger,
            sessionKey: sessionKey
        )
    }

    internal func generateFullSystemPrompt(conversationID: UUID?, withUserSystemPrompt userSystemPrompt: String?) async throws -> String {
        try await orchestratorSessionRuntimeService.generateFullSystemPrompt(
            conversationID: conversationID,
            withUserSystemPrompt: userSystemPrompt
        )
    }

    /// Copies a conversation to a new one with a different model and optionally a new system prompt.
    /// Useful for transferring read-only (unavailable model) conversations to an available model.
    internal func copyConversation(from sourceConversationID: UUID, to model: Model, systemPrompt: String) async throws -> UUID {
        try await conversationDomainServices.lifecycle.copyConversation(
            from: sourceConversationID,
            to: model,
            systemPrompt: systemPrompt
        )
    }

    /// Persists a split through the given user message (inclusive), appends the new in-memory conversation, and selects it.
    /// Does not cancel generation or start orchestration (used by tests).
    internal func persistSplitConversationSelectingNewThread(
        sourceConversationID: UUID,
        atUserMessageID messageID: UUID
    ) async throws -> (
        newConversationID: UUID,
        anchorNewUserMessageID: UUID
    ) {
        try await conversationDomainServices.lifecycle.persistSplitSelectingNewThread(
            sourceConversationID: sourceConversationID,
            atUserMessageID: messageID,
            adoptSelection: true
        )
    }

    /// Control-plane branch for REST (`POST …/branch`): split then leave the fork selected without starting LLM streaming.
    internal func branchConversationAtUserMessageControlPlane(conversationID: UUID, userMessageID: UUID) async throws -> UUID {
        logger?.info("[HarnessRuntimeSession] branchConversationAtUserMessageControlPlane start conversationID=\(conversationID) anchorMessageID=\(userMessageID)")
        let newID = try await conversationDomainServices.lifecycle.branchConversation(
            conversationID: conversationID,
            userMessageID: userMessageID,
            selectionBehavior: .adoptChild
        )
        logger?.info("[HarnessRuntimeSession] branchConversationAtUserMessageControlPlane complete sourceConversationID=\(conversationID) childConversationID=\(newID)")
        return newID
    }

    internal func invalidateConversationCheckpointsForAPI(conversationID: UUID, kinds: [String]) async throws {
        try await conversationDomainServices.lifecycle.invalidateConversationCheckpoints(
            conversationID: conversationID,
            kinds: kinds
        )
    }

    /// Creates a new conversation with messages from the current thread through the given **user** message (inclusive),
    /// records split lineage on the new conversation, selects it, and starts the same streaming orchestration as revert.
    internal func splitConversationAtUserMessage(
        conversationID: UUID,
        messageID: UUID,
        configuration: Configuration = .init()
    ) async throws -> ChatStreamResponse {
        try await agentRuntimeSessionService.splitConversationAtUserMessage(
            conversationID: conversationID,
            messageID: messageID,
            configuration: configuration
        )
    }

    internal func updateConversationMetadata(conversationID: UUID, topic: String?, description: String?, metadata: JSON? = nil, interactionMode: InteractionMode? = nil, modeProfileID: String? = nil, interactionModeChangeInitiator: String? = nil, interactionModeChangeReason: String? = nil, skipControlPlaneRevisionBump: Bool = false) async throws {
        try await conversationDomainServices.controlPlane.updateConversationMetadata(
            conversationID: conversationID,
            topic: topic,
            description: description,
            metadata: metadata,
            interactionMode: interactionMode,
            modeProfileID: modeProfileID,
            interactionModeChangeInitiator: interactionModeChangeInitiator,
            interactionModeChangeReason: interactionModeChangeReason,
            skipControlPlaneRevisionBump: skipControlPlaneRevisionBump
        )
    }

    internal func updateConversationModelAndUserPrompt(conversationID: UUID, model: Model?, userSystemPrompt: String?, skipControlPlaneRevisionBump: Bool = false) async throws {
        try await conversationDomainServices.controlPlane.updateConversationModelAndUserPrompt(
            conversationID: conversationID,
            model: model,
            userSystemPrompt: userSystemPrompt
        )
    }

    internal func updateConversationRoutingToolPolicy(conversationID: UUID, policy: ConversationExplicitToolPolicy, skipControlPlaneRevisionBump _: Bool = false) async throws {
        guard let current = await persistenceDomain.modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        let patch = ConversationPatch(
            expectedRevision: current.controlPlaneRevision,
            routingToolPolicy: policy
        )
        try await conversationDomainServices.controlPlane.patchConversation(conversationID: conversationID, patch: patch)
    }

    internal func updateConversationThinkingConfig(conversationID: UUID, thinkingConfig: ThinkingConfig?, skipControlPlaneRevisionBump: Bool = false) async throws {
        try await conversationDomainServices.controlPlane.updateConversationThinkingConfig(
            conversationID: conversationID,
            thinkingConfig: thinkingConfig
        )
    }

    internal func updateConversationThinkingPreference(conversationID: UUID, thinkingEnabled: Bool, skipControlPlaneRevisionBump: Bool = false) async throws {
        let config: ThinkingConfig = thinkingEnabled ? .adaptive : .disabled
        try await updateConversationThinkingConfig(
            conversationID: conversationID,
            thinkingConfig: config,
            skipControlPlaneRevisionBump: skipControlPlaneRevisionBump
        )
    }

    internal func updateConversationReasoningEffort(conversationID: UUID, reasoningEffort: ConversationReasoningEffort, skipControlPlaneRevisionBump: Bool = false) async throws {
        let config: ThinkingConfig
        switch reasoningEffort {
        case .none:
            config = .level(.off, budgetTokens: nil)
        case .minimal:
            config = .level(.minimal, budgetTokens: nil)
        case .low:
            config = .level(.low, budgetTokens: nil)
        case .medium:
            config = .level(.medium, budgetTokens: nil)
        case .high:
            config = .level(.high, budgetTokens: nil)
        }
        try await updateConversationThinkingConfig(
            conversationID: conversationID,
            thinkingConfig: config,
            skipControlPlaneRevisionBump: skipControlPlaneRevisionBump
        )
    }

    /// REST `PATCH` path: model/prompt resolution + one revision check and one control-plane bump (see ``apiApplyConversationRESTPatch``).
    internal func applyConversationPatchFromREST(conversationID: UUID, patch: ConversationPatch, resolvedModel: Model?) async throws -> UInt64 {
        try await conversationDomainServices.controlPlane.applyConversationRESTPatch(
            conversationID: conversationID,
            patch: patch,
            resolvedModel: resolvedModel
        )
    }

    internal func consumeTimedOutToolApprovalsForRuntime(
        conversationID: UUID,
        runID: UUID?,
        iteration: Int?,
        modelID: UUID?,
        lifecycleEmitter: AgentRuntimeLifecycleEmitter
    ) async {
        await toolApprovalRuntimeService.consumeTimedOutToolApprovalsForRuntime(
            conversationID: conversationID,
            runID: runID,
            iteration: iteration,
            modelID: modelID,
            lifecycleEmitter: lifecycleEmitter
        )
    }

    internal func applyToolApprovalResolution(
        conversationID: UUID,
        runID: UUID?,
        toolName: String,
        route: ToolApprovalRoute,
        status: ToolApprovalResolutionStatus,
        source: String,
        reason: String?,
        kind: ToolApprovalResolutionKind,
        policyReason: String,
        publicationSource: String,
        iteration: Int? = nil,
        modelID: UUID? = nil,
        approvalSpec: ToolApprovalContractSpec? = nil,
        lifecycleEmitter: AgentRuntimeLifecycleEmitter? = nil
    ) async {
        await toolApprovalRuntimeService.applyToolApprovalResolution(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            route: route,
            status: status,
            source: source,
            reason: reason,
            kind: kind,
            policyReason: policyReason,
            publicationSource: publicationSource,
            iteration: iteration,
            modelID: modelID,
            approvalSpec: approvalSpec,
            lifecycleEmitter: lifecycleEmitter
        )
    }

    internal func applySubAgentTransportPermissionResolutionIfNeeded(
        conversationID: UUID,
        toolName: String,
        route: ToolApprovalRoute,
        status: ToolApprovalResolutionStatus,
        source: String
    ) async {
        await subAgentSpawnService.applySubAgentTransportPermissionResolutionIfNeeded(
            conversationID: conversationID,
            toolName: toolName,
            route: route,
            status: status,
            source: source
        )
    }

    internal func approvalRouteForConversation(conversationID: UUID) async -> ToolApprovalRoute {
        if let conversation = await persistenceDomain.modelConversation(id: conversationID),
           conversation.parentConversationID != nil {
            return .parent
        }
        return .user
    }

    internal func contextMessagesApplyingTrustPolicy(_ messages: [Message], configuration: Configuration?) async -> [Message] {
        guard let configuration else { return messages }
        let effective = await configurationApplyingTrustPolicy(configuration)
        guard let trustClass = effective.resolvedInputTrustClass,
              trustPolicyConfiguration.shouldDowngradeContext(for: trustClass)
        else {
            return messages
        }
        guard let lastID = messages.last?.id else { return messages }
        // Keep the active user input while dropping older low-trust user turns from context.
        return messages.filter { message in
            guard message.role == .user, message.id != lastID else { return true }
            let klass = MessageInputTrustCodec.safePolicyClass(
                raw: message.inputTrustRaw,
                unknownFallback: trustPolicyConfiguration.safeDefaultClass
            )
            return klass != .lowTrust
        }
    }

    internal func spawnSubAgentViaPool(
        parentConversationID: UUID,
        request: SubAgentSpawnRequest,
        modelOverride: Model?,
        bypassDelegateAllowList: Bool = false
    ) async throws -> UUID {
        try await subAgentSpawnService.spawnSubAgentViaPool(
            parentConversationID: parentConversationID,
            request: request,
            modelOverride: modelOverride,
            bypassDelegateAllowList: bypassDelegateAllowList
        )
    }

    internal func deleteConversation(conversationID: UUID, hard: Bool = true) async throws {
        try await conversationDomainServices.lifecycle.deleteConversation(conversationID: conversationID, hard: hard)
    }

    /// Hard-deletes conversations in `.deleted` lifecycle whose ``updatedAt`` is before the retention cutoff.
    public func purgeSoftDeletedPastRetention(retentionDays: Int, now: Date = Date()) async throws -> Int {
        try await conversationStartupService.purgeSoftDeletedPastRetention(retentionDays: retentionDays, now: now)
    }

    /// Runs one bounded physical prune cycle for superseded derived artifacts/checkpoints.
    public func runDerivedArtifactRetentionSweep(
        policy: DerivedArtifactRetentionPolicy
    ) async throws -> DerivedArtifactRetentionSweepResult {
        try await conversationStartupService.runDerivedArtifactRetentionSweep(policy: policy)
    }
    
    // MARK: - Private
    
    var logger: Logger?
    internal func invalidateMemorySnapshotIfStoreVersionDrift(
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
            try await persistenceDomain.routingAppendCheckpointInvalidationAsync(
                conversationID: conversationID,
                kinds: [HarnessCheckpointInvalidationKind.memoryInjectionSnapshot]
            )
            await conversationTopicPublicationRuntimeService.publishCheckpointInvalidationOnTopic(
                conversationID: conversationID,
                invalidatedKinds: [HarnessCheckpointInvalidationKind.memoryInjectionSnapshot]
            )
        } catch {
            logger?.warning("[HarnessRuntimeSession] memory snapshot auto-invalidation failed: \(error)")
        }
    }

    internal func applySubagentCheckpointInvalidationIfNeeded(
        _ spec: ContextEngineSubagentCheckpointInvalidationSpec?
    ) async {
        await orchestratorSessionRuntimeService.applySubagentCheckpointInvalidationIfNeeded(spec)
    }
    internal static let allDerivedCheckpointInvalidationKinds: [String] = [
        HarnessCheckpointInvalidationKind.contextCompaction,
        HarnessCheckpointInvalidationKind.turnSummaryEvent,
        HarnessCheckpointInvalidationKind.memoryInjectionSnapshot,
        HarnessCheckpointInvalidationKind.toolResultTrim,
        HarnessCheckpointInvalidationKind.systemPromptAssembly,
        HarnessCheckpointInvalidationKind.attachmentProjection,
    ]

    let toolPolicy: ToolPolicyConfiguration
    private let trustPolicyConfiguration: TrustPolicyConfiguration
    let agentHarness: AgentHarnessConfiguration
    private let thinkingPolicyConfiguration: ThinkingPolicyConfiguration
    let conversationTransformConfiguration: ConversationTransformConfiguration
    /// Read-only mirror of `conversationTransformConfiguration.contextCompaction.manualRESTEnabled`
    /// for the API layer (which lives in a separate file and cannot reach the private storage).
    /// Computed; never cached, so flipping the flag in `PromptConfig.json` and rebuilding the
    /// manager picks it up immediately. The configuration itself is `let`, so no actor hop needed.
    var contextCompactionManualRESTEnabled: Bool {
        conversationTransformConfiguration.contextCompaction.manualRESTEnabled
    }
    private let conversationTransformer: any ConversationTransforming
    private let llmFactory: any ModelLLMFactoring
    private let registryEntryProvider: (@Sendable (UUID) async -> ModelRegistryEntry?)?
    private let rankedRegistryEntriesProvider: (@Sendable (ModelReference) async -> [ModelRegistryEntry])?
    private let callScheduler: any ModelCallScheduling
    private let invocationCoordinator: any ModelInvocationLifecycleTracking
    let toolSystemGateway: any ToolSystemGatewaying = DefaultToolSystemGateway()
    private var delegateCostTracker: (any DelegateCostTracking)?
    let runtimeExecutorFactory: AgentRuntimeExecutorFactory
    /// TODO: Replace this temporary hardcoded flag with robust debug settings exposed in UI.
    private let persistOriginalToolResultsDebugModeEnabled: Bool = true
    private var pendingToolResultTransformRecordsByConversationID: [UUID: [String: PendingToolResultTransformRecord]] = [:]
    private var lastContextTransformSnapshotByConversationID: [UUID: ContextTransformSnapshot] = [:]
    private var staleProjectionDropCount: Int = 0
    private var causalityRejectedSummaryCount: Int = 0
    private var overlapConflictResolvedCount: Int = 0
    private var decodeRejectedSummaryCount: Int = 0
    private var invalidStructuralSummaryCount: Int = 0
    private var unsuccessfulSummarySkippedCount: Int = 0
    private var deduplicatedSummaryEventCount: Int = 0
    private var projectionApplyLatencyMs: [Int] = []
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

    private enum ToolResultMessageOrigin: String, Sendable {
        case original
        case synthesizedWithTransform = "synthesized_with_transform"
    }

    private struct PendingToolResultTransformRecord: Sendable {
        let origin: ToolResultMessageOrigin
        let originalContent: String?
    }

    internal func composeModelReferenceForRouting(conversationID: UUID?, interactionMode: InteractionMode?, clientReference: ModelReference) async -> ModelReference {
        let routingQueryJSON: String?
        let resolved: ResolvedModeProfile
        if let conversationID,
           let conversation = await persistenceDomain.modelConversation(id: conversationID) {
            routingQueryJSON = conversation.routingPrefs?.queryJSON
            resolved = await orchestratorSessionRuntimeService.resolvedModeProfile(for: conversation)
        } else if let interactionMode {
            routingQueryJSON = nil
            resolved = (await runtimeDependencies.modeRegistry.resolveReportingFallback(
                modeId: interactionMode.rawValue,
                logger: logger,
                fallbackModeId: InteractionMode.chat.rawValue
            )).profile
        } else {
            return clientReference
        }
        return ModeProfileModelRouting.effectiveModelReference(
            clientReference,
            routingQueryJSON: routingQueryJSON,
            resolvedProfile: resolved
        )
    }

    internal func shouldEnableContextTransform(
        interactionMode: InteractionMode,
        contextCompactionLevel: String?
    ) -> Bool {
        let defaultEnabled = conversationTransformConfiguration.toggles(for: interactionMode).enableContextTransform
        guard let level = contextCompactionLevel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !level.isEmpty
        else {
            return defaultEnabled
        }
        switch level {
        case "off":
            return false
        case "shallow", "full":
            return true
        default:
            return defaultEnabled
        }
    }

    internal func bootstrapContextEngineLifecycle(conversationID: UUID, runID: UUID?) async {
        _ = await contextEngine.bootstrap(
            request: ContextEngineBootstrapRequest(
                conversationID: conversationID,
                runID: runID
            )
        )
    }

    internal func afterTurnContextEngineLifecycle(
        conversationID: UUID,
        runID: UUID?,
        terminalReason: ConversationRunTerminalReason?,
        anchorUserMessageID: UUID? = nil
    ) async {
        let recentMessages: [Message]
        if let conversation = await persistenceDomain.modelConversation(id: conversationID) {
            recentMessages = conversation.messages
        } else {
            recentMessages = []
        }
        _ = await contextEngine.afterTurn(
            request: ContextEngineAfterTurnRequest(
                conversationID: conversationID,
                runID: runID,
                terminalReason: terminalReason,
                anchorUserMessageID: anchorUserMessageID,
                recentMessages: recentMessages
            )
        )
    }

    internal func prepareSubagentSpawn(
        conversationID: UUID,
        runID: UUID?,
        candidateToolNames: [String],
        permissionPolicyByToolName: [String: SubAgentPermissionPolicy],
        trustLevelByToolName: [String: SubAgentTrustLevel],
        preApprovedToolNames: Set<String>
    ) async -> ContextEnginePrepareSubagentSpawnResult {
        let response = await contextEngine.prepareSubagentSpawn(
            request: ContextEnginePrepareSubagentSpawnRequest(
                conversationID: conversationID,
                runID: runID,
                candidateToolNames: candidateToolNames,
                permissionPolicyByToolName: permissionPolicyByToolName,
                trustLevelByToolName: trustLevelByToolName,
                preApprovedToolNames: preApprovedToolNames
            )
        )
        await applySubagentCheckpointInvalidationIfNeeded(response.checkpointInvalidation)
        return response
    }

    internal func onSubagentEnded(
        conversationID: UUID,
        runID: UUID?,
        toolName: String,
        permissionPolicy: SubAgentPermissionPolicy?,
        trustLevel: SubAgentTrustLevel?
    ) async -> ContextEngineSubagentEndedResult {
        let response = await contextEngine.onSubagentEnded(
            request: ContextEngineSubagentEndedRequest(
                conversationID: conversationID,
                runID: runID,
                toolName: toolName,
                permissionPolicy: permissionPolicy,
                trustLevel: trustLevel
            )
        )
        await applySubagentCheckpointInvalidationIfNeeded(response.checkpointInvalidation)
        return response
    }
}

extension HarnessRuntimeSession {
    public func modelConversation(id: UUID) async -> ModelConversation? {
        await persistenceDomain.modelConversation(id: id)
    }

    internal func startStreamingOrchestrationTask(
        sendingConversationID: UUID,
        turnLoopAnchorUserMessageID: UUID?,
        configuration: Configuration,
        orchestrator: SwiftAgentKitOrchestrator
    ) async {
        await agentRuntimeSessionService.startStreamingOrchestrationTask(
            sendingConversationID: sendingConversationID,
            turnLoopAnchorUserMessageID: turnLoopAnchorUserMessageID,
            configuration: configuration,
            orchestrator: orchestrator
        )
    }
}
