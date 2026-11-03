import EasyJSON
import Foundation
import SwiftAgentKit
import Synchronization
import Testing
@testable import SwiftAgentHarness

/// Records requests and answers each with a canned body.
final class RecordingHTTPTransport: Sendable {
    private let requests = Mutex<[URLRequest]>([])
    private let body: Data

    init(_ body: String) {
        self.body = Data(body.utf8)
    }

    var recorded: [URLRequest] { requests.withLock { $0 } }

    var transport: ProviderHTTPStatus.Transport {
        { [self] request in
            requests.withLock { $0.append(request) }
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
}

enum VendorCodecFixtures {
    static let png = Message.Image(name: "shot", imageData: Data([0x89, 0x50, 0x4E, 0x47]), mediaType: "image/png")

    static func config(_ dialect: ComputerUseNativeDialect?, tools: [String] = []) -> LLMRequestConfig {
        LLMRequestConfig(
            availableTools: tools.map { ToolDefinition(name: $0, description: $0, parameters: [], type: .function) },
            additionalParameters: dialect.map { .object([ComputerUseNativeDialect.parameterKey: $0.wireParameters]) }
        )
    }

    static func object(_ json: JSON) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: ProviderHTTPStatus.encode(json)) as? [String: Any])
    }

    static func json(_ text: String) throws -> JSON {
        try ProviderHTTPStatus.decode(Data(text.utf8))
    }
}

@Suite("OpenAI Responses codec: the computer tool")
struct OpenAIResponsesComputerCodecTests {
    private typealias F = VendorCodecFixtures
    private let dialect = ComputerUseNativeDialect(toolset: .openAIComputer)
    private let system = Message(id: UUID(), role: .system, content: "You operate a browser.")
    private let task = Message(id: UUID(), role: .user, content: "Buy the blue mug.")
    private let checks: JSON = .array([.object(["id": .string("sc_1"), "code": .string("malicious_instructions"), "message": .string("Odd page text")])])

    private func body(_ messages: [Message], tools: [String] = ["computer", "computer_verify"]) throws -> [String: Any] {
        try F.object(OpenAIResponsesComputerCodec.requestBody(
            model: "gpt-6.1-sol", messages: messages, config: F.config(dialect, tools: tools), reasoningEffort: nil
        ))
    }

    private func turn(checks: JSON? = nil) -> Message {
        var arguments: [String: JSON] = ["actions": .array([.object(["type": .string("screenshot")])])]
        if let checks { arguments["pending_safety_checks"] = checks }
        return Message(id: UUID(), role: .assistant, content: "", toolCalls: [
            ToolCall(name: "computer", arguments: .object(arguments), id: "call_1@resp_1"),
            ToolCall(name: "computer_verify", arguments: .object([:]), id: "call_2@resp_1"),
        ])
    }

