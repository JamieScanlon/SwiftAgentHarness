import Foundation
import SwiftData
import Testing
@testable import SwiftAgentHarness

@Suite struct SplitGatewayServiceFactoryTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func makeRuntimeGraph(services: HarnessRuntimeSessionFactory.Services) -> HarnessRuntimeGraph {
        let subAgentIngress = SubAgentAPIIngressService(
            spawn: services.subAgentSpawnService,
            completion: services.subAgentCompletionRuntimeService
        )
        return SplitGatewayServiceFactory.makeRuntimeGraph(
            services: services,
            subAgentLifecycleHost: subAgentIngress,
            subAgentCompletionHost: subAgentIngress,
            subAgentCompletion: SubAgentCompletionIngressService(host: subAgentIngress)
        )
    }

    @Test func makeServiceGraphFromRuntimeGraphBuildsGateway() async throws {
        let host = HarnessConversationTestFixtures.makeRuntimeSession(container: try makeContainer())
        let services = await host.services
        let runtimeGraph = makeRuntimeGraph(services: services)
        let graph = SplitGatewayServiceFactory.makeServiceGraph(runtimeGraph: runtimeGraph)
        let gateway = SplitGatewayServiceFactory.makeServiceGraph(graph: graph)
        let conversations = await gateway.conversation.apiListConversationInfo()
        #expect(conversations.isEmpty)
    }

    @Test func harnessServiceGraphExplicitServicesBuildGateway() async throws {
        let host = HarnessConversationTestFixtures.makeRuntimeSession(container: try makeContainer())
        let graph = await HarnessConversationTestFixtures.makeServiceGraph(from: host)
        let info = await graph.conversationAdapter.apiListConversationInfo()
        #expect(info.isEmpty)
    }

    @Test func makeRuntimeGraphUsesPolicyRuntimeServiceNotSession() async throws {
        let host = HarnessConversationTestFixtures.makeRuntimeSession(container: try makeContainer())
        let services = await host.services
        let runtimeGraph = makeRuntimeGraph(services: services)
        let policyRuntime = services.conversationToolModePolicyRuntimeService
        guard let owner = runtimeGraph.toolPolicyOwner as? ConversationToolModePolicyRuntimeService else {
            Issue.record("toolPolicyOwner should be ConversationToolModePolicyRuntimeService")
            return
        }
        #expect(ObjectIdentifier(owner) == ObjectIdentifier(policyRuntime))
        #expect(ObjectIdentifier(owner) != ObjectIdentifier(host))
    }
}
