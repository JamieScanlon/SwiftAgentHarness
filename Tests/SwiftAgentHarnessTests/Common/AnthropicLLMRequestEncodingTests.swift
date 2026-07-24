import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("AnthropicLLM request encoding")
struct AnthropicLLMRequestEncodingTests {

    @Test("assistant toolCalls encode as tool_use content blocks")
    func assistantToolCallsEncodeAsToolUse() async throws {
        let llm = try await makeAdapter(capabilities: [.completion, .tools])
        let messages = [
            Message(
                id: UUID(),
                role: .assistant,
                content: "looking up",
                toolCalls: [
                    ToolCall(name: "search", arguments: .object(["q": .string("rust")]), id: "toolu_1"),
                ]
            )
        ]
        let data = try await llm.testEncodedRequestBody(from: messages, config: LLMRequestConfig())
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let wireMessages = try #require(json["messages"] as? [[String: Any]])
        let assistant = try #require(wireMessages.first { ($0["role"] as? String) == "assistant" })
        let content = try #require(assistant["content"] as? [[String: Any]])
        #expect(content.contains { ($0["type"] as? String) == "text" && ($0["text"] as? String) == "looking up" })
        guard let toolUse = content.first(where: { ($0["type"] as? String) == "tool_use" }) else {
            Issue.record("missing tool_use block")
            return
        }
        #expect(toolUse["id"] as? String == "toolu_1")
        #expect(toolUse["name"] as? String == "search")
        let input = toolUse["input"] as? [String: Any]
        #expect(input?["q"] as? String == "rust")
    }

    @Test("tool messages encode as user tool_result blocks")
    func toolMessagesEncodeAsToolResult() async throws {
        let llm = try await makeAdapter(capabilities: [.completion, .tools])
        let messages = [
            Message(
                id: UUID(),
                role: .tool,
                content: "result payload",
                toolCallId: "toolu_1"
            )
        ]
        let data = try await llm.testEncodedRequestBody(from: messages, config: LLMRequestConfig())
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let wireMessages = try #require(json["messages"] as? [[String: Any]])
        let user = try #require(wireMessages.first { ($0["role"] as? String) == "user" })
        let content = try #require(user["content"] as? [[String: Any]])
        guard let toolResult = content.first(where: { ($0["type"] as? String) == "tool_result" }) else {
            Issue.record("missing tool_result block")
            return
        }
        #expect(toolResult["tool_use_id"] as? String == "toolu_1")
        #expect(toolResult["content"] as? String == "result payload")
    }

    @Test("base apiURL resolves to /v1/messages")
    func baseURLResolvesToMessages() async throws {
        let llm = try await makeAdapter(capabilities: [.completion])
        #expect(llm.testMessagesURL().absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(llm.testModelsURL().absoluteString == "https://api.anthropic.com/v1/models")
    }

    @Test("already-qualified messages URL is not double-appended")
    func messagesURLNotDoubleAppended() async throws {
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
        let llm = AnthropicLLM(
            apiURL: URL(string: "https://api.anthropic.com/v1/messages")!,
            apiKey: "dummy",
            model: "claude-test",
            capabilities: [.completion],
            systemPrompt: prompt
        )
        #expect(llm.testMessagesURL().absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(llm.testModelsURL().absoluteString == "https://api.anthropic.com/v1/models")
    }

    @Test("thinkingConfig encodes enabled thinking with budget")
    func thinkingConfigEncodesEnabledBudget() async throws {
        let llm = try await makeAdapter(capabilities: [.completion, .thinking])
        let config = LLMRequestConfig(
            additionalParameters: .object([
                "thinkingConfig": .object([
                    "level": .string("high"),
                    "budgetTokens": .integer(1024),
                ]),
            ])
        )
        let data = try await llm.testEncodedRequestBody(
            from: [Message(id: UUID(), role: .user, content: "hi")],
            config: config
        )
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let thinking = try #require(json["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "enabled")
        #expect(thinking["budget_tokens"] as? Int == 1024)
    }

    private func makeAdapter(capabilities: [LLMCapability]) async throws -> AnthropicLLM {
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
        return AnthropicLLM(
            apiURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "dummy",
            model: "claude-test",
            capabilities: capabilities,
            systemPrompt: prompt
        )
    }
}
