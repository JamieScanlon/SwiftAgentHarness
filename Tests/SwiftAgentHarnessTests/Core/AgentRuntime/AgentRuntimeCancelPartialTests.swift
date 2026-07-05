#if canImport(Darwin)
import Darwin
#endif
import Foundation
import Logging
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("AgentRuntime cancel partial", .serialized)
struct AgentRuntimeCancelPartialTests {
    @Test("cancelled run persists interrupted partial assistant and cancellation marker")
    func cancelledRunPersistsInterruptedPartialAssistant() async throws {
        let container = try section6Container()
        let model = section6Model()
        let manager = HarnessRuntimeSession(
            container: container,
            llmFactory: ScriptedLLMFactory(
                llm: ScriptedStreamingLLM(
                    modelName: "cancel-llm",
                    chunks: ["partial-a", "partial-b"],
                    finalContent: "assistant-final-should-not-persist",
                    chunkDelayNanos: 150_000_000,
                    finalDelayNanos: 150_000_000
                )
            ),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        let publisher = Section6ConversationEventCapture()
        await manager.setConversationTopicPublisher(publisher)
        try await manager.createConversation(with: model, userSystemPrompt: "cancel-test")
        let conversationID = try #require(await manager.currentConversationID)

        let response = try await manager.sendMessageAndStreamResponse("cancel me", images: [], conversationID: conversationID)
        async let drainedTask = drainChatStreamOrchestration(response)
        async let partialArrived: Void = {
            for await partial in response.partialContent {
                if case .text(let chunk) = partial, chunk.contains("partial-a") {
                    return
                }
            }
        }()
        await waitUntil(timeoutMS: 5_000) {
            let lifecycle = await manager.agentRuntimeSessionService.lifecycleSnapshot(for: conversationID)
            return lifecycle.generationTask != nil || lifecycle.isContentStreamingActive
        }
        try await partialArrived
        let runID = try #require(response.runID)
        try await manager.cancelActiveRunForAPI(conversationID: conversationID, runID: runID)

        await waitUntil {
            let runs = await manager.listRunsForAPI(
                conversationID: conversationID,
                filter: ConversationRunListFilter(limit: 5)
            ).runs
            return runs.first(where: { $0.id == runID })?.outcome == .cancelled
        }

        let runs = await manager.listRunsForAPI(
            conversationID: conversationID,
            filter: ConversationRunListFilter(limit: 5)
        ).runs
        let cancelled = try #require(runs.first(where: { $0.id == runID }))
        #expect(cancelled.outcome == .cancelled)
        #expect(cancelled.cancellationReason?.contains("task_cancelled") == true)

        await waitUntil(timeoutMS: 10_000) {
            let messages = (try? await manager.listCurrentMessages()) ?? []
            return messages.contains {
                $0.role == MessageRole.assistant && $0.content.contains("partial-a")
            }
        }
        let messages = try await manager.listCurrentMessages()
        let partialAssistant = try #require(
            messages.first(where: { $0.role == MessageRole.assistant })
        )
        #expect(partialAssistant.content.contains("partial-a"))
        #expect(!partialAssistant.content.contains("assistant-final-should-not-persist"))

        let states = await drainedTask
        let finalState = states.last
        #expect(finalState?.harness?.terminationCategory == ConversationRunTerminalCategory.externalCancellation.rawValue)
        #expect(finalState?.harness?.terminationDetail == "task_cancelled")

        let lifecycle = await publisher.runtimeLifecycleEvents(for: conversationID)
        let terminalLifecycle = lifecycle.last(where: { $0.name == RuntimeLifecycleEventName.turnCancelled })
        #expect(terminalLifecycle != nil)
        #expect(terminalLifecycle?.terminalReason?.category == .externalCancellation)
    }

}
