import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("SubAgentCompletionRuntimeService")
struct SubAgentCompletionRuntimeServiceTests {
    @Test("resolvePendingCompletionConversationID finds tool call in persisted conversation")
    func resolvePendingCompletionByToolCallID() async throws {
                let container = try HarnessTestModelContainer.makeInMemory()
        let host = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        let model = Model(
            protocol: .openAIAPI,
            modelName: "completion-resolve-test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
        try await host.createConversation(with: model, userSystemPrompt: "completion-resolve")
        let conversationID = try #require(await host.currentConversationID)
        let toolCallID = "tool-call-\(UUID().uuidString)"
        _ = try await host.saveMessageToCache(
            Message(
                id: UUID(),
                role: .assistant,
                content: "",
                timestamp: Date(),
                toolCalls: [ToolCall(name: "delegate_test", arguments: .object([:]), id: toolCallID)]
            ),
            for: conversationID
        )

        let resolved = await host.subAgentCompletionRuntimeService.resolvePendingCompletionConversationID(
            toolCallID: toolCallID
        )
        #expect(resolved == conversationID)
    }

    @Test("A payload retained across a restart is re-appended by the retry, not lost to fallback")
    func retainedPayloadSurvivesRestart() async throws {
        let container = try HarnessTestModelContainer.makeInMemory()
        let host = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        let model = Model(
            protocol: .openAIAPI,
            modelName: "completion-restart-test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
        try await host.createConversation(with: model, userSystemPrompt: "completion-restart")
        let conversationID = try #require(await host.currentConversationID)
        _ = try await host.saveMessageToCache(
            Message(id: UUID(), role: .user, content: "kick off the delegate", timestamp: Date()),
            for: conversationID
        )

        let notification = Message(
            id: UUID(),
            role: .assistant,
            content: "<task-notification>delegate_explore finished</task-notification>",
            timestamp: Date()
        )
        let announce = CompletionAnnouncePayload(
            delegateHandleID: "handle-restart",
            toolCallID: "call-restart",
            conversationID: conversationID,
            lifecycleID: "handle-restart",
            status: .done,
            completedAt: Date(),
            source: "subAgentPool.localAgent"
        )
        // The row a process restart leaves behind: the lifecycle event published, the content did
        // not land. In-memory state is gone, so the persisted payload is the only way back.
        try await host.persistenceDomain.routingPersistCompletionAnnounceEventAsync(
            conversationID: conversationID,
            payload: CompletionAnnounceEventPayload(
                announce: announce,
                runtimePublished: true,
                subagentPublished: false,
                retryCount: 1,
                deliveryState: "pending",
                pendingNotification: CompletionAnnounceNotificationPayload(message: notification),
                createdAt: Date()
            )
        )

        await host.subAgentCompletionRuntimeService.reconcileUnresolvedCompletionAnnouncementsOnStartup()
        await host.subAgentCompletionRuntimeService.retryPendingCompletionAnnouncements()

        let messages = await host.modelConversation(id: conversationID)?.messages ?? []
        #expect(messages.contains { $0.id == notification.id })
        #expect(messages.contains { $0.content == notification.content })
    }
}
