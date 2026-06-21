import EasyJSON
import Foundation
import Testing
import SwiftAgentKit
@testable import SwiftAgentHarness

@Suite("AssistantMessageAccumulator")
struct AssistantMessageAccumulatorTests {
    @Test("accumulates text deltas and finalizes assistant message")
    func accumulatesText() {
        var acc = AssistantMessageAccumulator()
        acc.consume(.stream(LLMResponse.llmResponse(from: "hel", availableTools: []).markingIncomplete()))
        acc.consume(.stream(LLMResponse.llmResponse(from: "lo", availableTools: []).markingIncomplete()))
        acc.consume(.complete(LLMResponse.llmResponse(from: "hello", availableTools: [])))
        let message = acc.finalize()
        #expect(message.role == .assistant)
        #expect(message.content == "hello")
        #expect(message.toolCalls.isEmpty)
    }

    @Test("finalize omits streamed reasoning from assistant message")
    func omitsReasoningFromFinalize() {
        var acc = AssistantMessageAccumulator()
        acc.consume(
            .stream(
                LLMResponse.streamChunk(
                    "x",
                    streamingFragment: .reasoning("hidden reasoning")
                )
            )
        )
        acc.consume(.complete(LLMResponse.llmResponse(from: "x", availableTools: [])))
        let message = acc.finalize()
        #expect(message.content == "x")
    }

    @Test("accumulates tool call fragments")
    func accumulatesToolCalls() {
        var acc = AssistantMessageAccumulator()
        acc.consume(
            .stream(
                LLMResponse.streamChunk(
                    "",
                    streamingFragment: .toolCall(id: "call-1", name: "read", argumentsFragment: "{\"q\":")
                )
            )
        )
        acc.consume(
            .stream(
                LLMResponse.streamChunk(
                    "",
                    streamingFragment: .toolCall(id: "call-1", name: "read", argumentsFragment: "\"x\"}")
                )
            )
        )
        acc.consume(.complete(LLMResponse.llmResponse(from: "", availableTools: [])))
        let message = acc.finalize()
        #expect(message.toolCalls.count == 1)
        #expect(message.toolCalls.first?.name == "read")
    }

    @Test("LM Studio split tool-call delta shape preserves arguments on finalize")
    func lmStudioSplitToolCallDeltaShape() {
        let conversationID = "6EB8FBC6-66DE-4058-B563-C2EA353A46EC"
        let argsJSON = "{\"conversation_id\":\"\(conversationID)\"}"
        var acc = AssistantMessageAccumulator()
        acc.consume(
            .stream(
                LLMResponse.streamChunk(
                    "",
                    streamingFragment: .toolCall(id: "387522868", name: "get_plan", argumentsFragment: "")
                )
            )
        )
        acc.consume(
            .stream(
                LLMResponse.streamChunk(
                    "",
                    streamingFragment: .toolCall(id: nil, name: nil, argumentsFragment: argsJSON)
                )
            )
        )
        acc.consume(
            .complete(
                LLMResponse.llmResponse(from: "", availableTools: [])
                    .appending(toolCalls: [
                        ToolCall(
                            name: "get_plan",
                            arguments: .object(["conversation_id": .string(conversationID)]),
                            id: "387522868"
                        )
                    ])
            )
        )
        let message = acc.finalize()
        #expect(message.toolCalls.count == 1)
        #expect(message.toolCalls.first?.name == "get_plan")
        if case .object(let dict) = message.toolCalls.first?.arguments,
           case .string(let cid)? = dict["conversation_id"] {
            #expect(cid == conversationID)
        } else {
            Issue.record("expected conversation_id in finalized tool call arguments")
        }
    }
}
