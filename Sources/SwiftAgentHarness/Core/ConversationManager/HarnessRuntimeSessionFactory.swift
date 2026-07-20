import Foundation
import Logging
import SwiftAgentKit
import SwiftAgentKitOrchestrator

public enum HarnessRuntimeSessionFactory {
    public struct Services: Sendable {
        let orchestrator: OrchestratorSessionPortAdapter
        let selection: ConversationSelectionAccessAdapter
        let sessionProjection: SessionProjectionPortAdapter
        let topics: ConversationTopicPublicationPortAdapter
        public let agentRuntimeSessionService: AgentRuntimeSessionService
        let orchestrationCore: AgentRuntimeOrchestrationCore
        public let subAgentCompletionRuntimeService: SubAgentCompletionRuntimeService
        let runtimeLifecyclePublicationService: RuntimeLifecyclePublicationService
        public let conversationStartupService: ConversationStartupService
        let contextProjectionService: ContextProjectionService
        let skillActivationService: SkillActivationService
        let subAgentPool: any SubAgentPooling
        public let orchestratorRuntimeService: OrchestratorRuntimeService
        public let subAgentSpawnService: SubAgentSpawnService
        let toolApprovalRuntimeService: ToolApprovalRuntimeService
        let slashCommandDispatchService: SlashCommandDispatchService
        public let conversationReplayService: ConversationReplayService
        let conversationDomainServices: ConversationDomainServiceBundle
        let conversationToolDataService: ConversationToolDataService
        let conversationToolModePolicyRuntimeService: ConversationToolModePolicyRuntimeService
        let conversationMessagingRuntimeService: ConversationMessagingRuntimeService
        let conversationTopicPublicationRuntimeService: ConversationTopicPublicationRuntimeService
        let conversationSelectionRuntimeService: ConversationSelectionRuntimeService
        let sessionProjectionRuntimeService: SessionProjectionRuntimeService
        let orchestratorSessionRuntimeService: OrchestratorSessionRuntimeService
        public let channelRegistryHolder: ChannelRegistryHolder
    }

    static func makeForTesting(
        deps: ConversationRuntimeDependencies,
        persistenceDomain: ConversationPersistenceDomain? = nil,
        wireMemorySubAgents: Bool = false,
        tenancyPolicy: TenancyPolicySettings = .disabled
    ) -> Services {
        makeServices(
            deps: deps,
            persistenceDomain: persistenceDomain ?? deps.persistenceDomain,
            wireMemorySubAgents: wireMemorySubAgents,
            tenancyPolicy: tenancyPolicy
        )
    }

    static func makeSession(
        persistenceDomain: ConversationPersistenceDomain,
        runtimeDependencies: ConversationRuntimeDependencies,
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
        runtimeExecutorFactory: @escaping AgentRuntimeExecutorFactory,
        wireMemorySubAgents: Bool = false,
        tenancyPolicy: TenancyPolicySettings = .disabled
    ) -> (HarnessRuntimeSession, Services) {
        let services = makeServices(
            deps: runtimeDependencies,
            persistenceDomain: persistenceDomain,
            wireMemorySubAgents: wireMemorySubAgents,
            tenancyPolicy: tenancyPolicy
        )
        let session = HarnessRuntimeSession(
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
            llmFactory: llmFactory,
            registryEntryProvider: registryEntryProvider,
            rankedRegistryEntriesProvider: rankedRegistryEntriesProvider,
            delegateCostTracker: delegateCostTracker,
            callScheduler: callScheduler,
            invocationCoordinator: invocationCoordinator,
            compactionCoordinator: compactionCoordinator,
            contextEngine: contextEngine,
            runtimeExecutorFactory: runtimeExecutorFactory
        )
        let denialHygieneHandler = ExecDenialHygieneService(
            persistenceDomain: persistenceDomain,
            refreshProjection: { conversationID in
                await services.conversationMessagingRuntimeService.refreshProjectedConversationMessages(
                    conversationID: conversationID,
                    baseMessagesOverride: nil
                )
            },
            logger: logger
        )
        Task {
            await ExecApprovalStore.shared.configure(denialHygieneHandler: denialHygieneHandler)
        }
        return (session, services)
    }

