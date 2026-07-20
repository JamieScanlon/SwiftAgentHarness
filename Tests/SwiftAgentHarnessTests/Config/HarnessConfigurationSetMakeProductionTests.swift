import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("HarnessConfigurationSet makeProduction wiring", .serialized)
struct HarnessConfigurationSetMakeProductionTests {
    @Test("makeProduction(configuration:) stores the set on runtime dependencies")
    func makeProductionStoresConfigurationSet() async throws {
        let json = """
        {
          "options": { "includeAgentSkills": false, "includeCurrentDateTime": false },
          "agentHarness": { "strictAgentHarnessPrompts": false, "maxCorrectionRetries": 3 },
          "memory": { "activeMemoryEnabled": false },
          "toolPolicy": { "dispatch": { "parallelEnabled": true } }
        }
        """
        let document = try PromptConfigDocument.parse(data: Data(json.utf8))
        let configuration = HarnessConfigurationSet.load(from: document)

        let container = try HarnessConversationTestFixtures.makeInMemoryContainer()
        let persistence = ConversationPersistenceDomain.makeForTesting(container: container, logger: nil)
        let compactionCoordinator = CompactionConcurrencyCoordinator()
        let (session, _) = HarnessRuntimeSession.makeProduction(
            persistenceDomain: persistence,
            logger: nil,
            configuration: configuration,
            conversationTransformer: NoOpConversationTransformer(),
            llmFactory: StandardModelLLMFactory(),
            registryEntryProvider: nil,
            rankedRegistryEntriesProvider: nil,
            delegateCostTracker: nil,
            callScheduler: ModelCallScheduler(),
            invocationCoordinator: ModelInvocationCoordinator(),
            compactionCoordinator: compactionCoordinator,
            contextEngine: DefaultContextEngine(compactionCoordinator: compactionCoordinator, logger: nil),
            modeRegistry: ModeRegistryPortAdapter(
                service: ModeRegistryService(modeProfileConfiguration: configuration.modeProfiles)
            )
        )

        let deps = await session.runtimeDependencies
        #expect(deps.configurationSet.agentHarness.maxCorrectionRetries == 3)
        #expect(deps.configurationSet.promptAssembly.includeAgentSkills == false)
        #expect(deps.configurationSet.memory.activeMemoryEnabled == false)
        #expect(deps.agentHarness.maxCorrectionRetries == 3)
        #expect(deps.configurationSet.toolPolicy.parallelDispatchEnabled)
        #expect(deps.toolPolicy.parallelDispatchEnabled)

        PromptConfigBundleResource.configure(data: Data("""
        {
          "agentHarness": { "maxCorrectionRetries": 99 },
          "toolPolicy": { "dispatch": { "parallelEnabled": false } }
        }
        """.utf8))
        defer { PromptConfigBundleResource.resetForTesting() }

        let depsAfterAmbientMutation = await session.runtimeDependencies
        #expect(depsAfterAmbientMutation.configurationSet.agentHarness.maxCorrectionRetries == 3)
        #expect(depsAfterAmbientMutation.configurationSet.toolPolicy.parallelDispatchEnabled)
        #expect(depsAfterAmbientMutation.toolPolicy.parallelDispatchEnabled)
    }
}
