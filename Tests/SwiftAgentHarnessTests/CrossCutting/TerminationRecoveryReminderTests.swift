import Foundation
import SwiftData
import Testing
@testable import SwiftAgentHarness

@Suite("Termination recovery reminder")
struct TerminationRecoveryReminderTests {
    @Test("escalating reminder uses non-user role")
    func escalatingReminderUsesSystemRole() async throws {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
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
            runtimeExecutorFactory: AgentRuntimeExecutorFactories.default,
            logger: nil
        )
        let service = AgentRuntimeSessionService(
            deps: deps,
            messaging: ConversationMessagingPortAdapter.unbound,
            topics: ConversationTopicPublicationPortAdapter.unbound,
            orchestratorPort: OrchestratorSessionPortAdapter.makeUnbound(),
            selection: ConversationSelectionAccessAdapter.makeUnbound(),
            outbound: HarnessRuntimeOutboundTestDoubles.stubCollaborators(),
            orchestrationCore: AgentRuntimeOrchestrationCore()
        )

        let reminder = await service.makeTerminationRecoveryReminderMessage(
            conversationID: UUID(),
            attempt: 2,
            reminder: ModeProfileTerminationRecoveryReminder.escalating
        )

        #expect(reminder?.role == .system)
        #expect(reminder?.content.contains("Ephemeral runtime notice") == true)
    }
}
