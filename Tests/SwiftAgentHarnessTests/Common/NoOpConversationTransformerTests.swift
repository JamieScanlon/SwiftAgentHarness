import Foundation
import EasyJSON
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("NoOpConversationTransformer")
struct NoOpConversationTransformerTests {
    private func makeConversationMeta() -> ConversationTransformMetadata {
        ConversationTransformMetadata(
            conversationID: UUID(),
            modelID: "model-id",
            modelName: "model-name",
            interactionMode: .chat,
            routingPolicyTools: [],
            routingPolicySkills: [],
            thinkingEnabled: true,
            reasoningEffort: nil,
            metadata: .object(["key": .string("value")])
        )
    }

    @Test("transformContext returns original messages")
    func contextNoOp() async throws {
        let transformer = NoOpConversationTransformer()
        let messages = [
            Message(id: UUID(), role: .user, content: "hello", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "world", timestamp: Date(), toolCalls: []),
        ]
        let output = try await transformer.transformContext(
            ContextTransformInput(messages: messages, conversation: makeConversationMeta(), phase: .initial)
        )
        #expect(output.messages.map(\.id) == messages.map(\.id))
        #expect(output.messageProvenance?.count == messages.count)
        #expect(output.messageProvenance?.allSatisfy { $0.origin == .original } == true)
    }

    @Test("transformToolResult returns original result")
    func toolResultNoOp() async throws {
        let transformer = NoOpConversationTransformer()
        let toolCall = ToolCall(name: "web-fetch", arguments: .object([:]), id: UUID().uuidString)
        let result = ToolResult(success: true, content: "large content", metadata: .object([:]), toolCallId: toolCall.id)
        let output = try await transformer.transformToolResult(
            ToolResultTransformInput(toolCall: toolCall, result: result, conversation: makeConversationMeta())
        )
        #expect(output.result.content == result.content)
        #expect(output.result.toolCallId == result.toolCallId)
    }

    @Test("transformTurnSummary preserves full turn messages")
    func turnSummaryNoOp() async throws {
        let transformer = NoOpConversationTransformer()
        let turnMessages = [
            Message(id: UUID(), role: .user, content: "do work", timestamp: Date(), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "done", timestamp: Date(), toolCalls: []),
        ]
        let output = try await transformer.transformTurnSummary(
            TurnSummaryTransformInput(
                conversation: makeConversationMeta(),
                turnMessageRangeStartIndex: 0,
                turnMessages: turnMessages
            )
        )
        #expect(output.replacementTurnMessages.map(\.id) == turnMessages.map(\.id))
    }
}
