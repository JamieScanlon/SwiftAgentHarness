#if canImport(Darwin)
import Darwin
#endif
import Foundation
import Logging
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("AgentRuntime dual conversation isolation")
struct AgentRuntimeDualConversationIsolationTests {
    @Test("dual-conversation concurrent streaming keeps assistant transcripts isolated")
    func dualConversationConcurrentStreamingIsolation() async throws {
        let container = try section6Container()
        let model = section6Model()
        let harness = InMemoryHarnessSessionPersistence()
        let publisher = Section6ConversationEventCapture()
        let manager1 = HarnessRuntimeSession(
            container: container,
            llmFactory: ScriptedLLMFactory(
                llm: ScriptedStreamingLLM(
                    modelName: "llm-one",
                    chunks: [],
                    finalContent: "assistant-one",
                    chunkDelayNanos: 30_000_000,
                    finalDelayNanos: 60_000_000
                )
            ),
            harnessSessionPersistenceOverride: harness
        )
        let manager2 = HarnessRuntimeSession(
            container: container,
            llmFactory: ScriptedLLMFactory(
                llm: ScriptedStreamingLLM(
                    modelName: "llm-two",
                    chunks: [],
                    finalContent: "assistant-two",
                    chunkDelayNanos: 30_000_000,
                    finalDelayNanos: 60_000_000
                )
            ),
            harnessSessionPersistenceOverride: harness
        )
        await manager1.setConversationTopicPublisher(publisher)
        await manager2.setConversationTopicPublisher(publisher)
        try await manager1.createConversation(with: model, userSystemPrompt: "sys-1", topic: nil, description: nil, metadata: nil, interactionMode: .chat)
        let conversationID1 = try #require(await manager1.currentConversationID)
        try await manager1.createConversation(with: model, userSystemPrompt: "sys-2", topic: nil, description: nil, metadata: nil, interactionMode: .chat)
        let conversationID2 = try #require(await manager1.currentConversationID)
        try await manager1.resetConversationsFromCatalog(availableModels: [model])
        try await manager2.resetConversationsFromCatalog(availableModels: [model])
        try await manager1.selectConversation(conversationID: conversationID1)
        try await manager2.selectConversation(conversationID: conversationID2)

        // Transcript-derived runs + runtime lifecycle envelopes are covered by other tests in this suite and ``RunLifecycleDurabilityTests`` (harness fixtures).

        async let response1 = manager1.sendMessageAndStreamResponse(
            "one",
            images: [],
            conversationID: conversationID1
        )
        async let response2 = manager2.sendMessageAndStreamResponse(
            "two",
            images: [],
            conversationID: conversationID2
        )
        let stream1 = try await response1
        let stream2 = try await response2
        async let settled1 = awaitStreamingRunSettled(manager1, response: stream1)
        async let settled2 = awaitStreamingRunSettled(manager2, response: stream2)
        await settled1
        await settled2

        await waitUntil(timeoutMS: 10_000) {
            let messages = (try? await manager1.listMessages(conversationID: conversationID1)) ?? []
            return messages.contains(where: { $0.role == .assistant && $0.content == "assistant-one" })
        }
        await waitUntil(timeoutMS: 10_000) {
            let messages = (try? await manager2.listMessages(conversationID: conversationID2)) ?? []
            return messages.contains(where: { $0.role == .assistant && $0.content == "assistant-two" })
        }

        let messages1 = try await manager1.listMessages(conversationID: conversationID1)
        let messages2 = try await manager2.listMessages(conversationID: conversationID2)
        #expect(messages1.contains(where: { $0.role == MessageRole.assistant && $0.content == "assistant-one" }))
        #expect(messages2.contains(where: { $0.role == MessageRole.assistant && $0.content == "assistant-two" }))
        #expect(!messages1.contains(where: { $0.content.contains("assistant-two") }))
        #expect(!messages2.contains(where: { $0.content.contains("assistant-one") }))
    }

}