    @Test("The first request declares the computer tool and the other tools as functions, with the system prompt as instructions")
    func firstRequest() throws {
        let body = try body([system, task])
        #expect(body["model"] as? String == "gpt-6.1-sol")
        #expect(body["instructions"] as? String == "You operate a browser.")
        #expect(body["store"] as? Bool == true)
        #expect(body["previous_response_id"] == nil)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.first?["type"] as? String == "computer")
        #expect(tools.dropFirst().map { $0["name"] as? String } == ["computer_verify"])
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.count == 1)
        #expect(input[0]["role"] as? String == "user")
    }

    @Test("A computer_call becomes one computer tool call carrying its actions and checks, named by response")
    func decode() throws {
        let decoded = try OpenAIResponsesComputerCodec.decode(try F.json("""
        {"id": "resp_1", "status": "completed", "output": [
          {"type": "reasoning", "id": "rs_1", "summary": []},
          {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Opening the cart."}]},
          {"type": "computer_call", "id": "cu_1", "call_id": "call_1", "status": "completed",
           "actions": [{"type": "click", "button": "left", "x": 405, "y": 157}],
           "pending_safety_checks": [{"id": "sc_1", "code": "sensitive_domain", "message": "Bank"}]},
          {"type": "function_call", "call_id": "call_2", "name": "computer_verify", "arguments": "{\\"claim\\": \\"done\\"}"}
        ], "usage": {"input_tokens": 1200, "output_tokens": 40, "total_tokens": 1240, "input_tokens_details": {"cached_tokens": 1000}}}
        """))
        #expect(decoded.content == "Opening the cart.")
        #expect(decoded.toolCalls.map(\.name) == ["computer", "computer_verify"])
        #expect(decoded.toolCalls.map(\.id) == ["call_1@resp_1", "call_2@resp_1"])
        let arguments = try F.object(decoded.toolCalls[0].arguments)
        #expect((arguments["actions"] as? [[String: Any]])?.first?["type"] as? String == "click")
        #expect((arguments["pending_safety_checks"] as? [[String: Any]])?.first?["code"] as? String == "sensitive_domain")
        #expect(ComputerUseOpenAIToolProvider.signals(decoded.toolCalls[0].arguments.objectValue?["pending_safety_checks"]) == [.sensitiveDomain])
        #expect(try F.object(decoded.toolCalls[1].arguments)["claim"] as? String == "done")
        #expect(decoded.usage == .init(inputTokens: 1200, outputTokens: 40, totalTokens: 1240, cachedTokens: 1000))
        #expect(decoded.finishReason == "tool_calls")
    }

    @Test("Results continue the stored response: the screenshot as computer_call_output, checks acknowledged only when confirmed")
    func continuation() throws {
        let computer = Message(
            id: UUID(), role: .tool,
            content: "\(ComputerUseOpenAIToolProvider.acknowledgedLine)\nAction 2 suspected-noop: nothing changed",
            images: [F.png], toolCallId: "call_1@resp_1"
        )
        let verify = Message(id: UUID(), role: .tool, content: "verified", toolCallId: "call_2@resp_1")
        let body = try body([system, task, turn(checks: checks), computer, verify])
        #expect(body["previous_response_id"] as? String == "resp_1")
        #expect(body["instructions"] as? String == "You operate a browser.", "instructions don't carry over")
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.map { $0["type"] as? String } == ["computer_call_output", "function_call_output", nil])
        #expect(input[0]["call_id"] as? String == "call_1")
        let output = try #require(input[0]["output"] as? [String: Any])
        #expect(output["type"] as? String == "computer_screenshot")
        #expect((output["image_url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
        #expect(output["detail"] as? String == "original")
        #expect((input[0]["acknowledged_safety_checks"] as? [[String: Any]])?.first?["id"] as? String == "sc_1")
        #expect(input[1]["call_id"] as? String == "call_2")
        #expect(input[1]["output"] as? String == "verified")
        let note = try #require((input[2]["content"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(note.contains("suspected-noop"))
        #expect(!note.contains(ComputerUseOpenAIToolProvider.acknowledgedLine))

        let declined = Message(id: UUID(), role: .tool, content: "Action 1 refused: the user declined", images: [F.png], toolCallId: "call_1@resp_1")
        let unacknowledged = try #require(try self.body([system, task, turn(checks: checks), declined])["input"] as? [[String: Any]])
        #expect(unacknowledged[0]["acknowledged_safety_checks"] == nil)
    }

    @Test("OpenAILLM sends a computer-use session to the Responses endpoint; other requests stay on chat completions")
    func routing() async throws {
        let transport = RecordingHTTPTransport("""
        {"id": "resp_9", "status": "completed", "output": [{"type": "message", "content": [{"type": "output_text", "text": "Done."}]}]}
        """)
        let llm = OpenAILLM(
            baseURL: "https://api.openai.com/v1", apiKey: "sk-test", model: "gpt-6.1-sol",
            capabilities: [.completion, .tools, .vision], responsesTransport: transport.transport
        )
        let response = try await llm.send([task], config: F.config(dialect))
        #expect(response.content == "Done.")
        let request = try #require(transport.recorded.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(OpenAILLM.usesComputerResponses(F.config(dialect)))
        #expect(!OpenAILLM.usesComputerResponses(F.config(nil)))
        #expect(!OpenAILLM.usesComputerResponses(F.config(ComputerUseNativeDialect(toolset: .toolset20260801))))
    }
}

@Suite("Gemini Interactions codec")
struct GeminiInteractionsCodecTests {
    private typealias F = VendorCodecFixtures
    private let dialect = ComputerUseNativeDialect(toolset: .geminiComputerUse, environment: .browser)
    private let system = Message(id: UUID(), role: .system, content: "You operate a browser.")
    private let task = Message(id: UUID(), role: .user, content: "Buy the blue mug.", images: [VendorCodecFixtures.png])

    private func body(_ messages: [Message], dialect: ComputerUseNativeDialect?, tools: [String] = ["click", "navigate", "computer_verify"]) throws -> [String: Any] {
        try F.object(GeminiInteractionsCodec.requestBody(model: "gemini-3.8-flash", messages: messages, config: F.config(dialect, tools: tools)))
    }

