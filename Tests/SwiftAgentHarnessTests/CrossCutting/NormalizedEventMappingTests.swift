import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("NormalizedEvent projector")
struct NormalizedEventMappingTests {
    @Test("text delta maps to incomplete chunk content")
    func textDeltaMapsToChunk() {
        let chunk = NormalizedEventMapper.streamChunk(
            for: .textDelta("hello"),
            availableTools: []
        )
        #expect(chunk.content == "hello")
        #expect(chunk.isComplete == false)
    }

    @Test("thinking delta maps to reasoning streaming fragment")
    func thinkingDeltaMapsToFragment() {
        let chunk = NormalizedEventMapper.streamChunk(
            for: .thinkingDelta("thinking"),
            availableTools: []
        )
        guard case .reasoning(let text)? = chunk.streamingFragment else {
            Issue.record("Expected reasoning streaming fragment")
            return
        }
        #expect(text == "thinking")
    }

    @Test("tool-call started maps to streamToolCallStarted fragment")
    func toolCallStartedMapsToFragment() {
        let chunk = NormalizedEventMapper.streamChunk(
            for: .toolCallStarted(id: "call-1", name: "lookup", contentIndex: 2),
            availableTools: []
        )
        guard case .toolCallStarted(let id, let name, let index)? = chunk.streamingFragment else {
            Issue.record("Expected toolCallStarted streaming fragment")
            return
        }
        #expect(id == "call-1")
        #expect(name == "lookup")
        #expect(index == 2)
    }

    @Test("tool-call delta maps to toolCall streaming fragment in eager mode")
    func toolCallDeltaMapsToFragment() {
        var state = ToolCallStreamingState(supportsEager: true)
        _ = state.projectDelta(id: "call-1", name: "lookup", argumentsFragment: "")
        let chunks = state.projectDelta(id: "call-1", name: "lookup", argumentsFragment: "{\"q\":\"x\"}")
        guard case .toolCall(let id, let name, let args)? = chunks.first?.streamingFragment else {
            Issue.record("Expected toolCall streaming fragment")
            return
        }
        #expect(id == "call-1")
        #expect(name == "lookup")
        #expect(args == "{\"q\":\"x\"}")
    }

    @Test("tool-call completed maps to streamToolCallCompleted fragment")
    func toolCallCompletedMapsToFragment() {
        let chunk = NormalizedEventMapper.streamChunk(
            for: .toolCallCompleted(id: "call-1", name: "lookup", arguments: "{\"q\":\"x\"}"),
            availableTools: []
        )
        guard case .toolCallCompleted(let id, let name, let args)? = chunk.streamingFragment else {
            Issue.record("Expected toolCallCompleted streaming fragment")
            return
        }
        #expect(id == "call-1")
        #expect(name == "lookup")
        #expect(args == "{\"q\":\"x\"}")
    }

    @Test("usage and stop events produce no stream chunks")
    func tailEventsProduceNoChunks() {
        var state = ToolCallStreamingState(supportsEager: true)
        let usageChunks = NormalizedEventProjector.streamChunks(
            for: .usage(NormalizedUsage(inputTokens: 1, outputTokens: 2)),
            availableTools: [],
            toolState: &state
        )
        let stopChunks = NormalizedEventProjector.streamChunks(
            for: .stop(.end),
            availableTools: [],
            toolState: &state
        )
        #expect(usageChunks.isEmpty)
        #expect(stopChunks.isEmpty)
    }

    @Test("normalized stream tail merges usage and stop into metadata")
    func streamTailMergesMetadata() {
        let tail = NormalizedStreamTail(
            usage: NormalizedUsage(inputTokens: 10, outputTokens: 5),
            stop: .toolUse
        )
        let meta = tail.apply(to: nil)
        #expect(meta.promptTokens == 10)
        #expect(meta.completionTokens == 5)
        #expect(meta.totalTokens == 15)
        #expect(meta.finishReason == FinishReason.toolCalls.rawValue)
    }
}
