import EasyJSON
import Testing
import SwiftAgentKit
@testable import SwiftAgentHarness

@Suite("OpenAILLM reasoning effort")
struct OpenAILLMReasoningEffortTests {
    @Test("extractReasoningEffort maps known string values")
    func extractReasoningEffortKnownValues() {
        let llm = OpenAILLM(
            baseURL: "http://localhost:1234/v1",
            apiKey: "dummy",
            model: "o4-mini",
            capabilities: [.completion, .thinking]
        )
        let mapped = llm.extractReasoningEffort(from: .object(["thinkingConfig": .object(["level": .string("minimal")])]))
        #expect(mapped == .minimal)
    }

    @Test("extractReasoningEffort returns nil for unsupported capability")
    func extractReasoningEffortUnsupportedCapability() {
        let llm = OpenAILLM(
            baseURL: "http://localhost:1234/v1",
            apiKey: "dummy",
            model: "gpt-4o-mini",
            capabilities: [.completion]
        )
        let mapped = llm.extractReasoningEffort(from: .object(["thinkingConfig": .object(["level": .string("high")])]))
        #expect(mapped == nil)
    }

    @Test("extractReasoningEffort returns nil for unknown values")
    func extractReasoningEffortUnknownValue() {
        let llm = OpenAILLM(
            baseURL: "http://localhost:1234/v1",
            apiKey: "dummy",
            model: "o4-mini",
            capabilities: [.completion, .thinking]
        )
        let mapped = llm.extractReasoningEffort(from: .object(["thinkingConfig": .string("turbo")]))
        #expect(mapped == nil)
    }
}
