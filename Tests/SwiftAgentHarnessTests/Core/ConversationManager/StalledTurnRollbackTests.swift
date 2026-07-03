import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Stalled-turn rollback")
struct StalledTurnRollbackTests {

    @Test("rollbackLatestAssistantTurnForRuntime removes assistant from registry and persisted transcript")
    func rollbackRemovesAssistantFromRegistryAndPersistence() async throws {
        let fixture = try HarnessConversationTestFixtures.makeInMemoryHarnessRuntimeHost()
        let domain = fixture.domain
        let model = HarnessConversationTestFixtures.makeTestModel()
        let conv = try await domain.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .agent
        )
        try await domain.resetConversationsFromCatalog(availableModels: [model])

        let user = Message(id: UUID(), role: .user, content: "question", timestamp: Date())
        let assistant = Message(id: UUID(), role: .assistant, content: "stalled", timestamp: Date().addingTimeInterval(1))
        _ = try await domain.routingSaveMessage(
            user,
            for: conv.id,
            resourceManager: nil,
            logger: nil,
            expectedPreviousTailHarnessMessageID: nil,
            transcriptRunID: nil
        )
        _ = try await domain.routingSaveMessage(
            assistant,
            for: conv.id,
            resourceManager: nil,
            logger: nil,
            expectedPreviousTailHarnessMessageID: nil,
            transcriptRunID: UUID()
        )

        let messaging = await fixture.host.conversationMessagingRuntimeService
        await messaging.rollbackLatestAssistantTurnForRuntime(
            conversationID: conv.id,
            assistantMessageID: assistant.id
        )

        let registryRow = await domain.modelConversation(id: conv.id)
        #expect(registryRow?.messages.contains(where: { $0.id == assistant.id }) == false)
        #expect(registryRow?.messages.contains(where: { $0.id == user.id }) == true)

        let harness = fixture.stack.conversationManager.harnessSessionPersistence
        let activeMessages = try ConversationTranscriptLineage.activeMessages(
            conversationID: conv.id,
            harness: harness
        )
        #expect(activeMessages.contains(where: { $0.id == assistant.id }) == false)
        #expect(activeMessages.contains(where: { $0.id == user.id }) == true)

        try HarnessConversationTestFixtures.resetRegistryFromCatalog(
            manager: fixture.stack.conversationManager,
            availableModels: [model]
        )
        let reloaded = try #require(fixture.stack.conversationManager.modelConversation(id: conv.id))
        #expect(reloaded.messages.contains(where: { $0.id == assistant.id }) == false)
        #expect(reloaded.messages.contains(where: { $0.id == user.id }) == true)
    }

    @Test("rollbackLatestAssistantTurnForRuntime no-ops when assistant is not active tail")
    func rollbackNoOpsWhenAssistantIsNotTail() async throws {
        let fixture = try HarnessConversationTestFixtures.makeInMemoryHarnessRuntimeHost()
        let domain = fixture.domain
        let model = HarnessConversationTestFixtures.makeTestModel()
        let conv = try await domain.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .agent
        )
        try await domain.resetConversationsFromCatalog(availableModels: [model])

        let user1 = Message(id: UUID(), role: .user, content: "first", timestamp: Date())
        let stalledAssistant = Message(
            id: UUID(),
            role: .assistant,
            content: "stalled",
            timestamp: Date().addingTimeInterval(1)
        )
        let user2 = Message(id: UUID(), role: .user, content: "second", timestamp: Date().addingTimeInterval(2))
        let tailAssistant = Message(
            id: UUID(),
            role: .assistant,
            content: "tail",
            timestamp: Date().addingTimeInterval(3)
        )
        for message in [user1, stalledAssistant, user2, tailAssistant] {
            _ = try await domain.routingSaveMessage(
                message,
                for: conv.id,
                resourceManager: nil,
                logger: nil,
                expectedPreviousTailHarnessMessageID: nil,
                transcriptRunID: nil
            )
        }

        let messaging = await fixture.host.conversationMessagingRuntimeService
        await messaging.rollbackLatestAssistantTurnForRuntime(
            conversationID: conv.id,
            assistantMessageID: stalledAssistant.id
        )

        let registryRow = await domain.modelConversation(id: conv.id)
        #expect(registryRow?.messages.contains(where: { $0.id == stalledAssistant.id }) == true)
        #expect(registryRow?.messages.contains(where: { $0.id == tailAssistant.id }) == true)

        let harness = fixture.stack.conversationManager.harnessSessionPersistence
        let activeMessages = try ConversationTranscriptLineage.activeMessages(
            conversationID: conv.id,
            harness: harness
        )
        #expect(activeMessages.last?.id == tailAssistant.id)
        #expect(activeMessages.contains(where: { $0.id == stalledAssistant.id }) == true)
    }
}
