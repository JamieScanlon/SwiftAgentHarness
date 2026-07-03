import EasyJSON
import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

// MARK: - Helpers

private func makeInMemoryContainer() throws -> ModelContainer {
        return try HarnessTestModelContainer.makeInMemory()
}

private func makeModel(name: String = "test:latest") -> Model {
    Model(
        protocol: .ollama,
        modelName: name,
        serverURL: URL(string: "http://localhost:11434")!,
        capabilities: [],
        modelProtocol: .ollama
    )
}

// MARK: - Tests

@Suite("HarnessRuntimeSession tool call persistence", .serialized)
struct HarnessRuntimeSessionToolCallPersistenceTests {

    // MARK: - Loading full tool call data (toolCallItems)

    @Test("resetConversationsFromCatalog loads full tool call data when toolCallItems is populated")
    func loadsFullToolCallDataFromToolCallItems() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "tool-call-items")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel(name: "test:latest")
        let assistant = Message(
            id: UUID(),
            role: .assistant,
            content: "I'll search",
            timestamp: Date(),
            toolCalls: [
                ToolCall(
                    name: "search",
                    arguments: .object(["query": .string("test query")]),
                    instructions: "Search for test query",
                    id: "call_abc123"
                ),
                ToolCall(
                    name: "get_weather",
                    arguments: .object(["location": .string("London")]),
                    instructions: "",
                    id: "call_def456"
                ),
            ]
        )
        _ = try await HarnessConversationTestFixtures.seedRegistryConversation(
            host: fixture.host,
            model: model,
            extraMessages: [assistant]
        )
        let runtimeSession = fixture.host

        let conversations = await runtimeSession.listConversationInfo()
        #expect(conversations.count == 1)
        let assistantMsg = conversations[0].messages.first { $0.role == .assistant }
        #expect(assistantMsg != nil)
        #expect(assistantMsg?.toolCalls.count == 2)

        let searchCall = assistantMsg?.toolCalls.first { $0.name == "search" }
        let weatherCall = assistantMsg?.toolCalls.first { $0.name == "get_weather" }

        #expect(searchCall?.id == "call_abc123")
        #expect(searchCall?.name == "search")
        #expect(searchCall?.instructions == "Search for test query")

        #expect(weatherCall?.id == "call_def456")
        #expect(weatherCall?.name == "get_weather")
        #expect(weatherCall?.instructions == "")

        // Verify arguments round-trip
        if let searchCall {
            let encoded = try? JSONEncoder().encode(searchCall.arguments)
            let jsonString = encoded.flatMap { String(data: $0, encoding: .utf8) }
            #expect(jsonString?.contains("test query") == true)
        }
    }

    // MARK: - Loading legacy tool calls (fallback)

    @Test("resetConversationsFromCatalog loads legacy tool call names from thin transcript payload")
    func loadsLegacyToolCallNamesFromThinTranscript() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "legacy-tool-names")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel(name: "test:latest")
        try await fixture.host.createConversation(with: model, userSystemPrompt: "System")
        let conversationID = try #require(await fixture.host.currentConversationID)
        let assistant = Message(
            id: UUID(),
            role: .assistant,
            content: "Assistant",
            timestamp: Date(),
            toolCalls: []
        )
        try HarnessConversationTestFixtures.appendThinTranscriptMessage(
            local: fixture.local,
            conversationID: conversationID,
            message: assistant,
            toolCallNames: ["legacy_tool_a", "legacy_tool_b"]
        )
        try await fixture.host.resetConversationsFromCatalog(availableModels: [model])

        let assistantMsg = (await fixture.host.listConversationInfo())[0].messages.first { $0.role == .assistant }
        #expect(assistantMsg?.toolCalls.count == 2)
        #expect(assistantMsg?.toolCalls.map(\.name).sorted() == ["legacy_tool_a", "legacy_tool_b"])
    }

    // MARK: - Copy preserves full tool call data

    @Test("copyConversation preserves full tool call data (id, name, arguments, instructions)")
    func copyPreservesFullToolCallData() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "copy-tool-full")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel(name: "source:latest")
        let assistant = Message(
            id: UUID(),
            role: .assistant,
            content: "Running skill",
            timestamp: Date(),
            toolCalls: [
                ToolCall(
                    name: "skill_tool",
                    arguments: .object(["skill_name": .string("pdf-processing")]),
                    instructions: "Extract text",
                    id: "id_1"
                ),
            ]
        )
        let sourceConversationID = try await HarnessConversationTestFixtures.seedRegistryConversation(
            host: fixture.host,
            model: model,
            extraMessages: [assistant]
        )

        let targetModel = makeModel(name: "target:latest")
        try await fixture.host.copyConversation(from: sourceConversationID, to: targetModel, systemPrompt: "New")

        let copied = (await fixture.host.listConversationInfo()).first { $0.modelName == "target:latest" }!
        let copiedAssistant = copied.messages.first { $0.role == .assistant }
        #expect(copiedAssistant != nil)
        #expect(copiedAssistant?.toolCalls.count == 1)

        let toolCall = copiedAssistant!.toolCalls[0]
        #expect(toolCall.id == "id_1")
        #expect(toolCall.name == "skill_tool")
        #expect(toolCall.instructions == "Extract text")
    }

    @Test("copyConversation preserves multiple full tool calls")
    func copyPreservesMultipleFullToolCalls() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "copy-tool-multi")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel(name: "source:latest")
        let assistant = Message(
            id: UUID(),
            role: .assistant,
            content: "Both tools",
            timestamp: Date(),
            toolCalls: [
                ToolCall(name: "tool_a", arguments: .object([:]), instructions: "A", id: "a"),
                ToolCall(name: "tool_b", arguments: .object(["x": .double(1)]), instructions: "B", id: "b"),
            ]
        )
        let sourceConversationID = try await HarnessConversationTestFixtures.seedRegistryConversation(
            host: fixture.host,
            model: model,
            extraMessages: [assistant]
        )

        let targetModel = makeModel(name: "target:latest")
        try await fixture.host.copyConversation(from: sourceConversationID, to: targetModel, systemPrompt: "New")

        let copied = (await fixture.host.listConversationInfo()).first { $0.modelName == "target:latest" }!
        let assistantMsg = copied.messages.first { $0.role == .assistant }
        #expect(assistantMsg?.toolCalls.count == 2)

        let names = assistantMsg?.toolCalls.map(\.name).sorted() ?? []
        #expect(names == ["tool_a", "tool_b"])

        let toolA = assistantMsg?.toolCalls.first { $0.name == "tool_a" }
        let toolB = assistantMsg?.toolCalls.first { $0.name == "tool_b" }
        #expect(toolA?.id == "a")
        #expect(toolA?.instructions == "A")
        #expect(toolB?.id == "b")
        #expect(toolB?.instructions == "B")
    }

    // MARK: - Empty / edge cases

    @Test("resetConversationsFromCatalog handles messages with no tool calls")
    func handlesMessagesWithNoToolCalls() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "no-tool-calls")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel(name: "test:latest")
        _ = try await HarnessConversationTestFixtures.seedRegistryConversation(
            host: fixture.host,
            model: model,
            extraMessages: [Message(id: UUID(), role: .user, content: "Hi", timestamp: Date(), toolCalls: [])]
        )

        let conversations = await fixture.host.listConversationInfo()
        #expect(conversations.count == 1)
        let userMsg = conversations[0].messages.first { $0.role == .user }
        #expect(userMsg != nil)
        #expect(userMsg?.toolCalls.isEmpty == true)
    }

    @Test("resetConversationsFromCatalog restores tool message toolCallId from cache")
    func loadsToolResultToolCallId() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "tool-call-id")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel(name: "test:latest")
        _ = try await HarnessConversationTestFixtures.seedRegistryConversationWithStaggeredMessages(
            host: fixture.host,
            model: model
        )

        let toolMsg = (await fixture.host.listConversationInfo())[0].messages.first { $0.role == .tool }
        #expect(toolMsg != nil)
        #expect(toolMsg?.toolCallId == "tc-1")
    }

    @Test("tool calls without id load with generated identity on hydrate")
    func loadsToolCallWithNilId() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "tool-nil-id")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel(name: "test:latest")
        let assistant = Message(
            id: UUID(),
            role: .assistant,
            content: "Content",
            timestamp: Date(),
            toolCalls: [ToolCall(name: "no_id_tool", arguments: .object([:]), instructions: "No ID", id: nil)]
        )
        _ = try await HarnessConversationTestFixtures.seedRegistryConversation(
            host: fixture.host,
            model: model,
            extraMessages: [assistant]
        )

        let assistantMsg = (await fixture.host.listConversationInfo())[0].messages.first { $0.role == .assistant }
        #expect(assistantMsg?.toolCalls.count == 1)
        #expect(assistantMsg?.toolCalls.first?.name == "no_id_tool")
        #expect(assistantMsg?.toolCalls.first?.instructions == "No ID")
    }

    // MARK: - Tool message toolCallId (save / recall / copy / split)

    @Test("testing_applyOrchestratorMessages persists toolCallId and resetConversationsFromCatalog restores it")
    func orchestratorAppendPersistsToolCallIdRoundTrip() async throws {
        let container = try makeInMemoryContainer()
        let harness = InMemoryHarnessSessionPersistence()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: harness)
        let model = makeModel(name: "persist-tool:latest")
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys")
        let conversationID = try #require(await runtimeSession.currentConversationID)

        let toolCallId = "call_orchestrator_roundtrip_1"
        let toolMessage = Message(
            id: UUID(),
            role: .tool,
            content: "tool output",
            timestamp: Date(),
            toolCalls: [],
            toolCallId: toolCallId
        )
        await runtimeSession.testing_applyOrchestratorMessages([toolMessage])

        let entries = try harness.readTranscriptEntries(conversationID: conversationID, request: .full)
        let toolPayloads = entries.compactMap { try? SessionTranscriptMapping.messageForReplay(from: $0) }
            .filter { $0.role == .tool }
        #expect(toolPayloads.map(\.toolCallId) == [toolCallId])

        let reloaded = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: harness)
        try await reloaded.resetConversationsFromCatalog(availableModels: [model])
        let toolMsg = try #require(
            await reloaded.listConversationInfo().first(where: { $0.id == conversationID })?.messages.first { $0.role == .tool }
        )
        #expect(toolMsg.toolCallId == toolCallId)
    }

    @Test("copyConversation preserves tool message toolCallId")
    func copyPreservesToolResultToolCallId() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "copy-tool-id")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceModel = makeModel(name: "source-copy-tool:latest")
        let sourceConversationID = try await HarnessConversationTestFixtures.seedRegistryConversationWithStaggeredMessages(
            host: fixture.host,
            model: sourceModel
        )

        let targetModel = makeModel(name: "target-copy-tool:latest")
        try await fixture.host.copyConversation(from: sourceConversationID, to: targetModel, systemPrompt: "New")

        let copiedID = try #require(await fixture.host.currentConversationID)
        let copiedTool = try #require(
            await fixture.host.listConversationInfo().first(where: { $0.id == copiedID })?.messages.first { $0.role == .tool }
        )
        #expect(copiedTool.toolCallId == "tc-1")
    }

    @Test("testing_persistSplitConversationAtUserMessage preserves tool message toolCallId on the new branch")
    func splitPreservesToolResultToolCallId() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sha-toolcall-split-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let container = try makeInMemoryContainer()
        let model = makeModel(name: "split-tool:latest")
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: local
        )
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "S")
        let sourceConversationID = try #require(await runtimeSession.currentConversationID)

        let t0 = Date()
        let userA = Message(
            id: UUID(),
            role: .user,
            content: "first",
            timestamp: t0.addingTimeInterval(1),
            toolCalls: []
        )
        let assistant = Message(
            id: UUID(),
            role: .assistant,
            content: "Calling",
            timestamp: t0.addingTimeInterval(2),
            toolCalls: []
        )
        let toolCallId = "call_split_preserve_1"
        let toolMessage = Message(
            id: UUID(),
            role: .tool,
            content: "tool out",
            timestamp: t0.addingTimeInterval(3),
            toolCalls: [],
            toolCallId: toolCallId
        )
        let userB = Message(
            id: UUID(),
            role: .user,
            content: "anchor",
            timestamp: t0.addingTimeInterval(4),
            toolCalls: []
        )
        await runtimeSession.appendMessagesToConversation([userA, assistant, toolMessage, userB], conversationID: sourceConversationID)

        let newConversationID = try await runtimeSession.testing_persistSplitConversationAtUserMessage(
            sourceConversationID: sourceConversationID,
            messageID: userB.id
        )

        let splitEntries = try local.readTranscriptEntries(conversationID: newConversationID, request: .full)
        let splitIds = splitEntries.compactMap { try? SessionTranscriptMapping.messageForReplay(from: $0) }
            .filter { $0.role == .tool }
            .compactMap(\.toolCallId)
        #expect(splitIds == [toolCallId])

        let splitTool = try #require(
            await runtimeSession.listConversationInfo().first(where: { $0.id == newConversationID })?.messages.first { $0.role == .tool }
        )
        #expect(splitTool.toolCallId == toolCallId)
    }
}
