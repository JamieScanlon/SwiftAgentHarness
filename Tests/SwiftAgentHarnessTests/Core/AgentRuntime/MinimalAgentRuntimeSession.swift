import Foundation
@testable import SwiftAgentHarness

enum MinimalAgentRuntimeSession {
    /// A runtime session over in-memory persistence with every collaborator unbound.
    static func make() throws -> AgentRuntimeSessionService {
        let container = try HarnessTestModelContainer.makeInMemory()
        let domain = ConversationPersistenceDomain.makeForTesting(container: container, logger: nil)
        let compactionCoordinator = CompactionConcurrencyCoordinator()
        let deps = ConversationRuntimeDependencies(
            persistenceDomain: domain,
            compactionCoordinator: compactionCoordinator,
            contextEngine: DefaultContextEngine(compactionCoordinator: compactionCoordinator, logger: nil),
            contextAssemblyRuntime: ContextAssemblyRuntimeFacade(
                persistenceDomain: domain,
                conversationTransformConfiguration: .default
            ),
            modeRegistry: ModeRegistryTestSupport.makePort(),
            llmFactory: StandardModelLLMFactory(),
            callScheduler: ModelCallScheduler(),
            invocationCoordinator: ModelInvocationCoordinator(),
            runtimeLaneCoordinator: RuntimeLaneCoordinator(configuration: .default),
            toolPolicy: .unrestricted,
            trustPolicyConfiguration: .disabled,
            agentHarness: .default,
            thinkingPolicyConfiguration: .default,
            conversationTransformConfiguration: .default,
            conversationTransformer: NoOpConversationTransformer(),
            registryEntryProvider: nil,
            rankedRegistryEntriesProvider: nil,
            delegateCostTracker: nil,
            runtimeExecutorFactory: AgentRuntimeExecutorFactories.defaultInternal,
            logger: nil
        )
        return AgentRuntimeSessionService(
            deps: deps,
            messaging: ConversationMessagingPortAdapter.unbound,
            topics: ConversationTopicPublicationPortAdapter.unbound,
            orchestratorPort: OrchestratorSessionPortAdapter.makeUnbound(),
            selection: ConversationSelectionAccessAdapter.makeUnbound(),
            outbound: HarnessRuntimeOutboundTestDoubles.stubCollaborators(),
            orchestrationCore: AgentRuntimeOrchestrationCore()
        )
    }
}
