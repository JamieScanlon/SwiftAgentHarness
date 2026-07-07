import Foundation
import SwiftData
import Testing
@testable import SwiftAgentHarness

@Suite("Harness runtime session — shutdown drain")
struct HarnessRuntimeSessionShutdownDrainTests {
    @Test("unbound ports return nil without trapping")
    func unboundPortsModelConversationLookup() async throws {
                let container = try HarnessTestModelContainer.makeInMemory()
        let stack = ConversationPersistenceStack.makeForTesting(container: container, logger: nil)
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
        let orchestrator = OrchestratorSessionPortAdapter.makeUnbound()
        let selection = ConversationSelectionAccessAdapter.makeUnbound()
        let messaging: ConversationMessagingPort = ConversationMessagingPortAdapter.unbound
        let topics: ConversationTopicPublicationPort = ConversationTopicPublicationPortAdapter.unbound
        let orchestrationCore = AgentRuntimeOrchestrationCore()
        let agentRuntime = AgentRuntimeSessionService(
            deps: deps,
            messaging: messaging,
            topics: topics,
            orchestratorPort: orchestrator,
            selection: selection,
            outbound: HarnessRuntimeOutboundTestDoubles.stubCollaborators(),
            orchestrationCore: orchestrationCore
        )
        let missing = await agentRuntime.modelConversationWhenSessionLive(id: UUID())
        #expect(missing == nil)
        #expect(await agentRuntime.isOrchestratorPortInstalled == false)
    }

    @Test("shutdownOrchestratorAndToolRuntimes clears generation and replay tasks")
    func shutdownClearsGenerationAndReplayTasks() async throws {
                let container = try HarnessTestModelContainer.makeInMemory()
        let session = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        await session.shutdownOrchestratorAndToolRuntimes()
        let lifecycle = await session.agentRuntimeSessionService.lifecycleSnapshot(for: nil)
        #expect(lifecycle.generationTask == nil)
        #expect(await session.conversationReplayService.testing_hasActiveReplayTasks() == false)
    }
}
