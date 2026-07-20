import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ReplayLLM")
struct ReplayLLMTests {
    @Test("nextMessageBatch returns scripted batches in order")
    func nextMessageBatchInOrder() async throws {
        let m1 = Message(id: UUID(), role: .assistant, content: "one")
        let m2 = Message(id: UUID(), role: .tool, content: "two")
        let llm = ReplayLLM(messageBatches: [[m1], [m2]])

        let first = await llm.nextMessageBatch()
        let second = await llm.nextMessageBatch()
        let third = await llm.nextMessageBatch()

        #expect(first?.first?.content == "one")
        #expect(second?.first?.content == "two")
        #expect(third == nil)
    }

    @Test("send uses scripted assistant response")
    func sendReturnsScriptedAssistantMessage() async throws {
        let toolCall = ToolCall(name: "search", arguments: .object([:]), id: "tc-1")
        let assistant = Message(
            id: UUID(),
            role: .assistant,
            content: "assistant replay",
            toolCalls: [toolCall]
        )
        let llm = ReplayLLM(messageBatches: [[assistant]])
        let response = try await llm.send([], config: LLMRequestConfig())
        #expect(response.content == "assistant replay")
        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls.first?.name == "search")
    }

    @Test("peekNextMessageBatch does not advance cursor")
    func peekDoesNotAdvanceCursor() async {
        let m1 = Message(id: UUID(), role: .assistant, content: "one")
        let m2 = Message(id: UUID(), role: .user, content: "two")
        let llm = ReplayLLM(messageBatches: [[m1], [m2]])

        let peek1 = await llm.peekNextMessageBatch()
        let peek2 = await llm.peekNextMessageBatch()
        let next = await llm.nextMessageBatch()

        #expect(peek1?.first?.content == "one")
        #expect(peek2?.first?.content == "one")
        #expect(next?.first?.content == "one")
        #expect(await llm.peekNextMessageBatch()?.first?.content == "two")
    }

    @Test("peekNextMessageBatch returns nil when exhausted")
    func peekReturnsNilWhenExhausted() async {
        let llm = ReplayLLM(messageBatches: [[Message(id: UUID(), role: .assistant, content: "only")]])
        _ = await llm.nextMessageBatch()
        #expect(await llm.peekNextMessageBatch() == nil)
    }
}
