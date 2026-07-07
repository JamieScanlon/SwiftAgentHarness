
import EasyJSON
import Foundation
import SwiftAgentKit
import SwiftData
import Testing
@testable import SwiftAgentHarness

// MARK: - Stub Data Provider

private final class StubConversationsDataProvider: ConversationsDataProviding, @unchecked Sendable {
    var metadata: [ConversationMetadata] = []
    var conversations: [UUID: ModelConversation] = [:]
    var selectShouldThrow = false

    /// Records switchConversation calls for verification in tests
    var switchConversationCalls: [(id: UUID, message: String?)] = []

    func listConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] {
        metadata
    }

    func getConversation(id: UUID) async -> ModelConversation? {
        conversations[id]
    }

    func switchConversation(id: UUID, message: String?) async throws -> String? {
        switchConversationCalls.append((id, message))
        if selectShouldThrow {
            throw NSError(domain: "StubConversationsDataProvider", code: 404, userInfo: [NSLocalizedDescriptionKey: "conversation not found"])
        }
        guard conversations[id] != nil else {
            throw NSError(domain: "StubConversationsDataProvider", code: 404, userInfo: [NSLocalizedDescriptionKey: "conversation not found"])
        }
        guard let message, !message.isEmpty else { return nil }
        return nil
    }
}

/// Stub that simulates conversation updates when switchConversation sends a message.
/// Tracks "sent" messages to verify the flow that would update the conversation.
private final class RecordingSwitchProvider: ConversationsDataProviding, @unchecked Sendable {
    var conversations: [UUID: ModelConversation] = [:]
    var sentMessages: [(conversationId: UUID, message: String)] = []

    func listConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] { [] }
    func getConversation(id: UUID) async -> ModelConversation? { conversations[id] }

    func switchConversation(id: UUID, message: String?) async throws -> String? {
        if let message, !message.isEmpty {
            sentMessages.append((id, message))
            // Simulate conversation being updated: add user message to in-memory copy
            if var conv = conversations[id] {
                conv.messages.append(Message(id: UUID(), role: .user, content: message))
                conversations[id] = conv
            }
        }
        return nil
    }
}

// MARK: - Test Support

private enum ConversationsToolProviderTestSupport {
    static func makeContainer() throws -> ModelContainer {
                return try HarnessTestModelContainer.makeInMemory()
    }

    static func makeModel(name: String = "test-model") -> Model {
        Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: name,
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    static func makeConversation(
        id: UUID = UUID(),
        model: Model,
        messages: [Message] = [],
        topic: String? = nil,
        description: String? = nil
    ) -> ModelConversation {
        let now = Date()
        return ModelConversation(
            id: id,
            model: model,
            messages: messages,
            createdAt: now,
            updatedAt: now,
            topic: topic,
            description: description
        )
    }
}

// MARK: - Tests

@Suite("ConversationsToolProvider", .serialized)
struct ConversationsToolProviderTests {

    @Test("availableTools returns list_conversations, get_conversation, and switch_conversation")
    func availableTools() async throws {
        let provider = StubConversationsDataProvider()
        let toolProvider = ConversationsToolProvider(dataProvider: provider)

        let tools = await toolProvider.availableTools()

        let names = tools.map(\.name).sorted()
        #expect(names == ["get_conversation", "list_conversations", "switch_conversation"])

        let listTool = tools.first { $0.name == ConversationsToolProvider.listConversationsToolName }
        #expect(listTool != nil)
        #expect(listTool?.parameters.isEmpty == true)
        #expect((listTool?.description.isEmpty) == false)

        let getTool = tools.first { $0.name == ConversationsToolProvider.getConversationToolName }
        #expect(getTool != nil)
        #expect(getTool?.parameters.count == 3)
        #expect(getTool?.parameters.contains { $0.name == "id" && $0.required } == true)
        #expect(getTool?.parameters.contains { $0.name == "start_index" && !$0.required } == true)
        #expect(getTool?.parameters.contains { $0.name == "limit" && !$0.required } == true)

        let switchTool = tools.first { $0.name == ConversationsToolProvider.switchConversationToolName }
        #expect(switchTool != nil)
        #expect(switchTool?.parameters.count == 2)
        #expect(switchTool?.parameters.contains { $0.name == "id" && $0.required } == true)
        #expect(switchTool?.parameters.contains { $0.name == "message" && !$0.required } == true)
    }

