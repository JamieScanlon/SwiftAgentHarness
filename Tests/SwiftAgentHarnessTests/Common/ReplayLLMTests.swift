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
}
