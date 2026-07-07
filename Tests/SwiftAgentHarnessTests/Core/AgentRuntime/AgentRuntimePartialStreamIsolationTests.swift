import Foundation
import SwiftData
import Testing
@testable import SwiftAgentHarness

@Suite("AgentRuntime partial stream isolation")
struct AgentRuntimePartialStreamIsolationTests {
    @Test("concurrent partial streams are isolated by runID")
    func concurrentPartialStreamsIsolatedByRunID() async throws {
        let service = try makeMinimalAgentRuntimeSessionService()
        let run1 = UUID()
        let run2 = UUID()
        let conversation1 = UUID()
        let conversation2 = UUID()

        let stream1 = await service.beginAgentLoopPartialStream(runID: run1)
        let stream2 = await service.beginAgentLoopPartialStream(runID: run2)

        let collector1 = Task { await collectTextPartials(from: stream1) }
        let collector2 = Task { await collectTextPartials(from: stream2) }

        await service.publishAgentLoopDelta(.text("A"), conversationID: conversation1, runID: run1)
        await service.publishAgentLoopDelta(.text("B"), conversationID: conversation2, runID: run2)

        await service.finishAgentLoopPartialStream(runID: run1)

        let partials1 = await collector1.value
        #expect(partials1 == ["A"])

        await service.publishAgentLoopDelta(.text("C"), conversationID: conversation2, runID: run2)
        await service.finishAgentLoopPartialStream(runID: run2)

        let partials2 = await collector2.value
        #expect(partials2 == ["B", "C"])
        #expect(!partials2.contains("A"))
    }

    private func makeMinimalAgentRuntimeSessionService() throws -> AgentRuntimeSessionService {
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

    private func collectTextPartials(from stream: AsyncStream<ChatStreamingPartial>) async -> [String] {
        var values: [String] = []
        for await partial in stream {
            if case .text(let text) = partial {
                values.append(text)
            }
        }
        return values
    }
}
