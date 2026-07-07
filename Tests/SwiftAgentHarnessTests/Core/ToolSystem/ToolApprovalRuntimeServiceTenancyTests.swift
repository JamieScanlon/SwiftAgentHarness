import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ToolApprovalRuntimeService tenancy")
struct ToolApprovalRuntimeServiceTenancyTests {
    private func makeModel() -> Model {
        Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "tool-approval-tenancy-model",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    private func makeDependencies(container: ModelContainer) -> ConversationRuntimeDependencies {
        let domain = ConversationPersistenceDomain.makeForTesting(container: container, logger: nil)
        return ConversationRuntimeDependencies(
            persistenceDomain: domain,
            compactionCoordinator: CompactionConcurrencyCoordinator(),
            contextEngine: DefaultContextEngine(compactionCoordinator: CompactionConcurrencyCoordinator(), logger: nil),
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
    }

    private func makeService(
        deps: ConversationRuntimeDependencies,
        strictTenancy: Bool,
        permissionRules: any PermissionRuleStore = InMemoryPermissionRuleStore()
    ) -> ToolApprovalRuntimeService {
        let topics = ConversationTopicPublicationPortAdapter.makeUnbound()
        return ToolApprovalRuntimeService(
            deps: deps,
            topics: topics,
            permissionRules: permissionRules,
            tenancyPolicy: TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: strictTenancy)
        )
    }

    private func seedConversation(
        deps: ConversationRuntimeDependencies,
        ownerAccountID: UUID
    ) async throws -> UUID {
        let conversation = try await deps.persistenceDomain.createConversation(
            with: makeModel(),
            userSystemPrompt: "sys",
            topic: "topic",
            description: nil,
            metadata: nil,
            interactionMode: .chat,
            ownerAccountID: ownerAccountID
        )
        return conversation.id
    }

    @Test("durable grant for owner A does not pre-approve owner B conversations")
    func durableGrantDoesNotCrossOwners() async throws {
        let container = try HarnessTestModelContainer.makeInMemory()
        let deps = makeDependencies(container: container)
        let service = makeService(deps: deps, strictTenancy: true)
        let ownerA = UUID()
        let ownerB = UUID()
        let conversationA = try await seedConversation(deps: deps, ownerAccountID: ownerA)
        let conversationB = try await seedConversation(deps: deps, ownerAccountID: ownerB)

        await service.grantDurableToolRule(toolName: "write_file", conversationID: conversationA)

        let configA = await service.configurationApplyingToolApprovals(
            HarnessRuntimeSession.Configuration(),
            conversationID: conversationA,
            runID: nil
        )
        let configB = await service.configurationApplyingToolApprovals(
            HarnessRuntimeSession.Configuration(),
            conversationID: conversationB,
            runID: nil
        )

        #expect(configA.preApprovedToolNames.contains("write_file"))
        #expect(configB.preApprovedToolNames.contains("write_file") == false)
    }

    @Test("strict tenancy ignores legacy global tool-name grants in configuration merge")
    func strictTenancyIgnoresLegacyGlobalGrants() async throws {
        let container = try HarnessTestModelContainer.makeInMemory()
        let deps = makeDependencies(container: container)
        let rules = InMemoryPermissionRuleStore()
        await rules.add(.toolName("legacy_tool"))
        let service = makeService(deps: deps, strictTenancy: true, permissionRules: rules)
        let owner = UUID()
        let conversationID = try await seedConversation(deps: deps, ownerAccountID: owner)

        let merged = await service.configurationApplyingToolApprovals(
            HarnessRuntimeSession.Configuration(),
            conversationID: conversationID,
            runID: nil
        )

        #expect(merged.preApprovedToolNames.contains("legacy_tool") == false)
    }

    @Test("relaxed tenancy with nil owner still applies legacy global tool-name grants")
    func relaxedTenancyAppliesLegacyGlobalGrants() async throws {
        let container = try HarnessTestModelContainer.makeInMemory()
        let deps = makeDependencies(container: container)
        let rules = InMemoryPermissionRuleStore()
        await rules.add(.toolName("legacy_tool"))
        let service = makeService(deps: deps, strictTenancy: false, permissionRules: rules)
        let conversation = try await deps.persistenceDomain.createConversation(
            with: makeModel(),
            userSystemPrompt: "sys",
            topic: "topic",
            description: nil,
            metadata: nil,
            interactionMode: .chat,
            ownerAccountID: nil
        )

        let merged = await service.configurationApplyingToolApprovals(
            HarnessRuntimeSession.Configuration(),
            conversationID: conversation.id,
            runID: nil
        )

        #expect(merged.preApprovedToolNames.contains("legacy_tool"))
    }
}
