import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Termination tools")
struct TerminationToolProviderTests {
    @Test("finish succeeds for existing conversation")
    func finishSucceeds() async throws {
        let mock = MockTerminationConversationDataProvider()
        let conversationID = UUID()
        mock.conversations[conversationID] = ModelConversation(
            id: conversationID,
            model: makeTerminationTestModel(),
            systemPrompt: "sys",
            interactionMode: .agent
        )
        let provider = TerminationToolProvider(dataProvider: mock, logger: nil)
        let result = try await provider.executeTool(
            ToolCall(
                name: TerminationToolProvider.finishToolName,
                arguments: .object([
                    "conversation_id": .string(conversationID.uuidString),
                    "summary": .string("all tasks done"),
                ]),
                id: "finish-1"
            )
        )
        #expect(result.success)
        #expect(result.content.contains("Finished"))
    }

    @Test("ask_user returns structured metadata payload")
    func askUserReturnsStructuredMetadata() async throws {
        let mock = MockTerminationConversationDataProvider()
        let conversationID = UUID()
        mock.conversations[conversationID] = ModelConversation(
            id: conversationID,
            model: makeTerminationTestModel(),
            systemPrompt: "sys",
            interactionMode: .agent
        )
        let provider = TerminationToolProvider(dataProvider: mock, logger: nil)
        let optionsJSON = """
        [{"id":"approve","label":"Approve"},{"id":"decline","label":"Decline"}]
        """
        let result = try await provider.executeTool(
            ToolCall(
                name: TerminationToolProvider.askUserToolName,
                arguments: .object([
                    "conversation_id": .string(conversationID.uuidString),
                    "question": .string("Proceed with deploy?"),
                    "options": .string(optionsJSON),
                    "allow_multiple": .boolean(false),
                    "default_option_id": .string("approve"),
                ]),
                id: "ask-1"
            )
        )
        #expect(result.success)
        guard case .object(let metadata) = result.metadata else {
            Issue.record("missing metadata object")
            return
        }
        guard let askUserNode = metadata["askUser"],
              case .object(let askUser) = askUserNode
        else {
            Issue.record("missing askUser metadata")
            return
        }
        guard let questionNode = askUser["question"],
              case .string(let question) = questionNode
        else {
            Issue.record("missing question")
            return
        }
        #expect(question == "Proceed with deploy?")
        guard let allowMultipleNode = askUser["allowMultiple"],
              case .boolean(let allowMultiple) = allowMultipleNode
        else {
            Issue.record("missing allowMultiple")
            return
        }
        #expect(allowMultiple == false)
        if let optionsNode = askUser["options"], case .array(let options) = optionsNode {
            #expect(options.count == 2)
        } else {
            Issue.record("missing options array")
        }
    }

    @Test("ask_user validates options payload")
    func askUserValidatesOptions() async throws {
        let mock = MockTerminationConversationDataProvider()
        let conversationID = UUID()
        mock.conversations[conversationID] = ModelConversation(
            id: conversationID,
            model: makeTerminationTestModel(),
            systemPrompt: "sys",
            interactionMode: .agent
        )
        let provider = TerminationToolProvider(dataProvider: mock, logger: nil)
        let result = try await provider.executeTool(
            ToolCall(
                name: TerminationToolProvider.askUserToolName,
                arguments: .object([
                    "conversation_id": .string(conversationID.uuidString),
                    "question": .string("Proceed?"),
                    "options": .string("[]"),
                ]),
                id: "ask-2"
            )
        )
        #expect(result.success == false)
        #expect(result.error?.contains("at least two options") == true)
    }

    @Test("think succeeds and returns snapshot metadata")
    func thinkSucceedsWithSnapshot() async throws {
        let mock = MockTerminationConversationDataProvider()
        let conversationID = UUID()
        mock.conversations[conversationID] = ModelConversation(
            id: conversationID,
            model: makeTerminationTestModel(),
            systemPrompt: "sys",
            interactionMode: .plan
        )
        let provider = TerminationToolProvider(dataProvider: mock, logger: nil)
        let result = try await provider.executeTool(
            ToolCall(
                name: TerminationToolProvider.thinkToolName,
                arguments: .object([
                    "conversation_id": .string(conversationID.uuidString),
                    "snapshot": .string("Need to compare two migration paths."),
                ]),
                id: "think-1"
            )
        )
        #expect(result.success)
        #expect(result.content.contains("Thinking checkpoint"))
        guard case .object(let metadata) = result.metadata else {
            Issue.record("missing metadata object")
            return
        }
        guard let actionNode = metadata["action"], case .string(let action) = actionNode else {
            Issue.record("missing action")
            return
        }
        #expect(action == TerminationToolProvider.thinkToolName)
        guard let hasSnapshotNode = metadata["hasSnapshot"], case .boolean(let hasSnapshot) = hasSnapshotNode else {
            Issue.record("missing hasSnapshot")
            return
        }
        #expect(hasSnapshot)
    }

    @Test("think succeeds without snapshot")
    func thinkSucceedsWithoutSnapshot() async throws {
        let mock = MockTerminationConversationDataProvider()
        let conversationID = UUID()
        mock.conversations[conversationID] = ModelConversation(
            id: conversationID,
            model: makeTerminationTestModel(),
            systemPrompt: "sys",
            interactionMode: .plan
        )
        let provider = TerminationToolProvider(dataProvider: mock, logger: nil)
        let result = try await provider.executeTool(
            ToolCall(
                name: TerminationToolProvider.thinkToolName,
                arguments: .object([
                    "conversation_id": .string(conversationID.uuidString),
                ]),
                id: "think-2"
            )
        )
        #expect(result.success)
    }
}

private final class MockTerminationConversationDataProvider: @unchecked Sendable, ConversationsDataProviding {
    var conversations: [UUID: ModelConversation] = [:]

    func listConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] { [] }
    func getConversation(id: UUID) async -> ModelConversation? { conversations[id] }
    func switchConversation(id: UUID, message: String?) async throws -> String? {
        _ = id
        _ = message
        return nil
    }
}

private func makeTerminationTestModel() -> Model {
    Model(
        protocol: .openAIAPI,
        modelName: "termination-tool-test",
        serverURL: URL(string: "http://localhost:1234")!,
        capabilities: [.completion, .tools],
        modelProtocol: .openAIAPI
    )
}
