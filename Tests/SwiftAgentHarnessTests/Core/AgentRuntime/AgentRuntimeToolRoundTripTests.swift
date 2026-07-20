#if canImport(Darwin)
import Darwin
#endif
import Foundation
import Logging
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("AgentRuntime tool round trip")
struct AgentRuntimeToolRoundTripTests {
    @Test("chat-mode tool call round-trip persists transcript and publishes messagesRefresh")
    func chatToolRoundTripPersistsAndPublishes() async throws {
        let container = try section6Container()
        let model = section6Model()
        let scriptedLLM = ScriptedToolThenAnswerLLM(
            toolName: ConversationsToolProvider.listConversationsToolName,
            toolCallID: "call_chat_tool_roundtrip_1",
            finalAssistantText: "Tool run complete."
        )
        let manager = HarnessRuntimeSession(
            container: container,
            llmFactory: ScriptedLLMFactory(llm: scriptedLLM),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        let publisher = Section6ConversationEventCapture()
        await manager.setConversationTopicPublisher(publisher)
        try await manager.createConversation(
            with: model,
            userSystemPrompt: "chat-tool-roundtrip",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        let conversationID = try #require(await manager.currentConversationID)
        let refreshBaseline = await publisher.messagesRefreshRoles(for: conversationID).count

        let response = try await manager.sendMessageAndStreamResponse(
            "run the tool in chat mode",
            images: [],
            conversationID: conversationID
        )
        await awaitStreamingRunSettled(manager, response: response)
        try await expectListMessages(
            conversationID: conversationID,
            manager: manager,
            timeoutMS: 10_000
        ) { messages in
            messages.contains(where: { $0.role == .assistant && $0.content == "Tool run complete." })
                && messages.contains(where: { $0.role == .tool && $0.toolCallId == "call_chat_tool_roundtrip_1" })
        }
        await manager.testing_refreshProjectedConversationMessages(conversationID: conversationID)

        let lifecycle = await publisher.runtimeLifecycleEvents(for: conversationID)
        #expect(lifecycle.contains(where: { $0.name == .modelCallCompleted }))
        #expect(lifecycle.contains(where: { $0.name == .turnCompleted }))

        await expectMessagesRefresh(
            conversationID: conversationID,
            publisher: publisher,
            baselineRoleSnapshotCount: refreshBaseline
        ) { newRoleSnapshots in
            newRoleSnapshots.contains(where: { $0.contains("tool") && $0.last == "assistant" })
        }
        let toolCallIDSnapshots = await publisher.messagesRefreshToolCallIDs(for: conversationID)
        let newToolCallIDSnapshots = Array(toolCallIDSnapshots.dropFirst(refreshBaseline))
        #expect(newToolCallIDSnapshots.contains(where: { $0.contains("call_chat_tool_roundtrip_1") }))
        #expect(await scriptedLLM.observedStreamCallCount() == 3)
    }

    @Test("chat-mode tool call round-trip commits assistant via agent loop transcript append")
    func chatToolRoundTripCommitsAssistantViaAgentLoop() async throws {
        let container = try section6Container()
        let model = section6Model()
        let scriptedLLM = ScriptedToolThenAnswerLLM(
            toolName: ConversationsToolProvider.listConversationsToolName,
            toolCallID: "call_chat_agent_loop_1",
            finalAssistantText: "Agent loop transcript check."
        )
        let manager = HarnessRuntimeSession(
            container: container,
            llmFactory: ScriptedLLMFactory(llm: scriptedLLM),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        try await manager.createConversation(
            with: model,
            userSystemPrompt: "chat-agent-loop",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        let conversationID = try #require(await manager.currentConversationID)

        let response = try await manager.sendMessageAndStreamResponse(
            "run agent loop tool round trip",
            images: [],
            conversationID: conversationID
        )
        await awaitStreamingRunSettled(manager, response: response)

        try await expectListMessages(
            conversationID: conversationID,
            manager: manager,
            timeoutMS: 10_000
        ) { messages in
            messages.contains(where: { $0.role == .assistant && $0.content == "Agent loop transcript check." })
        }
    }

    @Test("chat-mode revert tool round-trip publishes assistant in messagesRefresh")
    func chatRevertToolRoundTripPublishesAssistant() async throws {
        let container = try section6Container()
        let model = section6Model()
        let userAnchorID = UUID()
        let harness = InMemoryHarnessSessionPersistence()

        let scriptedLLM = ScriptedToolThenAnswerLLM(
            toolName: ConversationsToolProvider.listConversationsToolName,
            toolCallID: "call_chat_revert_tool_roundtrip_1",
            finalAssistantText: "Revert tool run complete."
        )
        let manager = HarnessRuntimeSession(
            container: container,
            llmFactory: ScriptedLLMFactory(llm: scriptedLLM),
            harnessSessionPersistenceOverride: harness
        )
        let publisher = Section6ConversationEventCapture()
        await manager.setConversationTopicPublisher(publisher)
        try await manager.createConversation(
            with: model,
            userSystemPrompt: "chat-revert-tool-roundtrip",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        let conversationID = try #require(await manager.currentConversationID)
        await manager.appendMessagesToConversation(
            [Message(id: userAnchorID, role: .user, content: "run the tool via revert", timestamp: Date(), toolCalls: [])],
            conversationID: conversationID
        )
        try await manager.selectConversation(conversationID: conversationID)

        let snapshotsBefore = await publisher.messagesRefreshRoles(for: conversationID).count
        let response = try await manager.revertToUserMessageAndStreamResponse(
            conversationID: conversationID,
            messageID: userAnchorID
        )
        await awaitStreamingRunSettled(manager, response: response)
        try await expectListMessages(
            conversationID: conversationID,
            manager: manager,
            timeoutMS: 10_000
        ) { messages in
            messages.contains(where: { $0.role == .assistant && $0.content == "Revert tool run complete." })
                && messages.contains(where: { $0.role == .tool && $0.toolCallId == "call_chat_revert_tool_roundtrip_1" })
        }

        let roleSnapshots = await publisher.messagesRefreshRoles(for: conversationID)
        let newRoleSnapshots = Array(roleSnapshots.dropFirst(snapshotsBefore))
        #expect(newRoleSnapshots.contains(where: { $0.contains("tool") && $0.last == "assistant" }))
        let toolCallIDSnapshots = await publisher.messagesRefreshToolCallIDs(for: conversationID)
        let newToolCallIDSnapshots = Array(toolCallIDSnapshots.dropFirst(snapshotsBefore))
        #expect(newToolCallIDSnapshots.contains(where: { $0.contains("call_chat_revert_tool_roundtrip_1") }))
        #expect(await scriptedLLM.observedStreamCallCount() == 3)
    }

    @Test("revert publishes pruned messagesRefresh after high frontier")
    func revertPublishesPrunedProjectionAfterHighFrontier() async throws {
        let container = try section6Container()
        let model = section6Model()
        let userAnchorID = UUID()
        let prunedAssistantID = UUID()
        let scriptedLLM = ScriptedStreamingLLM(
            modelName: "revert-projection-llm",
            chunks: ["ok"],
            finalContent: "post-revert assistant",
            chunkDelayNanos: 5_000_000,
            finalDelayNanos: 5_000_000
        )
        let manager = HarnessRuntimeSession(
            container: container,
            llmFactory: ScriptedLLMFactory(llm: scriptedLLM),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        let publisher = Section6ConversationEventCapture()
        await manager.setConversationTopicPublisher(publisher)
        try await manager.createConversation(
            with: model,
            userSystemPrompt: "revert-projection",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        let conversationID = try #require(await manager.currentConversationID)
        await manager.appendMessagesToConversation(
            [
                Message(id: userAnchorID, role: .user, content: "keep me", timestamp: Date(), toolCalls: []),
                Message(id: prunedAssistantID, role: .assistant, content: "prune-me-after-revert", timestamp: Date(), toolCalls: []),
            ],
            conversationID: conversationID
        )
        try await manager.selectConversation(conversationID: conversationID)

        let beforeRevert = try await manager.listMessages(conversationID: conversationID)
        let expectedPrefixCount = try #require(
            beforeRevert.firstIndex(where: { $0.id == userAnchorID }).map { $0 + 1 }
        )

        await manager.testing_seedProjectionPublishState(
            conversationID: conversationID,
            frontierEventID: 99_999,
            contentHash: 0
        )
        let metricsBefore = await manager.contextProjectionService.projectionHardeningMetrics()
        let snapshotsBefore = await publisher.messagesRefreshRoles(for: conversationID).count

        let response = try await manager.revertToUserMessageAndStreamResponse(
            conversationID: conversationID,
            messageID: userAnchorID
        )
        #expect(response.runID != nil)

        await waitUntil(timeoutMS: 5_000) {
            let roles = await publisher.messagesRefreshRoles(for: conversationID)
            let newRoles = Array(roles.dropFirst(snapshotsBefore))
            return newRoles.contains { $0.count == expectedPrefixCount }
        }

        let metricsAfter = await manager.contextProjectionService.projectionHardeningMetrics()
        #expect(metricsAfter.staleProjectionDropCount == metricsBefore.staleProjectionDropCount)

        let roleSnapshots = await publisher.messagesRefreshRoles(for: conversationID)
        let newRoleSnapshots = Array(roleSnapshots.dropFirst(snapshotsBefore))
        #expect(newRoleSnapshots.contains(where: { $0.count == expectedPrefixCount }))

        await awaitStreamingRunSettled(manager, response: response, timeoutMS: 15_000)
        let settled = try await manager.listMessages(conversationID: conversationID)
        #expect(settled.contains { $0.id == userAnchorID })
        #expect(!settled.contains { $0.id == prunedAssistantID })
        #expect(!settled.contains { $0.content == "prune-me-after-revert" })
    }

    @Test("chat-mode tool timeout persists tool transcript and publishes terminal lifecycle")
    func chatToolTimeoutPersistsAndPublishesTerminal() async throws {
        let container = try section6Container()
        let model = section6Model()
        let scriptedLLM = ScriptedToolThenTimeoutLLM(
            toolName: ConversationsToolProvider.listConversationsToolName,
            toolCallID: "call_chat_tool_timeout_1"
        )
        let manager = HarnessRuntimeSession(
            container: container,
            llmFactory: ScriptedLLMFactory(llm: scriptedLLM),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        let publisher = Section6ConversationEventCapture()
        await manager.setConversationTopicPublisher(publisher)
        try await manager.createConversation(
            with: model,
            userSystemPrompt: "chat-tool-timeout",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        let conversationID = try #require(await manager.currentConversationID)

        let response = try await manager.sendMessageAndStreamResponse(
            "run timeout tool in chat mode",
            images: [],
            conversationID: conversationID
        )
        await awaitStreamingRunSettled(manager, response: response)

        try await expectListMessages(conversationID: conversationID, manager: manager) { messages in
            messages.contains(where: { $0.role == .tool && $0.toolCallId == "call_chat_tool_timeout_1" })
        }
        let messages = try await manager.listMessages(conversationID: conversationID)
        let hasTimeoutAssistant = messages.contains { $0.role == .assistant && $0.content.contains("timeout") }
        #expect(hasTimeoutAssistant == false)

        let lifecycle = await publisher.runtimeLifecycleEvents(for: conversationID)
        let terminalNames: Set<RuntimeLifecycleEventName> = [.turnCompleted, .turnCancelled, .turnBounded]
        #expect(lifecycle.contains(where: { terminalNames.contains($0.name) }))
        let terminal = lifecycle.last(where: { terminalNames.contains($0.name) })
        #expect(terminal?.terminalReason?.category == .failure)
        let terminalDetailHasTimeout = (terminal?.terminalReason?.detail ?? "")
            .localizedCaseInsensitiveContains("timeout")
        #expect(terminalDetailHasTimeout)

        let publishedRoleSnapshots = await publisher.messagesRefreshRoles(for: conversationID)
        #expect(publishedRoleSnapshots.contains(where: { $0.contains("tool") }))
        let publishedToolCallIDSnapshots = await publisher.messagesRefreshToolCallIDs(for: conversationID)
        #expect(publishedToolCallIDSnapshots.contains(where: { $0.contains("call_chat_tool_timeout_1") }))
        #expect(await scriptedLLM.observedStreamCallCount() >= 1)
    }

    @Test("chat-mode allows two tool rounds before final assistant response")
    func chatTwoToolRoundsReachFinalAssistant() async throws {
        let container = try section6Container()
        let model = section6Model()
        let scriptedLLM = ScriptedTwoToolsThenAnswerLLM(
            toolName: ConversationsToolProvider.listConversationsToolName,
            firstToolCallID: "call_chat_two_rounds_1",
            secondToolCallID: "call_chat_two_rounds_2",
            finalAssistantText: "Two rounds complete."
        )
        let manager = HarnessRuntimeSession(
            container: container,
            llmFactory: ScriptedLLMFactory(llm: scriptedLLM),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        try await manager.createConversation(
            with: model,
            userSystemPrompt: "chat-two-rounds",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        let conversationID = try #require(await manager.currentConversationID)

        let response = try await manager.sendMessageAndStreamResponse(
            "run two tool rounds",
            images: [],
            conversationID: conversationID
        )
        await awaitStreamingRunSettled(manager, response: response)

        try await expectListMessages(
            conversationID: conversationID,
            manager: manager,
            timeoutMS: 10_000
        ) { messages in
            messages.contains(where: { $0.role == .assistant && $0.content == "Two rounds complete." })
        }
        let messages = try await manager.listMessages(conversationID: conversationID)
        let hasFinalAssistant = messages.contains { message in
            message.role == .assistant && message.content == "Two rounds complete."
        }
        #expect(hasFinalAssistant)
        #expect(await scriptedLLM.observedStreamCallCount() == 4)
    }

}
