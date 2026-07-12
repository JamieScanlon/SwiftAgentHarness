import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ConversationReplayRunner")
struct ConversationReplayRunnerTests {
    @Test("messageBatches wraps each message in its own batch")
    func messageBatchesOnePerMessage() {
        let messages = [
            Message(id: UUID(), role: .user, content: "u1"),
            Message(id: UUID(), role: .assistant, content: "a1"),
        ]
        let batches = ConversationReplayRunner.messageBatches(from: messages)
        #expect(batches.count == 2)
        #expect(batches[0].first?.content == "u1")
        #expect(batches[1].first?.content == "a1")
    }

    @Test("toolCall matches assistant tool call by toolCallId")
    func toolCallMatchesById() {
        let toolCall = ToolCall(name: "search", arguments: .object([:]), id: "tc-1")
        let assistant = Message(id: UUID(), role: .assistant, content: "", toolCalls: [toolCall])
        let tool = Message(id: UUID(), role: .tool, content: "result", toolCallId: "tc-1")
        let resolved = ConversationReplayRunner.toolCall(for: tool, replayedMessages: [assistant])
        #expect(resolved.name == "search")
        #expect(resolved.id == "tc-1")
    }

    @Test("toolCall falls back to synthetic replay_tool when id not found")
    func toolCallSyntheticWhenIdMissing() {
        let tool = Message(id: UUID(), role: .tool, content: "x", toolCallId: "missing")
        let resolved = ConversationReplayRunner.toolCall(for: tool, replayedMessages: [])
        #expect(resolved.name == "replay_tool")
        #expect(resolved.id == "missing")
    }

    @Test("toolCall prefers newer assistant when multiple matches exist")
    func toolCallPrefersNewerAssistantMatch() {
        let older = ToolCall(name: "older", arguments: .object([:]), id: "tc-1")
        let newer = ToolCall(name: "newer", arguments: .object([:]), id: "tc-1")
        let replayed = [
            Message(id: UUID(), role: .assistant, content: "", toolCalls: [older]),
            Message(id: UUID(), role: .assistant, content: "", toolCalls: [newer]),
        ]
        let tool = Message(id: UUID(), role: .tool, content: "r", toolCallId: "tc-1")
        let resolved = ConversationReplayRunner.toolCall(for: tool, replayedMessages: replayed)
        #expect(resolved.name == "newer")
    }

    @Test("toolCall without id uses last tool call on most recent assistant")
    func toolCallUsesMostRecentAssistantLastToolCall() {
        let old = ToolCall(name: "old", arguments: .object([:]), id: "a")
        let recent = ToolCall(name: "recent", arguments: .object([:]), id: "b")
        let replayed = [
            Message(id: UUID(), role: .assistant, content: "", toolCalls: [old]),
            Message(id: UUID(), role: .assistant, content: "", toolCalls: [recent]),
        ]
        let tool = Message(id: UUID(), role: .tool, content: "r")
        let resolved = ConversationReplayRunner.toolCall(for: tool, replayedMessages: replayed)
        #expect(resolved.name == "recent")
    }

    @Test("toolCall without id and no assistants returns synthetic replay_tool")
    func toolCallSyntheticWhenNoAssistants() {
        let tool = Message(id: UUID(), role: .tool, content: "r")
        let resolved = ConversationReplayRunner.toolCall(for: tool, replayedMessages: [])
        #expect(resolved.name == "replay_tool")
        #expect(resolved.id == nil)
    }
}
