import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private enum Support {
    static func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    static func makeModel(name: String, protocol p: ModelProtocol = .ollama) -> Model {
        Model(
            protocol: p,
            modelName: name,
            serverURL: URL(string: "http://localhost:11434")!,
            capabilities: [],
            modelProtocol: p
        )
    }
}

@Suite("HarnessRuntimeSession model and user prompt updates", .serialized)
struct HarnessRuntimeSessionModelAndPromptUpdateTests {

    @Test("updateConversationModelAndUserPrompt swaps model in memory and SwiftData")
    func modelSwapPersists() async throws {
        let container = try Support.makeContainer()
        let modelA = Support.makeModel(name: "a:latest")
        let modelB = Support.makeModel(name: "b:latest")

        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        try await runtimeSession.createConversation(with: modelA, userSystemPrompt: "hello", topic: nil, description: nil, metadata: nil, interactionMode: .chat)
        let id = try #require(await runtimeSession.currentConversationID)

        try await runtimeSession.conversationDomainServices.controlPlane.updateConversationModelAndUserPrompt(
            conversationID: id,
            model: modelB,
            userSystemPrompt: nil
        )

        let conv = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == id }))
        #expect(conv.model.id == modelB.id)
        #expect(conv.model.modelName == "b:latest")
        #expect(conv.systemPrompt == "hello")

        let reloaded = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        try await reloaded.resetConversationsFromCatalog(availableModels: [modelA, modelB])
        let again = try #require(await reloaded.listConversationInfo().first(where: { $0.id == id }))
        #expect(again.model.id == modelB.id)
    }

    @Test("updateConversationModelAndUserPrompt updates system message and cached systemPrompt")
    func promptUpdatePersists() async throws {
        let container = try Support.makeContainer()
        let model = Support.makeModel(name: "m:latest")

        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "v1", topic: nil, description: nil, metadata: nil, interactionMode: .chat)
        let id = try #require(await runtimeSession.currentConversationID)

        try await runtimeSession.conversationDomainServices.controlPlane.updateConversationModelAndUserPrompt(
            conversationID: id,
            model: nil,
            userSystemPrompt: "v2"
        )

        let conv = try #require(await runtimeSession.listConversationInfo().first(where: { $0.id == id }))
        #expect(conv.systemPrompt == "v2")
        let sys = try #require(conv.messages.first(where: { $0.role == .system }))
        #expect(sys.content == "v2")

        let reloaded = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        try await reloaded.resetConversationsFromCatalog(availableModels: [model])
        let again = try #require(await reloaded.listConversationInfo().first(where: { $0.id == id }))
        #expect(again.systemPrompt == "v2")
        let sys2 = try #require(again.messages.first(where: { $0.role == .system }))
        #expect(sys2.content == "v2")
    }

    @Test("updateConversationModelAndUserPrompt refreshes currentMessages when that conversation is selected")
    func selectedConversationCurrentMessagesRefresh() async throws {
        let container = try Support.makeContainer()
        let model = Support.makeModel(name: "m:latest")

        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "orig", topic: nil, description: nil, metadata: nil, interactionMode: .chat)
        let id = try #require(await runtimeSession.currentConversationID)

        try await runtimeSession.selectConversation(conversationID: id)
        let before = try await runtimeSession.listCurrentMessages()
        let beforeSys = try #require(before.first(where: { $0.role == .system }))
        #expect(beforeSys.content == "orig")

        try await runtimeSession.conversationDomainServices.controlPlane.updateConversationModelAndUserPrompt(
            conversationID: id,
            model: nil,
            userSystemPrompt: "patched"
        )

        let after = try await runtimeSession.listCurrentMessages()
        let afterSys = try #require(after.first(where: { $0.role == .system }))
        #expect(afterSys.content == "patched")

        let published = await runtimeSession.currentMessages
        let pubSys = try #require(published.first(where: { $0.role == .system }))
        #expect(pubSys.content == "patched")
    }

    @Test("updateConversationModelAndUserPrompt updates harness transcript system payload on Local")
    func harnessPromptUpdatePersistsInTranscript() async throws {
        let fixture = try HarnessConversationTestFixtures.makeLocalPersistenceStack(label: "prompt-transcript")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = HarnessConversationTestFixtures.makeTestModel(name: "harness-prompt")
        let host = HarnessRuntimeSession(
            container: fixture.stack.modelContainer,
            harnessSessionPersistenceOverride: fixture.local
        )
        try await host.createConversation(
            with: model,
            userSystemPrompt: "v1",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        let id = try #require(await host.currentConversationID)

        try await host.conversationDomainServices.controlPlane.updateConversationModelAndUserPrompt(
            conversationID: id,
            model: nil,
            userSystemPrompt: "v2-harness"
        )

        let entries = try fixture.local.readTranscriptEntries(conversationID: id, request: .full)
        let systemEntry = try #require(entries.first(where: { $0.type == .system }))
        let replayed = try #require(try SessionTranscriptMapping.messageForReplay(from: systemEntry))
        #expect(replayed.content == "v2-harness")

        let reloaded = HarnessRuntimeSession(
            container: fixture.stack.modelContainer,
            harnessSessionPersistenceOverride: fixture.local
        )
        try await reloaded.resetConversationsFromCatalog(availableModels: [model])
        let again = try #require(await reloaded.listConversationInfo().first(where: { $0.id == id }))
        #expect(again.systemPrompt == "v2-harness")
        let sys2 = try #require(again.messages.first(where: { $0.role == .system }))
        #expect(sys2.content == "v2-harness")
    }

    @Test("updateConversationModelAndUserPrompt invalidates orchestrator bound to non-selected conversation")
    func boundConversationPromptUpdateInvalidatesOrchestrator() async throws {
        let container = try Support.makeContainer()
        let model = Support.makeModel(name: "m:latest")
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "conv-a", topic: nil, description: nil, metadata: nil, interactionMode: .chat)
        let conversationA = try #require(await runtimeSession.currentConversation())
        await runtimeSession.orchestratorRuntimeService.setupOrchestrator(with: model, activeConversation: conversationA)
        #expect(await runtimeSession.sessionOrchestratorConversationID() == conversationA.id)

        try await runtimeSession.createConversation(with: model, userSystemPrompt: "conv-b", topic: nil, description: nil, metadata: nil, interactionMode: .chat)
        let conversationB = try #require(await runtimeSession.currentConversation())
        #expect(conversationB.id != conversationA.id)
        #expect(await runtimeSession.sessionOrchestratorConversationID() == conversationB.id)

        try await runtimeSession.conversationDomainServices.controlPlane.updateConversationModelAndUserPrompt(
            conversationID: conversationA.id,
            model: nil,
            userSystemPrompt: "conv-a-updated"
        )

        #expect(await runtimeSession.agentRuntimeSessionService.orchestrator(for: conversationA.id) == nil)
        #expect(await runtimeSession.sessionOrchestratorConversationID() == conversationB.id)
    }

    @Test("updateConversationModelAndUserPrompt throws when nothing would change")
    func noOpThrows() async throws {
        let container = try Support.makeContainer()
        let model = Support.makeModel(name: "m:latest")
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "same", topic: nil, description: nil, metadata: nil, interactionMode: .chat)
        let id = try #require(await runtimeSession.currentConversationID)

        await #expect(throws: ConversationServiceError.noMeaningfulModelOrPromptChange) {
            try await runtimeSession.updateConversationModelAndUserPrompt(conversationID: id, model: nil, userSystemPrompt: "same")
        }
    }
}
