import Foundation
import SwiftAgentKit
import SwiftData
import Testing
@testable import SwiftAgentHarness

private enum APILayerConversationAdapterTestSupport {
    static func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    static func makeTestModel(id: UUID = UUID()) -> Model {
        Model(
            id: id,
            protocol: .openAIAPI,
            modelName: "adapter-model",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }
}

@Suite("APILayer conversation adapter")
struct APILayerConversationAdapterTests {
    private func makeAdapter(runtimeSession: HarnessRuntimeSession) async -> APILayerConversationAdapter {
        await makeSplitConversationAdapter(runtimeSession: runtimeSession)
    }

    @Test("adapter can create and read conversations")
    func adapterCreateAndReadConversation() async throws {
        let container = try APILayerConversationAdapterTestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let adapter = await makeAdapter(runtimeSession: runtimeSession)
        let model = APILayerConversationAdapterTestSupport.makeTestModel()

        let conversationID = try await adapter.apiCreateConversation(
            with: model,
            userSystemPrompt: "adapter-test",
            topic: "topic",
            description: "desc",
            metadata: nil,
            interactionMode: .chat,
            modeProfileID: nil,
            cwd: nil
        )

        let created = await adapter.apiGetConversation(id: conversationID)
        #expect(created?.id == conversationID)
    }

    @Test("adapter maps missing conversation completion announce to route error")
    func missingConversationMapsToRouteError() async throws {
        let container = try APILayerConversationAdapterTestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let adapter = await makeAdapter(runtimeSession: runtimeSession)

        await #expect(throws: APILayerConversationRouteError.conversationNotFound) {
            try await adapter.apiPushCompletionAnnouncement(
                conversationID: UUID(),
                announce: CompletionAnnouncePayload(
                    delegateHandleID: "handle-1",
                    toolCallID: "tool-call-1",
                    conversationID: UUID(),
                    parentConversationID: nil,
                    lifecycleID: "handle-1",
                    status: .done,
                    completedAt: Date(),
                    source: "tests.adapter"
                ),
                toolMessageContent: nil
            )
        }
    }

    @Test("adapter routes tool mode approval policy surfaces")
    func adapterToolModeApprovalSurfaces() async throws {
        let container = try APILayerConversationAdapterTestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let adapter = await makeAdapter(runtimeSession: runtimeSession)
        let model = APILayerConversationAdapterTestSupport.makeTestModel()

        let conversationID = try await adapter.apiCreateConversation(
            with: model,
            userSystemPrompt: "adapter-policy-test",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat,
            modeProfileID: nil,
            cwd: nil
        )

        _ = try await adapter.apiListAvailableTools(conversationID: conversationID)
        _ = try await adapter.apiListAvailableSkills(conversationID: conversationID)
        _ = try await adapter.apiListSlashCommands(conversationID: conversationID)
        let modes = try await adapter.apiListModeProfiles()
        #expect(modes.isEmpty == false)

        try await adapter.apiResolveToolApproval(
            conversationID: conversationID,
            runID: nil,
            toolName: "example_tool",
            route: .user,
            status: .approved,
            source: "tests.adapter",
            reason: nil
        )
    }
}