    @Test("A computer-use request declares computer_use with the functions the harness can't carry out excluded")
    func declaration() throws {
        let body = try body([system, task], dialect: dialect)
        #expect(body["system_instruction"] as? String == "You operate a browser.")
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 2)
        #expect(tools[0]["type"] as? String == "computer_use")
        #expect(tools[0]["environment"] as? String == "browser")
        let excluded = try #require(tools[0]["excluded_predefined_functions"] as? [String])
        #expect(excluded.contains("key_down"))
        #expect(excluded.contains("open_app"))
        #expect(!excluded.contains("navigate"))
        #expect(tools[1]["type"] as? String == "function")
        #expect(tools[1]["name"] as? String == "computer_verify")
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.map { $0["type"] as? String } == ["text", "image"])
        #expect(input[1]["mime_type"] as? String == "image/png")

        let plain = try self.body([system, task], dialect: nil, tools: ["lookup"])
        #expect((plain["tools"] as? [[String: Any]])?.map { $0["type"] as? String } == ["function"])
    }

    @Test("Function calls decode with their arguments, named by interaction")
    func decode() throws {
        let decoded = try GeminiInteractionsCodec.decode(try F.json("""
        {"id": "int_1", "status": "requires_action", "steps": [
          {"type": "thought", "signature": "EvEF"},
          {"type": "model_output", "content": [{"type": "text", "text": "Clicking checkout."}]},
          {"type": "function_call", "id": "fc_1", "name": "click",
           "arguments": {"x": 450, "y": 120, "intent": "Check out", "safety_decision": {"decision": "require_confirmation", "explanation": "Purchase"}}}
        ], "usage": {"total_input_tokens": 900, "total_output_tokens": 30, "total_tokens": 930, "total_cached_tokens": 0}}
        """))
        #expect(decoded.content == "Clicking checkout.")
        #expect(decoded.toolCalls.map(\.id) == ["fc_1@int_1"])
        #expect(decoded.toolCalls.first?.name == "click")
        #expect(ComputerUseGeminiToolProvider.signals(decoded.toolCalls.first?.arguments.objectValue?["safety_decision"]) == [.requireConfirmation])
        #expect(decoded.usage == .init(inputTokens: 900, outputTokens: 30, totalTokens: 930, cachedTokens: 0))
        #expect(decoded.finishReason == "tool_calls")
        #expect(throws: LLMError.self) { try GeminiInteractionsCodec.decode(try F.json(#"{"id": "int_2", "status": "failed", "steps": []}"#)) }
    }

    @Test("Results continue the stored interaction as function_result steps with their text and screenshot")
    func continuation() throws {
        let turn = Message(id: UUID(), role: .assistant, content: "", toolCalls: [
            ToolCall(name: "click", arguments: .object([:]), id: "fc_1@int_1"),
            ToolCall(name: "navigate", arguments: .object([:]), id: "fc_2@int_1"),
        ])
        let first = Message(id: UUID(), role: .tool, content: #"{"safety_acknowledgement":true,"url":"https://shop.example/"}"#, images: [F.png], toolCallId: "fc_1@int_1")
        let halted = Message(id: UUID(), role: .tool, content: ComputerUseNativeToolset.haltText, toolCallId: "fc_2@int_1")
        let body = try body([system, task, turn, first, halted], dialect: dialect)
        #expect(body["previous_interaction_id"] as? String == "int_1")
        #expect(body["tools"] != nil, "tools are interaction-scoped and resent")
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.map { $0["type"] as? String } == ["function_result", "function_result"])
        #expect(input[0]["call_id"] as? String == "fc_1")
        #expect(input[0]["name"] as? String == "click")
        let result = try #require(input[0]["result"] as? [[String: Any]])
        #expect(result.map { $0["type"] as? String } == ["text", "image"])
        #expect((result[0]["text"] as? String)?.contains("safety_acknowledgement") == true)
        #expect(input[1]["is_error"] as? Bool == true)
    }

    @Test("GeminiLLM posts to the Interactions endpoint with the API key header")
    func transport() async throws {
        let transport = RecordingHTTPTransport("""
        {"id": "int_9", "status": "completed", "steps": [{"type": "model_output", "content": [{"type": "text", "text": "Done."}]}]}
        """)
        let llm = GeminiLLM(
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!, apiKey: "g-test", model: "gemini-3.8-flash",
            capabilities: [.completion, .tools, .vision], transport: transport.transport
        )
        let response = try await llm.send([task], config: F.config(dialect))
        #expect(response.content == "Done.")
        let request = try #require(transport.recorded.first)
        #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/interactions")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "g-test")
        let body = try F.object(try F.json(String(decoding: try #require(request.httpBody), as: UTF8.self)))
        #expect(body["model"] as? String == "gemini-3.8-flash")
    }
}

private extension JSON {
    var objectValue: [String: JSON]? {
        if case .object(let object) = self { return object }
        return nil
    }
}