    static func makeServices(
        deps: ConversationRuntimeDependencies,
        persistenceDomain: ConversationPersistenceDomain,
        wireMemorySubAgents: Bool = false,
        tenancyPolicy: TenancyPolicySettings = .disabled
    ) -> Services {
        let orchestrationCore = AgentRuntimeOrchestrationCore(
            maxPoolEntries: deps.agentHarness.orchestratorPoolMaxEntries,
            idleTTLSeconds: TimeInterval(deps.agentHarness.orchestratorPoolIdleTTLSeconds)
        )
        let orchestrator = OrchestratorSessionPortAdapter.makeUnbound()
        let selection = ConversationSelectionAccessAdapter.makeUnbound()
        let sessionProjection = SessionProjectionPortAdapter.makeUnbound()
        let messaging = ConversationMessagingPortAdapter.makeUnbound()
        let topics = ConversationTopicPublicationPortAdapter.makeUnbound()

        let contextProjectionService = ContextProjectionService(
            deps: deps,
            agentRuntime: orchestrationCore,
            selection: selection,
            topics: topics
        )
        let runtimeLifecyclePublicationService = RuntimeLifecyclePublicationService(
            deps: deps,
            messaging: messaging,
            agentRuntime: orchestrationCore
        )
        let skillActivationService = SkillActivationService(deps: deps)
        let sessionProjectionRuntimeService = SessionProjectionRuntimeService(
            persistenceDomain: persistenceDomain,
            selection: selection
        )
        sessionProjection.install(service: sessionProjectionRuntimeService)
        let conversationSelectionRuntimeService = ConversationSelectionRuntimeService(
            deps: deps,
            persistenceDomain: persistenceDomain,
            skillActivation: skillActivationService,
            sessionProjection: sessionProjection,
            contextProjection: contextProjectionService,
            registryOwnerAccountScope: { nil },
            tenancyPolicy: tenancyPolicy
        )
        selection.install(service: conversationSelectionRuntimeService)
        let subAgentPoolResolved = SubAgentPoolRuntimeWiring.resolve(
            customEndpointConfiguration: deps.configurationSet.subAgentCustomEndpoint,
            hostingPolicyConfiguration: deps.configurationSet.subAgentHostingPolicy,
            logger: deps.logger
        )
        let subAgentPool: any SubAgentPooling = subAgentPoolResolved.pool
        let subAgentCompletionRuntimeService = SubAgentCompletionRuntimeService(
            deps: deps,
            orchestrationCore: orchestrationCore,
            messaging: messaging,
            topics: topics
        )
        let orchestratorRuntimeService = OrchestratorRuntimeService(
            deps: deps,
            orchestrationCore: orchestrationCore,
            skillActivation: skillActivationService,
            contextProjection: contextProjectionService,
            subAgentPool: subAgentPool,
            selection: selection
        )
        let conversationReplayService = ConversationReplayService(
            deps: deps,
            contextProjection: contextProjectionService,
            selection: selection,
            sessionProjection: sessionProjection,
            messaging: messaging
        )
        let domainServices = ConversationDomainServiceFactory.makeBundle(
            deps: deps,
            orchestrationCore: orchestrationCore,
            orchestratorRuntime: orchestratorRuntimeService,
            conversationReplay: conversationReplayService,
            contextProjection: contextProjectionService,
            runtimeLifecyclePublication: runtimeLifecyclePublicationService,
            selection: selection,
            orchestrator: orchestrator,
            topics: topics,
            messaging: messaging,
            sessionProjection: sessionProjection,
            skillActivation: skillActivationService,
            registryOwnerAccountScope: { nil }
        )
        let conversationDomainServices = domainServices.bundle
        let lifecycle = conversationDomainServices.lifecycle
        let conversationStartupService = ConversationStartupService(
            deps: deps,
            orchestrationCore: orchestrationCore,
            sessionProjection: sessionProjection,
            messaging: messaging,
            runtimeLifecyclePublication: runtimeLifecyclePublicationService,
            lifecycle: lifecycle
        )
        orchestratorRuntimeService.installStartup(conversationStartupService)
        conversationStartupService.installSubAgentA2AManagerProvider(subAgentPoolResolved.a2aManagerProvider)
        conversationStartupService.installSubAgentACPManagerProvider(subAgentPoolResolved.acpManagerProvider)
        let conversationTopicPublicationRuntimeService = ConversationTopicPublicationRuntimeService(
            deps: deps,
            agentRuntime: orchestrationCore,
            startup: conversationStartupService
        )
        topics.install(
            topicService: conversationTopicPublicationRuntimeService,
            runtimeLifecyclePublication: runtimeLifecyclePublicationService
        )
        orchestratorRuntimeService.installTopicPublication(topics)
        let toolApprovalRuntimeService = ToolApprovalRuntimeService(
            deps: deps,
            topics: topics,
            tenancyPolicy: tenancyPolicy
        )
        let slashCommandDispatchService = SlashCommandDispatchService(
            deps: deps,
            tenancyPolicy: tenancyPolicy,
            topics: topics,
            messaging: messaging,
            selection: selection,
            sessionProjection: sessionProjection,
            skillActivation: skillActivationService,
            contextProjection: contextProjectionService,
            toolApproval: toolApprovalRuntimeService,
            orchestratorRuntime: orchestratorRuntimeService,
            agentRuntime: orchestrationCore,
            subAgentPool: subAgentPool
        )
        let conversationToolModePolicyRuntimeService = ConversationToolModePolicyRuntimeService(
            deps: deps,
            orchestratorRuntime: orchestratorRuntimeService,
            agentRuntime: orchestrationCore,
            skillActivation: skillActivationService,
            slashCommandDispatch: slashCommandDispatchService,
            toolApproval: toolApprovalRuntimeService,
            subAgentPool: subAgentPool,
            selection: selection
        )
        let agentRuntimeSessionService = AgentRuntimeSessionService(
            deps: deps,
            messaging: messaging,
            topics: topics,
            orchestratorPort: orchestrator,
            selection: selection,
            outbound: AgentRuntimeOutboundCollaborators(
                toolApproval: toolApprovalRuntimeService,
                orchestratorRuntime: orchestratorRuntimeService,
                contextProjection: contextProjectionService,
                lifecycle: lifecycle,
                slashCommand: slashCommandDispatchService
            ),
            orchestrationCore: orchestrationCore
        )
        ConversationDomainServiceFactory.installRunControl(
            agentRuntimeSessionService,
            controlPlane: domainServices.controlPlane,
            lifecycle: domainServices.lifecycle,
            runsReplay: domainServices.runsReplay
        )
        orchestratorRuntimeService.installAgentRuntime(agentRuntimeSessionService)
        let subAgentSpawnService = SubAgentSpawnService(
            deps: deps,
            subAgentPool: subAgentPool,
            completionService: subAgentCompletionRuntimeService,
            orchestratorRuntime: orchestratorRuntimeService,
            agentRuntime: agentRuntimeSessionService,
            topics: topics,
            messaging: messaging,
            orchestrator: orchestrator,
            startup: conversationStartupService,
            lifecycle: lifecycle,
            contextProjection: contextProjectionService
        )
        subAgentCompletionRuntimeService.installSpawn(subAgentSpawnService)
        orchestratorRuntimeService.installSpawn(subAgentSpawnService)
        conversationStartupService.installSpawn(subAgentSpawnService)
        agentRuntimeSessionService.installSubAgentSpawnService(subAgentSpawnService)
        toolApprovalRuntimeService.installSubAgentSpawnService(subAgentSpawnService)
        slashCommandDispatchService.installSubAgentSpawnService(subAgentSpawnService)
        Task {
            await subAgentSpawnService.installACPPermissionCoordinator(toolApproval: toolApprovalRuntimeService)
        }
        let conversationToolDataService = ConversationToolDataService(
            catalog: conversationDomainServices.catalog,
            controlPlane: conversationDomainServices.controlPlane,
            agentRuntime: agentRuntimeSessionService,
            selection: selection,
            tenancyPolicy: tenancyPolicy
        )
        orchestratorRuntimeService.installToolCollaborators(
            toolApproval: toolApprovalRuntimeService,
            toolData: conversationToolDataService
        )
        conversationToolModePolicyRuntimeService.installToolData(conversationToolDataService)
        let conversationMessagingRuntimeService = ConversationMessagingRuntimeService(
            deps: deps,
            persistenceDomain: persistenceDomain,
            agentRuntime: agentRuntimeSessionService,
            contextProjection: contextProjectionService,
            startup: conversationStartupService,
            slashCommand: slashCommandDispatchService,
            lifecycle: lifecycle,
            selection: selection,
            sessionProjection: sessionProjection,
            topics: topics
        )
        messaging.install(service: conversationMessagingRuntimeService)
        let orchestratorSessionRuntimeService = OrchestratorSessionRuntimeService(
            deps: deps,
            persistenceDomain: persistenceDomain,
            selection: selection,
            sessionProjection: sessionProjection,
            messaging: messaging,
            topics: topics,
            agentRuntime: agentRuntimeSessionService,
            orchestratorRuntime: orchestratorRuntimeService,
            skillActivation: skillActivationService,
            spawn: subAgentSpawnService,
            subAgentCompletion: subAgentCompletionRuntimeService,
            subAgentPool: subAgentPool,
            slashCommand: slashCommandDispatchService,
            toolData: conversationToolDataService
        )
        orchestrator.install(service: orchestratorSessionRuntimeService)
        orchestratorRuntimeService.installModePolicy(orchestratorSessionRuntimeService)
        orchestratorRuntimeService.installSessionCollaborator(orchestratorSessionRuntimeService)
        Task {
            await orchestrationCore.setOrchestratorTeardownHandler { [orchestratorRuntimeService] orchestrator in
                await orchestratorRuntimeService.releasePooledOrchestrator(orchestrator)
            }
        }
        let channelRegistryHolder = ChannelRegistryHolder()
        let acpDelegateFactory = SubAgentHarnessACPClientDelegateFactory(
            deps: deps,
            gateway: DefaultToolSystemGateway(visibilityGrants: deps.visibilityGrants),
            subAgentPool: subAgentPool,
            toolApproval: toolApprovalRuntimeService,
            resolveChannelRegistry: { channelRegistryHolder.registry },
            resolveOrchestrator: {
                let lifecycle = await agentRuntimeSessionService.lifecycleSnapshot(for: nil)
                guard let conversationID = ConversationScope.current?.selfID
                    ?? lifecycle.activeStreamingConversationID else {
                    return nil
                }
                return await agentRuntimeSessionService.orchestrator(for: conversationID)
            },
            resolveToolEntries: {
                let lifecycle = await agentRuntimeSessionService.lifecycleSnapshot(for: nil)
                guard let conversationID = ConversationScope.current?.selfID
                    ?? lifecycle.activeStreamingConversationID,
                      let orchestrator = await agentRuntimeSessionService.orchestrator(for: conversationID) else {
                    return []
                }
                return await orchestratorRuntimeService.allToolRegistryEntriesForOrchestration(orchestrator: orchestrator)
            },
            resolveModePolicyContext: { conversation in
                await orchestratorSessionRuntimeService.modePolicyContext(for: conversation)
            }
        )
        Task {
            await conversationStartupService.installSubAgentACPClientDelegateFactory(acpDelegateFactory)
        }
        if wireMemorySubAgents {
            MemorySubAgentSpawnWiring.install(
                deps: deps,
                persistenceDomain: persistenceDomain,
                subAgentSpawnService: subAgentSpawnService,
                agentRuntime: agentRuntimeSessionService
            )
        }
        return Services(
            orchestrator: orchestrator,
            selection: selection,
            sessionProjection: sessionProjection,
            topics: topics,
            agentRuntimeSessionService: agentRuntimeSessionService,
            orchestrationCore: orchestrationCore,
            subAgentCompletionRuntimeService: subAgentCompletionRuntimeService,
            runtimeLifecyclePublicationService: runtimeLifecyclePublicationService,
            conversationStartupService: conversationStartupService,
            contextProjectionService: contextProjectionService,
            skillActivationService: skillActivationService,
            subAgentPool: subAgentPool,
            orchestratorRuntimeService: orchestratorRuntimeService,
            subAgentSpawnService: subAgentSpawnService,
            toolApprovalRuntimeService: toolApprovalRuntimeService,
            slashCommandDispatchService: slashCommandDispatchService,
            conversationReplayService: conversationReplayService,
            conversationDomainServices: conversationDomainServices,
            conversationToolDataService: conversationToolDataService,
            conversationToolModePolicyRuntimeService: conversationToolModePolicyRuntimeService,
            conversationMessagingRuntimeService: conversationMessagingRuntimeService,
            conversationTopicPublicationRuntimeService: conversationTopicPublicationRuntimeService,
            conversationSelectionRuntimeService: conversationSelectionRuntimeService,
            sessionProjectionRuntimeService: sessionProjectionRuntimeService,
            orchestratorSessionRuntimeService: orchestratorSessionRuntimeService,
            channelRegistryHolder: channelRegistryHolder
        )
    }
}
