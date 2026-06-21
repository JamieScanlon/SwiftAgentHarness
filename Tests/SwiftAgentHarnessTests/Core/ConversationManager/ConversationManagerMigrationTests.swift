import Foundation
import SwiftData
import Testing
@testable import SwiftAgentHarness

@Suite struct ConversationManagerMigrationTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    @Test func catalogListViaDepsBasedWiring() async throws {
        let host = HarnessRuntimeSession(container: try makeContainer())
        let catalog = await host.conversationDomainServices.catalog
        #expect(await catalog.listConversationInfo().isEmpty)

        _ = try await host.conversationDomainServices.controlPlane.createConversation(
            with: Model(
                protocol: .openAIAPI,
                modelName: "migration-model",
                serverURL: URL(string: "http://localhost:1234")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            userSystemPrompt: "sys",
            topic: "Listed",
            description: nil,
            metadata: nil,
            interactionMode: .chat,
            modeProfileID: nil
        )

        let listed = await catalog.listConversationInfo()
        #expect(listed.count == 1)
        #expect(listed.first?.topic == "Listed")
    }

    @Test func runtimeGraphBuildsFromCoordinatingAndWiringSurface() async throws {
        let host = HarnessRuntimeSession(container: try makeContainer())
        let domain = await host.conversationDomainServices
        let agentRuntime = await host.agentRuntimeSessionService
        let replay = await host.conversationReplayService
        let policyRuntime = await host.conversationToolModePolicyRuntimeService
        let spawn = await host.subAgentSpawnService
        let completion = await host.subAgentCompletionRuntimeService

        let subAgentIngress = SubAgentAPIIngressService(spawn: spawn, completion: completion)
        let runtimeGraph = await SplitGatewayServiceFactory.makeRuntimeGraph(
            host: host,
            subAgentLifecycleHost: subAgentIngress,
            subAgentCompletionHost: subAgentIngress,
            subAgentCompletion: SubAgentCompletionIngressService(host: subAgentIngress)
        )

        #expect(ObjectIdentifier(runtimeGraph.agentRuntime) == ObjectIdentifier(agentRuntime))
        #expect(ObjectIdentifier(runtimeGraph.conversationReplay) == ObjectIdentifier(replay))
        guard let policyOwner = runtimeGraph.toolPolicyOwner as? ConversationToolModePolicyRuntimeService else {
            Issue.record("toolPolicyOwner should be ConversationToolModePolicyRuntimeService")
            return
        }
        #expect(ObjectIdentifier(policyOwner) == ObjectIdentifier(policyRuntime))
        let coordinating: any HarnessRuntimeSessionCoordinating = host
        #expect(await coordinating.currentConversation() == nil)
    }
}
