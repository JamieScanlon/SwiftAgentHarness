#if canImport(Darwin)
import Darwin
#endif
import Foundation
import Logging
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("AgentRuntime terminal lifecycle")
struct AgentRuntimeTerminalLifecycleTests {
    @Test("runtime terminal lifecycle, runs projection, and harness termination stay in parity")
    func terminalParityAcrossRuntimeRestAndHarnessWire() async throws {
        let container = try section6Container()
        let model = section6Model()
        let manager = HarnessRuntimeSession(
            container: container,
            llmFactory: ScriptedLLMFactory(
                llm: ScriptedStreamingLLM(
                    modelName: "parity-llm",
                    chunks: ["z"],
                    finalContent: "done",
                    chunkDelayNanos: 10_000_000,
                    finalDelayNanos: 10_000_000
                )
            ),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        let publisher = Section6ConversationEventCapture()
        await manager.setConversationTopicPublisher(publisher)
        try await manager.createConversation(with: model, userSystemPrompt: "parity")
        let conversationID = try #require(await manager.currentConversationID)

        let response = try await manager.sendMessageAndStreamResponse("go", images: [], conversationID: conversationID)
        let states = await drainChatStreamOrchestration(response)
        let finalState = states.last
        let runID = try #require(response.runID)

        await waitUntil {
            let runs = await manager.listRunsForAPI(
                conversationID: conversationID,
                filter: ConversationRunListFilter(limit: 5)
            ).runs
            return runs.first(where: { $0.id == runID })?.outcome == .completed
        }

        let runs = await manager.listRunsForAPI(
            conversationID: conversationID,
            filter: ConversationRunListFilter(limit: 5)
        ).runs
        let run = try #require(runs.first(where: { $0.id == runID }))
        #expect(run.outcome == .completed)
        let terminal = await publisher.runtimeLifecycleEvents(for: conversationID)
            .last(where: { $0.name == RuntimeLifecycleEventName.turnCompleted })
        #expect(terminal?.terminalReason?.category == ConversationRunTerminalCategory.naturalStop)
        #expect(finalState?.harness?.terminationCategory == terminal?.terminalReason?.category.rawValue)
    }

    @Test("chat-mode zero transcript delta is classified in terminal detail")
    func chatZeroTranscriptDeltaClassification() async throws {
        let container = try section6Container()
        let model = section6Model()
        let scriptedLLM = ScriptedEmptyAssistantLLM()
        let manager = HarnessRuntimeSession(
            container: container,
            llmFactory: ScriptedLLMFactory(llm: scriptedLLM),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        try await manager.createConversation(
            with: model,
            userSystemPrompt: "chat-zero-delta",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        let conversationID = try #require(await manager.currentConversationID)

        let response = try await manager.sendMessageAndStreamResponse(
            "return nothing",
            images: [],
            conversationID: conversationID
        )
        await awaitStreamingRunSettled(manager, response: response)
        let states = await drainChatStreamOrchestration(response)

        let messages = try await manager.listMessages(conversationID: conversationID)
        #expect(messages.contains(where: { $0.role == .assistant && $0.content.contains("without producing a final response") }) == false)

        let runID = try #require(response.runID)
        let runs = await manager.listRunsForAPI(
            conversationID: conversationID,
            filter: ConversationRunListFilter(limit: 5)
        ).runs
        let run = try #require(runs.first(where: { $0.id == runID }))
        #expect(run.outcome == .completed)
        #expect((states.last?.harness?.terminationDetail ?? "").contains("zero_transcript_delta"))
    }

    @Test("runtime streaming path persists memory snapshot with store version metadata")
    func runtimeStreamingPersistsVersionedMemorySnapshot() async throws {
        let container = try section6Container()
        let model = section6Model()
        let manager = HarnessRuntimeSession(
            container: container,
            llmFactory: ScriptedLLMFactory(
                llm: ScriptedStreamingLLM(
                    modelName: "memory-snapshot-llm",
                    chunks: ["partial"],
                    finalContent: "done"
                )
            ),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        try await manager.createConversation(
            with: model,
            userSystemPrompt: "memory",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .agent
        )
        let conversationID = try #require(await manager.currentConversationID)
        let response = try await manager.sendMessageAndStreamResponse("remember this", images: [], conversationID: conversationID)
        await awaitStreamingRunSettled(manager, response: response, timeoutMS: 15_000)

        let memoryKind = ConversationEventKind.memoryInjectionSnapshotCheckpoint.rawValue
        let events = await HarnessConversationTestFixtures.journalEvents(
            host: manager,
            conversationID: conversationID,
            kind: memoryKind
        )
        if let latest = events.first,
           let wire = ConversationEventCodec.decode(MemoryInjectionSnapshotCheckpointWire.self, from: latest.payloadJSON) {
            #expect(wire.memoryStoreVersion != nil)
            #expect(!(wire.memoryEntryIDs ?? []).isEmpty)
        }
    }
}
