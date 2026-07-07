import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Mode transition tools")
struct ModeTransitionToolProviderTests {
    @Test("enter_plan_mode transitions conversation to plan")
    func enterPlanModeTransitionsConversation() async throws {
        let mock = MockModeTransitionDataProvider()
        let conversationID = UUID()
        mock.conversations[conversationID] = ModelConversation(
            id: conversationID,
            model: .testModel(),
            systemPrompt: "sys",
            interactionMode: .chat
        )
        let provider = ModeTransitionToolProvider(dataProvider: mock)
        let call = ToolCall(
            name: ModeTransitionToolProvider.enterPlanModeToolName,
            arguments: .object(["conversation_id": .string(conversationID.uuidString)]),
            id: "tc-1"
        )
        let result = try await provider.executeTool(call)
        #expect(result.success)
        #expect(mock.transitions.count == 1)
        #expect(mock.transitions[0].mode == .plan)
    }

    @Test("exit_plan_mode honors explicit target_mode")
    func exitPlanModeHonorsTarget() async throws {
        let mock = MockModeTransitionDataProvider()
        let conversationID = UUID()
        mock.conversations[conversationID] = ModelConversation(
            id: conversationID,
            model: .testModel(),
            systemPrompt: "sys",
            interactionMode: .plan
        )
        let provider = ModeTransitionToolProvider(dataProvider: mock)
        let call = ToolCall(
            name: ModeTransitionToolProvider.exitPlanModeToolName,
            arguments: .object([
                "conversation_id": .string(conversationID.uuidString),
                "target_mode": .string("chat"),
            ]),
            id: "tc-2"
        )
        let result = try await provider.executeTool(call)
        #expect(result.success)
        #expect(mock.transitions.count == 1)
        #expect(mock.transitions[0].mode == .chat)
    }

    @Test("mode transition tool reports transition failures")
    func modeTransitionFailureIsReturnedAsToolError() async throws {
        let mock = MockModeTransitionDataProvider()
        let conversationID = UUID()
        mock.conversations[conversationID] = ModelConversation(
            id: conversationID,
            model: .testModel(),
            systemPrompt: "sys",
            interactionMode: .chat
        )
        mock.error = NSError(domain: "mode.transition.tests", code: 42, userInfo: [NSLocalizedDescriptionKey: "mode_change_run_in_progress"])
        let provider = ModeTransitionToolProvider(dataProvider: mock)
        let call = ToolCall(
            name: ModeTransitionToolProvider.enterPlanModeToolName,
            arguments: .object(["conversation_id": .string(conversationID.uuidString)]),
            id: "tc-3"
        )
        let result = try await provider.executeTool(call)
        #expect(result.success == false)
        #expect(result.error?.contains("mode_change_run_in_progress") == true)
    }

    @Test("enter_plan_mode returns not found when data provider denies cross-owner access")
    func enterPlanModeCrossOwnerDenied() async throws {
        let mock = MockModeTransitionDataProvider()
        let ownerA = UUID()
        let ownerB = UUID()
        let conversationA = UUID()
        let conversationB = UUID()
        mock.conversations[conversationA] = ModelConversation(
            id: conversationA,
            model: .testModel(),
            systemPrompt: "sys",
            interactionMode: .chat,
            ownerAccountID: ownerA
        )
        mock.conversations[conversationB] = ModelConversation(
            id: conversationB,
            model: .testModel(),
            systemPrompt: "sys",
            interactionMode: .chat,
            ownerAccountID: ownerB
        )
        let provider = ModeTransitionToolProvider(dataProvider: mock)
        let scope = ConversationScope(
            selfID: conversationA,
            parentID: nil,
            rootID: conversationA,
            lineageKind: .root,
            origin: .user
        )
        let call = ToolCall(
            name: ModeTransitionToolProvider.enterPlanModeToolName,
            arguments: .object(["conversation_id": .string(conversationB.uuidString)]),
            id: "tc-cross-owner"
        )
        let result = try await ConversationScope.withCurrent(scope) {
            try await provider.executeTool(call)
        }
        #expect(result.success == false)
        #expect(result.error?.contains("Conversation not found") == true)
        #expect(mock.transitions.isEmpty)
    }

    @Test("deferred mode transition returns scheduled message")
    func deferredModeTransitionMessage() async throws {
        let mock = MockModeTransitionDataProvider()
        let conversationID = UUID()
        mock.conversations[conversationID] = ModelConversation(
            id: conversationID,
            model: .testModel(),
            systemPrompt: "sys",
            interactionMode: .plan
        )
        mock.transitionResult = .deferredUntilRunCompletes
        let provider = ModeTransitionToolProvider(dataProvider: mock)
        let call = ToolCall(
            name: ModeTransitionToolProvider.exitPlanModeToolName,
            arguments: .object(["conversation_id": .string(conversationID.uuidString)]),
            id: "tc-4"
        )
        let result = try await provider.executeTool(call)
        #expect(result.success)
        #expect(result.content.contains("scheduled"))
    }
}

private final class MockModeTransitionDataProvider: @unchecked Sendable, ModeTransitionDataProviding {
    struct Transition: Sendable {
        let conversationID: UUID
        let mode: InteractionMode
    }

    var conversations: [UUID: ModelConversation] = [:]
    var transitions: [Transition] = []
    var error: Swift.Error?
    var transitionResult: ModeTransitionApplyResult = .applied

    func getConversation(id: UUID) async -> ModelConversation? {
        guard let conv = conversations[id] else { return nil }
        guard let scope = ConversationScope.current,
              let caller = conversations[scope.selfID],
              let callerOwner = caller.ownerAccountID else {
            return conv
        }
        return conv.ownerAccountID == callerOwner ? conv : nil
    }

    func transitionConversationMode(
        conversationID: UUID,
        targetMode: InteractionMode,
        initiatedBy: String,
        reason: String?
    ) async throws -> ModeTransitionApplyResult {
        _ = initiatedBy
        _ = reason
        if let error {
            throw error
        }
        transitions.append(.init(conversationID: conversationID, mode: targetMode))
        return transitionResult
    }
}

private extension Model {
    static func testModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "mode-transition-test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
    }
}
