import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// A conversation where the assistant made two parallel tool calls, the first returning a screenshot.
enum ToolImageWireFixtures {
    static let png = ToolImageFixtures.tinyPNG

    static func conversation(secondImage: Bool = false) -> [Message] {
        [
            Message(id: UUID(), role: .user, content: "Bold the title."),
            Message(
                id: UUID(),
                role: .assistant,
                content: "",
                toolCalls: [
                    ToolCall(name: "computer_observe", id: "call-1"),
                    ToolCall(name: "read_file", id: "call-2"),
                ]
            ),
            Message(
                id: UUID(),
                role: .tool,
                content: "Observation o_1",
                images: [Message.Image(name: "call-1-image-1", imageData: png, mediaType: "image/png")],
                toolCallId: "call-1"
            ),
            Message(
                id: UUID(),
                role: .tool,
                content: "file text",
                images: secondImage ? [Message.Image(name: "call-2-image-1", imageData: png, mediaType: "image/webp")] : [],
                toolCallId: "call-2"
            ),
            Message(id: UUID(), role: .assistant, content: "Done."),
        ]
    }

    static func prompt() async throws -> SystemPrompt {
        try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
    }
}

@Suite("Tool result images on the wire")
struct ToolResultImageWireEncodingTests {
    @Test("Anthropic puts tool images inside the tool_result as image blocks with their media type")
    func anthropicToolResultImageBlocks() async throws {
        let llm = AnthropicLLM(
            apiURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "dummy",
            model: "claude-test",
            capabilities: [.completion, .vision, .tools],
            systemPrompt: try await ToolImageWireFixtures.prompt()
        )
        let data = try await llm.testEncodedRequestBody(from: ToolImageWireFixtures.conversation(), config: LLMRequestConfig())
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let toolResults = messages.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .filter { ($0["type"] as? String) == "tool_result" }
        let withImage = try #require(toolResults.first { ($0["tool_use_id"] as? String) == "call-1" })
        let blocks = try #require(withImage["content"] as? [[String: Any]])
        #expect(blocks.first?["type"] as? String == "text")
        #expect(blocks.first?["text"] as? String == "Observation o_1")
        let image = try #require(blocks.first { ($0["type"] as? String) == "image" })
        let source = image["source"] as? [String: Any]
        #expect(source?["type"] as? String == "base64")
        #expect(source?["media_type"] as? String == "image/png")
        #expect(source?["data"] as? String == ToolImageWireFixtures.png.base64EncodedString())

        let textOnly = try #require(toolResults.first { ($0["tool_use_id"] as? String) == "call-2" })
        #expect(textOnly["content"] as? String == "file text")
    }

    @Test("OpenAI keeps tool messages text-only and sends their images in one user message after the tool run")
    func openAIImagesAfterToolRun() async throws {
        let llm = OpenAILLM(baseURL: "http://localhost:1234/v1", apiKey: "dummy", model: "gpt-4o", capabilities: [.completion, .vision])
        let data = try await llm.testEncodedChatMessagesJSON(
            from: ToolImageWireFixtures.conversation(secondImage: true),
            config: LLMRequestConfig()
        )
        let messages = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let roles = messages.map { $0["role"] as? String ?? "" }.filter { $0 != "system" }
        #expect(roles == ["user", "assistant", "tool", "tool", "user", "assistant"])
        let tools = messages.filter { ($0["role"] as? String) == "tool" }
        #expect(tools.allSatisfy { $0["content"] is String })
        try expectImageCarrier(messages, imageCount: 2, mentions: ["call-1", "call-2"], mediaTypes: ["image/png", "image/webp"])
    }

    @Test("LM Studio follows the same tool-run rule")
    func lmStudioImagesAfterToolRun() async throws {
        let llm = LMStudioLLM(
            model: "qwen/qwen3-vl-30b",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .vision],
            systemPrompt: try await ToolImageWireFixtures.prompt()
        )
        let data = try await llm.testEncodedChatRequestBody(from: ToolImageWireFixtures.conversation(), config: LLMRequestConfig())
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let roles = messages.map { $0["role"] as? String ?? "" }.filter { $0 != "system" }
        #expect(roles == ["user", "assistant", "tool", "tool", "user", "assistant"])
        try expectImageCarrier(messages, imageCount: 1, mentions: ["call-1"], mediaTypes: ["image/png"])
    }

    @Test("A conversation without tool images encodes exactly as before: no extra user message")
    func noToolImagesNoCarrier() async throws {
        var plain = ToolImageWireFixtures.conversation()
        plain[2].images = []
        let llm = OpenAILLM(baseURL: "http://localhost:1234/v1", apiKey: "dummy", model: "gpt-4o", capabilities: [.completion, .vision])
        let data = try await llm.testEncodedChatMessagesJSON(from: plain, config: LLMRequestConfig())
        let messages = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String ?? "" }.filter { $0 != "system" } == ["user", "assistant", "tool", "tool", "assistant"])
    }

    private func expectImageCarrier(
        _ messages: [[String: Any]],
        imageCount: Int,
        mentions: [String],
        mediaTypes: [String]
    ) throws {
        let lastTool = try #require(messages.lastIndex { ($0["role"] as? String) == "tool" })
        let carrier = messages[lastTool + 1]
        #expect(carrier["role"] as? String == "user")
        let parts = try #require(carrier["content"] as? [[String: Any]])
        let text = parts.first { ($0["type"] as? String) == "text" }?["text"] as? String ?? ""
        for id in mentions { #expect(text.contains(id)) }
        let urls = parts.compactMap { ($0["image_url"] as? [String: Any])?["url"] as? String }
        #expect(urls.count == imageCount)
        for (url, mediaType) in zip(urls, mediaTypes) {
            #expect(url.hasPrefix("data:\(mediaType);base64,"))
        }
    }
}
