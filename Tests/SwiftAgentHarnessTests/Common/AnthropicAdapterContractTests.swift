import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Anthropic adapter contract")
struct AnthropicAdapterContractTests {
    @Test("SSE parser maps thinking and text deltas")
    func sseParserThinkingAndText() {
        let thinkingJSON = """
        {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"step"}}
        """
        let textJSON = """
        {"type":"content_block_delta","delta":{"type":"text_delta","text":"hello"}}
        """
        let thinkingEvents = AnthropicSSEParser.events(fromJSONLine: thinkingJSON, eventName: nil)
        let textEvents = AnthropicSSEParser.events(fromJSONLine: textJSON, eventName: nil)
        #expect(thinkingEvents.count == 1)
        #expect(textEvents.count == 1)
        if case .thinkingDelta(let t, _)? = thinkingEvents.first {
            #expect(t == "step")
        } else {
            Issue.record("expected thinking delta")
        }
        if case .contentDelta(let t)? = textEvents.first {
            #expect(t == "hello")
        } else {
            Issue.record("expected text delta")
        }
    }

    @Test("NormalizedEvent mapper projects reasoning fragments")
    func normalizedReasoningFragment() {
        let chunk = NormalizedEventMapper.streamChunk(
            for: .thinkingDelta("hidden"),
            availableTools: []
        )
        guard case .reasoning(let text)? = chunk.streamingFragment else {
            Issue.record("expected reasoning fragment")
            return
        }
        #expect(text == "hidden")
        #expect(chunk.content.isEmpty)
    }

    @Test("SSE parser maps message_delta cache usage tokens and stop_reason")
    func sseParserMessageDeltaCacheUsage() {
        let json = """
        {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":80,"cache_creation_input_tokens":20}}
        """
        let events = AnthropicSSEParser.events(fromJSONLine: json, eventName: nil)
        #expect(events.count == 1)
        if case .messageDelta(let usage, let stopReason)? = events.first, let usage {
            #expect(usage.cacheReadInputTokens == 80)
            #expect(usage.cacheCreationInputTokens == 20)
            #expect(usage.normalizedUsage.cacheReadTokens == 80)
            #expect(usage.normalizedUsage.cacheWriteTokens == 20)
            #expect(stopReason == "end_turn")
        } else {
            Issue.record("expected messageDelta with cache usage")
        }
    }

    @Test("SSE parser maps tool_use content_block_start")
    func sseParserToolCallStarted() {
        let json = """
        {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"search"}}
        """
        let events = AnthropicSSEParser.events(fromJSONLine: json, eventName: nil)
        #expect(events.count == 1)
        if case .toolCallStarted(let id, let name, let index)? = events.first {
            #expect(id == "toolu_1")
            #expect(name == "search")
            #expect(index == 1)
        } else {
            Issue.record("expected toolCallStarted")
        }
    }
}
