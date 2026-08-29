import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("LMStudioLLM tool schema encoding")
struct LMStudioLLMToolSchemaEncodingTests {
    @Test("array property with items is preserved on the wire")
    func preservesArrayItems() async throws {
        let schema: JSON = .object([
            "type": .string("object"),
            "properties": .object([
                "paths": .object([
                    "type": .string("array"),
                    "description": .string("File paths"),
                    "items": .object(["type": .string("string")]),
                ]),
            ]),
            "required": .array([.string("paths")]),
        ])
        let json = try await encodedToolsBody(schema: schema)
        let paths = try requireProperty(named: "paths", in: json)
        #expect(paths["type"] as? String == "array")
        #expect(paths["description"] as? String == "File paths")
        let items = try #require(paths["items"] as? [String: Any])
        #expect(items["type"] as? String == "string")
        let parameters = try requireParameters(in: json)
        let required = try #require(parameters["required"] as? [String])
        #expect(required == ["paths"])
    }

    @Test("array property without items gets default items schema")
    func defaultsMissingArrayItems() async throws {
        let schema: JSON = .object([
            "type": .string("object"),
            "properties": .object([
                "paths": .object([
                    "type": .string("array"),
                    "description": .string("File paths"),
                ]),
            ]),
            "required": .array([.string("paths")]),
        ])
        let json = try await encodedToolsBody(schema: schema)
        let paths = try requireProperty(named: "paths", in: json)
        #expect(paths["type"] as? String == "array")
        let items = try #require(paths["items"] as? [String: Any])
        #expect(items["type"] as? String == "string")
    }

    @Test("enum and nested properties pass through on the wire")
    func preservesEnumAndNestedProperties() async throws {
        let schema: JSON = .object([
            "type": .string("object"),
            "properties": .object([
                "mode": .object([
                    "type": .string("string"),
                    "enum": .array([.string("fast"), .string("thorough")]),
                ]),
                "options": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "retry": .object(["type": .string("boolean")]),
                    ]),
                    "required": .array([.string("retry")]),
                ]),
            ]),
            "required": .array([.string("mode")]),
        ])
        let json = try await encodedToolsBody(schema: schema)
        let mode = try requireProperty(named: "mode", in: json)
        #expect(mode["type"] as? String == "string")
        let enumValues = try #require(mode["enum"] as? [String])
        #expect(enumValues == ["fast", "thorough"])

        let options = try requireProperty(named: "options", in: json)
        #expect(options["type"] as? String == "object")
        let nested = try #require(options["properties"] as? [String: Any])
        let retry = try #require(nested["retry"] as? [String: Any])
        #expect(retry["type"] as? String == "boolean")
        let nestedRequired = try #require(options["required"] as? [String])
        #expect(nestedRequired == ["retry"])
    }

    @Test("flat array parameter fallback also emits default items")
    func flatArrayFallbackDefaultsItems() async throws {
        let tool = ToolDefinition(
            name: "example_tool",
            description: "Example",
            parameters: [
                .init(name: "paths", description: "File paths", type: "array", required: true),
            ],
            type: .function
        )
        let llm = try await makeAdapter()
        let config = LLMRequestConfig(availableTools: [tool])
        let data = try await llm.testEncodedChatRequestBody(
            from: [Message(id: UUID(), role: .user, content: "hi")],
            config: config
        )
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let paths = try requireProperty(named: "paths", in: json)
        #expect(paths["type"] as? String == "array")
        let items = try #require(paths["items"] as? [String: Any])
        #expect(items["type"] as? String == "string")
    }

    // MARK: - Helpers

    private func encodedToolsBody(schema: JSON) async throws -> [String: Any] {
        let tool = ToolDefinition(
            name: "example_tool",
            description: "Example",
            parameters: [],
            type: .function
        )
        let llm = try await makeAdapter()
        let config = LLMRequestConfig(
            availableTools: [tool],
            toolParameterSchemasByName: ["example_tool": schema]
        )
        let data = try await llm.testEncodedChatRequestBody(
            from: [Message(id: UUID(), role: .user, content: "hi")],
            config: config
        )
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func requireParameters(in json: [String: Any]) throws -> [String: Any] {
        let tools = try #require(json["tools"] as? [[String: Any]])
        let function = try #require(tools.first?["function"] as? [String: Any])
        return try #require(function["parameters"] as? [String: Any])
    }

    private func requireProperty(named name: String, in json: [String: Any]) throws -> [String: Any] {
        let parameters = try requireParameters(in: json)
        let properties = try #require(parameters["properties"] as? [String: Any])
        return try #require(properties[name] as? [String: Any])
    }

    private func makeAdapter() async throws -> LMStudioLLM {
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
        return LMStudioLLM(
            model: "openai/gpt-oss-20b",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            systemPrompt: prompt
        )
    }
}