    @Test("list_conversations returns empty array when no conversations")
    func listConversationsEmpty() async throws {
        let provider = StubConversationsDataProvider()
        provider.metadata = []
        let toolProvider = ConversationsToolProvider(dataProvider: provider)

        let toolCall = ToolCall(
            name: ConversationsToolProvider.listConversationsToolName,
            arguments: .object([:]),
            id: "list-empty"
        )

        let result = try await toolProvider.executeTool(toolCall)

        #expect(result.success == true)
        // JSON encoder uses prettyPrinted, so content may have newlines
        let parsed = try JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [Any]
        #expect(parsed?.isEmpty == true)
        #expect(result.toolCallId == "list-empty")
    }

    @Test("list_conversations returns metadata for existing conversations")
    func listConversationsWithData() async throws {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let now = Date()
        let nowStr = isoFormatter.string(from: now)

        let provider = StubConversationsDataProvider()
        provider.metadata = [
            ConversationMetadata(
                id: "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
                modelName: "test-model",
                topic: "Test topic",
                description: "Test description",
                messageCount: 5,
                createdAt: nowStr,
                updatedAt: nowStr
            ),
        ]
        let toolProvider = ConversationsToolProvider(dataProvider: provider)

        let toolCall = ToolCall(
            name: ConversationsToolProvider.listConversationsToolName,
            arguments: .object([:]),
            id: "list-data"
        )

        let result = try await toolProvider.executeTool(toolCall)

        #expect(result.success == true)
        #expect(result.content.contains("a1b2c3d4-e5f6-7890-abcd-ef1234567890"))
        #expect(result.content.contains("test-model"))
        #expect(result.content.contains("Test topic"))
        #expect(result.content.contains("Test description"))
        #expect(result.content.contains("5"))
    }

    @Test("list_conversations preserves provider ordering")
    func listConversationsPreservesOrder() async throws {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let nowStr = isoFormatter.string(from: Date())
        let provider = StubConversationsDataProvider()
        provider.metadata = [
            ConversationMetadata(
                id: "11111111-1111-1111-1111-111111111111",
                modelName: "first-model",
                topic: "First",
                description: nil,
                messageCount: 1,
                createdAt: nowStr,
                updatedAt: nowStr
            ),
            ConversationMetadata(
                id: "22222222-2222-2222-2222-222222222222",
                modelName: "second-model",
                topic: "Second",
                description: nil,
                messageCount: 2,
                createdAt: nowStr,
                updatedAt: nowStr
            ),
        ]
        let toolProvider = ConversationsToolProvider(dataProvider: provider)
        let result = try await toolProvider.executeTool(
            ToolCall(
                name: ConversationsToolProvider.listConversationsToolName,
                arguments: .object([:]),
                id: "list-ordered"
            )
        )
        #expect(result.success == true)
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [[String: Any]])
        #expect(payload.count == 2)
        #expect(payload[0]["id"] as? String == "11111111-1111-1111-1111-111111111111")
        #expect(payload[1]["id"] as? String == "22222222-2222-2222-2222-222222222222")
    }

