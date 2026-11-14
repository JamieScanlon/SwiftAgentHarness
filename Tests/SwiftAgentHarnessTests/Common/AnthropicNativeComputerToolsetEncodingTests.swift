import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Anthropic codec: native computer-use toolset")
struct AnthropicNativeComputerToolsetEncodingTests {
    private func llm() async throws -> AnthropicLLM {
        let prompt = try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        return AnthropicLLM(
            apiURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "dummy",
            model: "claude-test",
            capabilities: [.completion, .vision, .tools],
            systemPrompt: prompt
        )
    }

    private func config(_ dialect: ComputerUseNativeDialect?, tools: [ToolDefinition]) -> LLMRequestConfig {
        LLMRequestConfig(
            availableTools: tools,
            additionalParameters: dialect.map { .object([ComputerUseNativeDialect.parameterKey: $0.wireParameters]) }
        )
    }

    private func function(_ name: String) -> ToolDefinition {
        ToolDefinition(name: name, description: name, parameters: [], type: .function)
    }

    private func body(_ messages: [Message], _ config: LLMRequestConfig) async throws -> [String: Any] {
        let data = try await llm().testEncodedRequestBody(from: messages, config: config)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private let prompt = Message(id: UUID(), role: .user, content: "Bold the title.")

    @Test("The toolset replaces its member tools with one declaration; other tools stay functions")
    func declaration() async throws {
        let dialect = ComputerUseNativeDialect(toolset: .toolset20260801)
        let tools = ["screenshot", "left_click", "key", ComputerUseToolProvider.verifyToolName].map(function)
        let json = try await body([prompt], config(dialect, tools: tools))
        let declared = try #require(json["tools"] as? [[String: Any]])
        #expect(declared.contains { $0["type"] as? String == "computer_toolset_20260801" && $0["name"] == nil })
        #expect(declared.compactMap { $0["name"] as? String } == [ComputerUseToolProvider.verifyToolName])
        #expect(AnthropicLLM.extraHeaders(for: config(dialect, tools: tools)).isEmpty)
    }

    @Test("Older versions declare the computer tool with its screen size and send their beta header")
    func olderDeclaration() async throws {
        let dialect = ComputerUseNativeDialect(toolset: .computer20251124, displayWidthPx: 1280, displayHeightPx: 800)
        let configuration = config(dialect, tools: [function("computer")])
        let json = try await body([prompt], configuration)
        let declared = try #require((json["tools"] as? [[String: Any]])?.first)
        #expect(declared["type"] as? String == "computer_20251124")
        #expect(declared["name"] as? String == "computer")
        #expect(declared["display_width_px"] as? Int == 1280)
        #expect(declared["display_height_px"] as? Int == 800)
        #expect(declared["enable_zoom"] as? Bool == true)
        #expect(AnthropicLLM.extraHeaders(for: configuration) == ["anthropic-beta": "computer-use-2025-11-24"])
    }

    @Test("History echoes toolset_name on member calls and results, and marks halted results as errors")
    func history() async throws {
        let dialect = ComputerUseNativeDialect(toolset: .toolset20260801)
        let click = ToolCall(name: "left_click", arguments: .object(["coordinate": .array([.integer(1), .integer(2)])]), id: "tu_1")
        let typed = ToolCall(name: "type", arguments: .object(["text": .string("x")]), id: "tu_2")
        let verify = ToolCall(name: ComputerUseToolProvider.verifyToolName, arguments: .object([:]), id: "tu_3")
        let messages = [
            prompt,
            Message(id: UUID(), role: .assistant, content: "", toolCalls: [click, typed, verify]),
            Message(id: UUID(), role: .tool, content: "refused", toolCallId: "tu_1"),
            Message(id: UUID(), role: .tool, content: ComputerUseNativeToolset.haltText, toolCallId: "tu_2"),
            Message(id: UUID(), role: .tool, content: "Recorded.", toolCallId: "tu_3"),
        ]
        let json = try await body(messages, config(dialect, tools: ["left_click", "type", ComputerUseToolProvider.verifyToolName].map(function)))
        let encoded = try #require(json["messages"] as? [[String: Any]])
        let uses = try #require(encoded[1]["content"] as? [[String: Any]])
        #expect(uses.map { $0["toolset_name"] as? String } == ["computer", "computer", nil])
        let results = encoded.dropFirst(2).compactMap { ($0["content"] as? [[String: Any]])?.first }
        #expect(results.map { $0["toolset_name"] as? String } == ["computer", "computer", nil])
        #expect(results.map { $0["is_error"] as? Bool } == [nil, true, nil])
    }

    @Test("Without the dialect nothing changes")
    func unchanged() async throws {
        let json = try await body([prompt], config(nil, tools: [function("left_click")]))
        #expect((json["tools"] as? [[String: Any]])?.first?["name"] as? String == "left_click")
        #expect(AnthropicLLM.extraHeaders(for: config(nil, tools: [])).isEmpty)
    }
}
