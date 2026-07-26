import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("LMStudioLLM multimodal message encoding")
struct LMStudioLLMMultimodalMessageEncodingTests {
    private let tinyPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    @Test("user message with inline imageData encodes image_url content parts")
    func userInlineImageEncodesImageURLParts() async throws {
        let llm = try await makeAdapter()
        let messages = [
            Message(
                id: UUID(),
                role: .user,
                content: "describe this",
                images: [Message.Image(name: "shot.png", imageData: tinyPNG)]
            )
        ]
        let config = LLMRequestConfig(additionalParameters: projectionParams(
            decisions: [("shot.png", "inline")]
        ))
        let data = try await llm.testEncodedChatRequestBody(from: messages, config: config)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let userContent = try requireUserContent(in: json)
        guard let parts = userContent as? [[String: Any]] else {
            Issue.record("Expected multimodal content array, got \(userContent)")
            return
        }
        #expect(parts.contains { ($0["type"] as? String) == "text" })
        guard let imagePart = parts.first(where: { ($0["type"] as? String) == "image_url" }) else {
            Issue.record("Missing image_url part")
            return
        }
        let imageURL = imagePart["image_url"] as? [String: Any]
        let url = imageURL?["url"] as? String
        #expect(url?.hasPrefix("data:image/png;base64,") == true)
        #expect(url?.contains(tinyPNG.base64EncodedString()) == true)
    }

    @Test("summarize disposition stays text-only with projection suffix")
    func summarizeStaysTextOnlyWithSuffix() async throws {
        let llm = try await makeAdapter()
        let messages = [
            Message(
                id: UUID(),
                role: .user,
                content: "hello",
                images: [Message.Image(name: "shot.png", imageData: tinyPNG)]
            )
        ]
        let config = LLMRequestConfig(additionalParameters: projectionParams(
            decisions: [("shot.png", "summarize")]
        ))
        let data = try await llm.testEncodedChatRequestBody(from: messages, config: config)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let userContent = try requireUserContent(in: json)
        guard let text = userContent as? String else {
            Issue.record("Expected string content, got \(userContent)")
            return
        }
        #expect(text.contains("hello"))
        #expect(text.contains("[Attachment projection]"))
        #expect(text.contains("shot.png:summarize"))
    }

    private func makeAdapter() async throws -> LMStudioLLM {
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
        return LMStudioLLM(
            model: "qwen/qwen3-vl-30b",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .vision],
            systemPrompt: prompt
        )
    }

    private func projectionParams(decisions: [(String, String)]) -> JSON {
        .object([
            "contextEngineAttachmentProjection": .object([
                "projectionFingerprint": .string("fp"),
                "decisions": .array(decisions.map { name, disposition in
                    .object([
                        "attachmentName": .string(name),
                        "disposition": .string(disposition),
                    ])
                }),
                "materializedBlocks": .array([]),
            ]),
        ])
    }

    private func requireUserContent(in json: [String: Any]) throws -> Any {
        let messages = try #require(json["messages"] as? [[String: Any]])
        let user = try #require(messages.first { ($0["role"] as? String) == "user" })
        return try #require(user["content"])
    }
}