    @Test("get_conversation returns full conversation with messages")
    func getConversationSuccess() async throws {
        let convID = UUID()
        let model = ConversationsToolProviderTestSupport.makeModel()
        let messages = [
            Message(id: UUID(), role: .user, content: "Hello", timestamp: Date()),
            Message(id: UUID(), role: .assistant, content: "Hi there!", timestamp: Date()),
        ]
        let conversation = ConversationsToolProviderTestSupport.makeConversation(
            id: convID,
            model: model,
            messages: messages,
            topic: "Greeting",
            description: "A simple greeting exchange"
        )

        let provider = StubConversationsDataProvider()
        provider.conversations[convID] = conversation
        let toolProvider = ConversationsToolProvider(dataProvider: provider)

        let toolCall = ToolCall(
            name: ConversationsToolProvider.getConversationToolName,
            arguments: .object(["id": .string(convID.uuidString)]),
            id: "get-1"
        )

        let result = try await toolProvider.executeTool(toolCall)

        #expect(result.success == true)
        #expect(result.content.contains(convID.uuidString))
        #expect(result.content.contains("test-model"))
        #expect(result.content.contains("Greeting"))
        #expect(result.content.contains("Hello"))
        #expect(result.content.contains("Hi there!"))
        #expect(result.content.contains("user"))
        #expect(result.content.contains("assistant"))

        let payload = try JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any]
        #expect(payload?["totalMessageCount"] as? Int == 2)
        let msgs = payload?["messages"] as? [Any]
        #expect(msgs?.count == 2)
    }

    @Test("get_conversation returns at most 25 messages with totalMessageCount for full thread")
    func getConversationCapsLimitAt25() async throws {
        let convID = UUID()
        let model = ConversationsToolProviderTestSupport.makeModel()
        let messages = (0..<30).map { i in
            Message(id: UUID(), role: .user, content: "m\(i)", timestamp: Date())
        }
        let conversation = ConversationsToolProviderTestSupport.makeConversation(
            id: convID,
            model: model,
            messages: messages
        )

        let provider = StubConversationsDataProvider()
        provider.conversations[convID] = conversation
        let toolProvider = ConversationsToolProvider(dataProvider: provider)

        let toolCall = ToolCall(
            name: ConversationsToolProvider.getConversationToolName,
            arguments: .object(["id": .string(convID.uuidString)]),
            id: "get-cap"
        )

        let result = try await toolProvider.executeTool(toolCall)

        #expect(result.success == true)
        let payload = try JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any]
        #expect(payload?["totalMessageCount"] as? Int == 30)
        let msgs = payload?["messages"] as? [Any]
        #expect(msgs?.count == 25)
    }

    @Test("get_conversation paginates with start_index")
    func getConversationPagination() async throws {
        let convID = UUID()
        let model = ConversationsToolProviderTestSupport.makeModel()
        let messages = (0..<10).map { i in
            Message(id: UUID(), role: .user, content: "m\(i)", timestamp: Date())
        }
        let conversation = ConversationsToolProviderTestSupport.makeConversation(
            id: convID,
            model: model,
            messages: messages
        )

        let provider = StubConversationsDataProvider()
        provider.conversations[convID] = conversation
        let toolProvider = ConversationsToolProvider(dataProvider: provider)

        let toolCall = ToolCall(
            name: ConversationsToolProvider.getConversationToolName,
            arguments: .object([
                "id": .string(convID.uuidString),
                "start_index": .integer(5),
            ]),
            id: "get-page"
        )

        let result = try await toolProvider.executeTool(toolCall)

        #expect(result.success == true)
        let payload = try JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any]
        #expect(payload?["totalMessageCount"] as? Int == 10)
        let msgs = payload?["messages"] as? [[String: Any]]
        #expect(msgs?.count == 5)
        #expect(msgs?.first?["content"] as? String == "m5")
        #expect(msgs?.last?["content"] as? String == "m9")
    }

    @Test("get_conversation clamps limit to 25 when above maximum")
    func getConversationClampsHighLimit() async throws {
        let convID = UUID()
        let model = ConversationsToolProviderTestSupport.makeModel()
        let messages = (0..<30).map { i in
            Message(id: UUID(), role: .user, content: "m\(i)", timestamp: Date())
        }
        let conversation = ConversationsToolProviderTestSupport.makeConversation(
            id: convID,
            model: model,
            messages: messages
        )

        let provider = StubConversationsDataProvider()
        provider.conversations[convID] = conversation
        let toolProvider = ConversationsToolProvider(dataProvider: provider)

        let toolCall = ToolCall(
            name: ConversationsToolProvider.getConversationToolName,
            arguments: .object([
                "id": .string(convID.uuidString),
                "limit": .integer(100),
            ]),
            id: "get-clamp-limit"
        )

        let result = try await toolProvider.executeTool(toolCall)

        #expect(result.success == true)
        let payload = try JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any]
        #expect(payload?["totalMessageCount"] as? Int == 30)
        let msgs = payload?["messages"] as? [Any]
        #expect(msgs?.count == 25)
        if case .object(let meta) = result.metadata,
           let rc = meta["returnedCount"],
           case .integer(25) = rc {
        } else {
            Issue.record("Expected returnedCount 25 in metadata")
        }
    }

    @Test("get_conversation returns empty messages when start_index past end but totalMessageCount preserved")
    func getConversationStartPastEnd() async throws {
        let convID = UUID()
        let model = ConversationsToolProviderTestSupport.makeModel()
        let messages = (0..<10).map { i in
            Message(id: UUID(), role: .user, content: "m\(i)", timestamp: Date())
        }
        let conversation = ConversationsToolProviderTestSupport.makeConversation(
            id: convID,
            model: model,
            messages: messages
        )

        let provider = StubConversationsDataProvider()
        provider.conversations[convID] = conversation
        let toolProvider = ConversationsToolProvider(dataProvider: provider)

        let toolCall = ToolCall(
            name: ConversationsToolProvider.getConversationToolName,
            arguments: .object([
                "id": .string(convID.uuidString),
                "start_index": .integer(100),
            ]),
            id: "get-past-end"
        )

        let result = try await toolProvider.executeTool(toolCall)

        #expect(result.success == true)
        let payload = try JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any]
        #expect(payload?["totalMessageCount"] as? Int == 10)
        let msgs = payload?["messages"] as? [Any]
        #expect(msgs?.isEmpty == true)
        if case .object(let meta) = result.metadata,
           let rc = meta["returnedCount"],
           case .integer(0) = rc {
        } else {
            Issue.record("Expected returnedCount 0 in metadata")
        }
    }

    @Test("get_conversation returns failure when conversation not found")
    func getConversationNotFound() async throws {
        let provider = StubConversationsDataProvider()
        provider.conversations = [:]
        let toolProvider = ConversationsToolProvider(dataProvider: provider)

        let missingID = UUID()
        let toolCall = ToolCall(
            name: ConversationsToolProvider.getConversationToolName,
            arguments: .object(["id": .string(missingID.uuidString)]),
            id: "get-not-found"
        )

        let result = try await toolProvider.executeTool(toolCall)

        #expect(result.success == false)
        #expect(result.error?.contains("Conversation not found") == true)
        #expect(result.error?.contains(missingID.uuidString) == true)
    }

    @Test("get_conversation returns failure for invalid UUID")
    func getConversationInvalidUUID() async throws {
        let provider = StubConversationsDataProvider()
        let toolProvider = ConversationsToolProvider(dataProvider: provider)

        let toolCall = ToolCall(
            name: ConversationsToolProvider.getConversationToolName,
            arguments: .object(["id": .string("not-a-valid-uuid")]),
            id: "get-invalid"
        )

        let result = try await toolProvider.executeTool(toolCall)

        #expect(result.success == false)
        #expect(result.error?.contains("Invalid conversation ID") == true)
    }

    @Test("get_conversation throws for missing id parameter")
    func getConversationMissingIdParam() async throws {
        let provider = StubConversationsDataProvider()
        let toolProvider = ConversationsToolProvider(dataProvider: provider)

        let toolCall = ToolCall(
            name: ConversationsToolProvider.getConversationToolName,
            arguments: .object([:]),
            id: "get-missing-param"
        )

        do {
            _ = try await toolProvider.executeTool(toolCall)
            Issue.record("Expected ConversationsToolProvider.Error.missingParameter")
        } catch ConversationsToolProvider.Error.missingParameter(let param) {
            #expect(param == "id")
        }
    }

    @Test("switch_conversation without message switches and returns success")
    func switchConversationWithoutMessage() async throws {
        let convID = UUID()
        let model = ConversationsToolProviderTestSupport.makeModel()
        let conversation = ConversationsToolProviderTestSupport.makeConversation(id: convID, model: model)
        let provider = StubConversationsDataProvider()
        provider.conversations[convID] = conversation
        let toolProvider = ConversationsToolProvider(dataProvider: provider)

        let toolCall = ToolCall(
            name: ConversationsToolProvider.switchConversationToolName,
            arguments: .object(["id": .string(convID.uuidString)]),
            id: "switch-1"
        )

        let result = try await toolProvider.executeTool(toolCall)

        #expect(result.success == true)
        #expect(result.content.contains("Switched to conversation"))
        #expect(result.content.contains(convID.uuidString))
    }

    @Test("switch_conversation with message returns success immediately")
    func switchConversationWithMessage() async throws {
        let convID = UUID()
        let model = ConversationsToolProviderTestSupport.makeModel()
        let conversation = ConversationsToolProviderTestSupport.makeConversation(id: convID, model: model)
        let provider = StubConversationsDataProvider()
        provider.conversations[convID] = conversation
        let toolProvider = ConversationsToolProvider(dataProvider: provider)

        let toolCall = ToolCall(
            name: ConversationsToolProvider.switchConversationToolName,
            arguments: .object([
                "id": .string(convID.uuidString),
                "message": .string("Hello, please respond.")
            ]),
            id: "switch-2"
        )

        let result = try await toolProvider.executeTool(toolCall)

        #expect(result.success == true)
        #expect(result.content.contains("Switched to conversation"))
        #expect(result.content.contains("sent message"))
    }

    @Test("switch_conversation returns failure for invalid UUID")
    func switchConversationInvalidUUID() async throws {
        let provider = StubConversationsDataProvider()
        let toolProvider = ConversationsToolProvider(dataProvider: provider)

        let toolCall = ToolCall(
            name: ConversationsToolProvider.switchConversationToolName,
            arguments: .object(["id": .string("not-a-uuid")]),
            id: "switch-invalid"
        )

        let result = try await toolProvider.executeTool(toolCall)

        #expect(result.success == false)
        #expect(result.error?.contains("Invalid conversation ID") == true)
    }

    @Test("switch_conversation throws for missing id parameter")
    func switchConversationMissingIdParam() async throws {
        let provider = StubConversationsDataProvider()
        let toolProvider = ConversationsToolProvider(dataProvider: provider)

        let toolCall = ToolCall(
            name: ConversationsToolProvider.switchConversationToolName,
            arguments: .object(["message": .string("hello")]),
            id: "switch-missing-id"
        )

        do {
            _ = try await toolProvider.executeTool(toolCall)
            Issue.record("Expected ConversationsToolProvider.Error.missingParameter")
        } catch ConversationsToolProvider.Error.missingParameter(let param) {
            #expect(param == "id")
        }
    }

    @Test("switch_conversation invokes data provider with correct id and message")
    func switchConversationInvokesProvider() async throws {
        let convID = UUID()
        let model = ConversationsToolProviderTestSupport.makeModel()
        let conversation = ConversationsToolProviderTestSupport.makeConversation(id: convID, model: model)
        let provider = StubConversationsDataProvider()
        provider.conversations[convID] = conversation
        let toolProvider = ConversationsToolProvider(dataProvider: provider)

        let toolCall = ToolCall(
            name: ConversationsToolProvider.switchConversationToolName,
            arguments: .object([
                "id": .string(convID.uuidString),
                "message": .string("Please summarize this.")
            ]),
            id: "switch-invoke"
        )

        _ = try await toolProvider.executeTool(toolCall)

        #expect(provider.switchConversationCalls.count == 1)
        #expect(provider.switchConversationCalls[0].id == convID)
        #expect(provider.switchConversationCalls[0].message == "Please summarize this.")
    }

    @Test("switch_conversation with message updates conversation in provider")
    func switchConversationUpdatesConversation() async throws {
        let convID = UUID()
        let model = ConversationsToolProviderTestSupport.makeModel()
        let conversation = ConversationsToolProviderTestSupport.makeConversation(id: convID, model: model)
        let provider = RecordingSwitchProvider()
        provider.conversations[convID] = conversation
        let toolProvider = ConversationsToolProvider(dataProvider: provider)

        let toolCall = ToolCall(
            name: ConversationsToolProvider.switchConversationToolName,
            arguments: .object([
                "id": .string(convID.uuidString),
                "message": .string("Add this to the thread")
            ]),
            id: "switch-update"
        )

        _ = try await toolProvider.executeTool(toolCall)

        #expect(provider.sentMessages.count == 1)
        #expect(provider.sentMessages[0].conversationId == convID)
        #expect(provider.sentMessages[0].message == "Add this to the thread")
        let updated = await provider.getConversation(id: convID)
        #expect(updated?.messages.contains { $0.role == .user && $0.content == "Add this to the thread" } == true)
    }

    @Test("switch_conversation returns failure when conversation not found")
    func switchConversationNotFound() async throws {
        let provider = StubConversationsDataProvider()
        provider.conversations = [:]
        let missingID = UUID()
        let toolProvider = ConversationsToolProvider(dataProvider: provider)

        let toolCall = ToolCall(
            name: ConversationsToolProvider.switchConversationToolName,
            arguments: .object(["id": .string(missingID.uuidString)]),
            id: "switch-not-found"
        )

        let result = try await toolProvider.executeTool(toolCall)

        #expect(result.success == false)
        #expect(result.error != nil)
    }

    @Test("unknown tool throws")
    func unknownToolThrows() async throws {
        let provider = StubConversationsDataProvider()
        let toolProvider = ConversationsToolProvider(dataProvider: provider)

        let toolCall = ToolCall(
            name: "unknown_tool",
            arguments: .object([:]),
            id: "unknown"
        )

        do {
            _ = try await toolProvider.executeTool(toolCall)
            Issue.record("Expected ConversationsToolProvider.Error.unknownTool")
        } catch ConversationsToolProvider.Error.unknownTool(let name) {
            #expect(name == "unknown_tool")
        }
    }

    // MARK: - Integration with HarnessRuntimeSession

    @Test("HarnessRuntimeSession conforms to ConversationsDataProviding and list_conversations works")
    func runtimeSessionListConversations() async throws {
        let container = try ConversationsToolProviderTestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = ConversationsToolProviderTestSupport.makeModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys", topic: "Integration test", description: nil)

        let toolProvider = ConversationsToolProvider(
            dataProvider: await runtimeSession.conversationToolDataService
        )
        let toolCall = ToolCall(
            name: ConversationsToolProvider.listConversationsToolName,
            arguments: .object([:]),
            id: "chat-list"
        )

        let result = try await toolProvider.executeTool(toolCall)

        #expect(result.success == true)
        #expect(result.content.contains("Integration test"))
        #expect(result.content.contains("test-model"))
    }

    @Test("HarnessRuntimeSession switch_conversation with message adds user message to conversation")
    func runtimeSessionSwitchConversationWithMessageAddsUserMessage() async throws {
        let container = try ConversationsToolProviderTestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = ConversationsToolProviderTestSupport.makeModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys")
        let convID = try #require(await runtimeSession.currentConversationID)

        let toolProvider = ConversationsToolProvider(
            dataProvider: await runtimeSession.conversationToolDataService
        )
        let toolCall = ToolCall(
            name: ConversationsToolProvider.switchConversationToolName,
            arguments: .object([
                "id": .string(convID.uuidString),
                "message": .string("User message from switch_conversation")
            ]),
            id: "chat-switch-msg"
        )

        let result = try await toolProvider.executeTool(toolCall)
        #expect(result.success == true)

        // User message is added synchronously before sendMessageAndStreamResponse returns.
        // Verify the conversation now contains the user message.
        let conversation = await await makeSplitConversationAdapter(runtimeSession: runtimeSession).apiGetConversation(id: convID)
        #expect(conversation?.messages.contains { $0.role == .user && $0.content == "User message from switch_conversation" } == true)
    }

    @Test("HarnessRuntimeSession switch_conversation without message switches current conversation")
    func runtimeSessionSwitchConversation() async throws {
        let container = try ConversationsToolProviderTestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = ConversationsToolProviderTestSupport.makeModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys1")
        let conv1ID = try #require(await runtimeSession.currentConversationID)
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys2")
        let conv2ID = try #require(await runtimeSession.currentConversationID)
        #expect(await runtimeSession.currentConversationID == conv2ID)

        let toolProvider = ConversationsToolProvider(
            dataProvider: await runtimeSession.conversationToolDataService
        )
        let toolCall = ToolCall(
            name: ConversationsToolProvider.switchConversationToolName,
            arguments: .object(["id": .string(conv1ID.uuidString)]),
            id: "chat-switch"
        )

        let result = try await toolProvider.executeTool(toolCall)

        #expect(result.success == true)
        #expect(await runtimeSession.currentConversationID == conv1ID)
    }

    @Test("HarnessRuntimeSession get_conversation returns conversation with messages")
    func runtimeSessionGetConversation() async throws {
        let container = try ConversationsToolProviderTestSupport.makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = ConversationsToolProviderTestSupport.makeModel()
        try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys")
        let convID = try #require(await runtimeSession.currentConversationID)

        // createConversation adds a system message with userSystemPrompt
        let toolProvider = ConversationsToolProvider(
            dataProvider: await runtimeSession.conversationToolDataService
        )
        let toolCall = ToolCall(
            name: ConversationsToolProvider.getConversationToolName,
            arguments: .object(["id": .string(convID.uuidString)]),
            id: "chat-get"
        )

        let result = try await toolProvider.executeTool(toolCall)

        #expect(result.success == true)
        #expect(result.content.contains(convID.uuidString))
        #expect(result.content.contains("sys"))
        #expect(result.content.contains("system"))
    }
}
