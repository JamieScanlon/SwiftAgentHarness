import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("NormalizedEvent mapper")
struct NormalizedEventMappingTests {
    @Test("content delta maps to incomplete chunk content")
    func contentDeltaMapsToChunk() {
        let chunk = NormalizedEventMapper.streamChunk(
            for: .contentDelta("hello"),
            availableTools: []
        )
        #expect(chunk.content == "hello")
        #expect(chunk.isComplete == false)
    }

    @Test("reasoning delta maps to reasoning streaming fragment")
    func reasoningDeltaMapsToFragment() {
        let chunk = NormalizedEventMapper.streamChunk(
            for: .reasoningDelta("thinking"),
            availableTools: []
        )
        guard case .reasoning(let text)? = chunk.streamingFragment else {
            Issue.record("Expected reasoning streaming fragment")
            return
        }
        #expect(text == "thinking")
    }

    @Test("tool-call delta maps to toolCall streaming fragment")
    func toolCallDeltaMapsToFragment() {
        let chunk = NormalizedEventMapper.streamChunk(
            for: .toolCallDelta(id: "call-1", name: "lookup", argumentsFragment: "{\"q\":\"x\"}"),
            availableTools: []
        )
        guard case .toolCall(let id, let name, let args)? = chunk.streamingFragment else {
            Issue.record("Expected toolCall streaming fragment")
            return
        }
        #expect(id == "call-1")
        #expect(name == "lookup")
        #expect(args == "{\"q\":\"x\"}")
    }
}
