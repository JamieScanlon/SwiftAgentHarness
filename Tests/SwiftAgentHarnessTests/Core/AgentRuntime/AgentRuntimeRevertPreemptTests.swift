#if canImport(Darwin)
import Darwin
#endif
import Foundation
import Logging
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("AgentRuntime revert preempt", .serialized)
struct AgentRuntimeRevertPreemptTests {
    @Test("revert while generating settles prior run then starts revert run")
    func revertWhileGeneratingPreemptsToQuiescence() async throws {
        let container = try section6Container()
        let model = section6Model()
        let manager = HarnessRuntimeSession(
            container: container,
            llmFactory: ScriptedLLMFactory(
                llm: ScriptedStreamingLLM(
                    modelName: "revert-preempt-llm",
                    chunks: ["partial-a", "partial-b", "partial-c"],
                    finalContent: "assistant-final-should-not-persist",
                    chunkDelayNanos: 150_000_000,
                    finalDelayNanos: 150_000_000
                )
            ),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        try await manager.createConversation(with: model, userSystemPrompt: "revert-preempt")
        let conversationID = try #require(await manager.currentConversationID)

        let priorResponse = try await manager.sendMessageAndStreamResponse(
            "generate then revert",
            images: [],
            conversationID: conversationID
        )
        let priorRunID = try #require(priorResponse.runID)
        async let priorDrained = drainChatStreamOrchestration(priorResponse)

        await waitUntil(timeoutMS: 5_000) {
            let lifecycle = await manager.agentRuntimeSessionService.lifecycleSnapshot(for: conversationID)
            return lifecycle.generationTask != nil || lifecycle.isContentStreamingActive
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                for await partial in priorResponse.partialContent {
                    if case .text(let chunk) = partial, chunk.contains("partial-a") {
                        continuation.resume()
                        return
                    }
                }
                continuation.resume()
            }
        }

        let messagesBeforeRevert = try await manager.listMessages(conversationID: conversationID)
        let userAnchorID = try #require(
            messagesBeforeRevert.last(where: { $0.role == .user })?.id
        )

        let revertResponse = try await manager.revertToUserMessageAndStreamResponse(
            conversationID: conversationID,
            messageID: userAnchorID
        )
        let revertRunID = try #require(revertResponse.runID)
        #expect(revertRunID != priorRunID)

        let conversationDuringRevert = try #require(await manager.modelConversation(id: conversationID))
        #expect(conversationDuringRevert.currentRunID == revertRunID)

        await awaitStreamingRunSettled(manager, response: revertResponse, timeoutMS: 15_000)
        _ = await priorDrained
        _ = await drainChatStreamOrchestration(revertResponse)

        let messagesAfter = try await manager.listMessages(conversationID: conversationID)
        let userIndex = try #require(messagesAfter.firstIndex(where: { $0.id == userAnchorID }))
        #expect(messagesAfter[userIndex].role == .user)
        #expect(messagesAfter[userIndex].content.contains("generate then revert"))
        let trailing = Array(messagesAfter[(userIndex + 1)...])
        #expect(!trailing.contains(where: { $0.content.contains("assistant-final-should-not-persist") }))
        for message in trailing {
            #expect(message.role == .assistant || message.role == .tool || message.role == .system)
        }

        let settledConversation = try #require(await manager.modelConversation(id: conversationID))
        #expect(settledConversation.currentRunID == nil || settledConversation.currentRunID == revertRunID)
    }
}
