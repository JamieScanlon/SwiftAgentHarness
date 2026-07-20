import Foundation
import SwiftAgentKit
import SwiftAgentKitMCP
import SwiftData
import Testing
import SwiftAgentHarnessProviders
@testable import SwiftAgentHarness

private extension MCPManager {
    func testing_markInitialized() {
        state = .initialized
    }
}

@Suite("Catalog listing preserves shared managers", .serialized)
struct CatalogListingSharedManagerRegressionTests {

    private func makeModel(name: String = "catalog-mcp:test") -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: name,
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI,
            maxContextLength: 8_192
        )
    }

    private func makeSession() throws -> HarnessRuntimeSession {
        let container = try HarnessTestModelContainer.makeInMemory()
        return HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
    }

    private func prepareConversation(session: HarnessRuntimeSession) async throws -> ModelConversation {
        ProviderTestManifestSupport.prepareRegistry()
        let model = makeModel()
        _ = try await session.createConversation(with: model, userSystemPrompt: "sys", topic: nil, description: nil)
        let conversation = try #require(await session.currentConversation())
        await session.testing_setCurrentConversationID(conversation.id)
        return conversation
    }

    @Test("policy tool catalog listing does not shut down shared MCP manager")
    func policyCatalogListingPreservesSharedMCP() async throws {
        let session = try makeSession()
        let sharedMCP = MCPManager()
        await sharedMCP.testing_markInitialized()
        await session.setMCPManager(sharedMCP)

        let conversation = try await prepareConversation(session: session)
        let policy = await session.conversationToolModePolicyRuntimeService

        _ = await policy.apiRegistryEntriesForListing(preferredConversation: conversation)
        _ = await policy.apiRegistryEntriesForListing(preferredConversation: conversation)
        // Allow any fire-and-forget teardown Task to run if reintroduced.
        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(await sharedMCP.state == .initialized)

        let tools = try await policy.listAvailableToolsForAPI(conversationID: conversation.id)
        #expect(!tools.isEmpty)
        #expect(await sharedMCP.state == .initialized)

        await session.orchestratorRuntimeService.shutdownToolRuntimes(existingOrchestrator: nil)
        #expect(await sharedMCP.state == .notReady)
    }

    @Test("session catalog listing does not shut down shared MCP manager")
    func sessionCatalogListingPreservesSharedMCP() async throws {
        let session = try makeSession()
        let sharedMCP = MCPManager()
        await sharedMCP.testing_markInitialized()
        await session.setMCPManager(sharedMCP)

        let conversation = try await prepareConversation(session: session)
        let sessionRuntime = await session.orchestratorSessionRuntimeService

        _ = try await sessionRuntime.listSubAgentRegistryEntriesForAPI(conversationID: conversation.id)
        _ = try await sessionRuntime.listSubAgentRegistryEntriesForAPI(conversationID: conversation.id)
        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(await sharedMCP.state == .initialized)

        await session.orchestratorRuntimeService.shutdownToolRuntimes(existingOrchestrator: nil)
        #expect(await sharedMCP.state == .notReady)
    }
}
