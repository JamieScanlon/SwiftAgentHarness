import EasyJSON
import Foundation
import SwiftAgentKit

/// Gemini's Interactions API.
///
/// Function calls come back as `function_call` steps and results go back as `function_result` steps, each with its
/// text and images. Turns continue from the stored interaction (`previous_interaction_id`), so only what came after
/// the latest assistant turn is sent; a request with no interaction to continue sends the conversation as content.
/// For a computer-use session the request declares the `computer_use` tool, excluding the predefined functions the
/// harness doesn't carry out.
enum GeminiInteractionsCodec {
    struct Decoded: Sendable {
        var content: String
        var toolCalls: [ToolCall]
        var usage: Usage?
        var finishReason: String
    }

    struct Usage: Sendable, Equatable {
        var inputTokens: Int?
        var outputTokens: Int?
        var totalTokens: Int?
        var cachedTokens: Int?
    }

    // MARK: - Request

    static func requestBody(model: String, messages: [Message], config: LLMRequestConfig) -> JSON {
        let dialect = ComputerUseNativeDialect(additionalParameters: config.additionalParameters)
            .flatMap { $0.toolset.vendor == .gemini ? $0 : nil }
        var body: [String: JSON] = ["model": .string(model)]
        let instructions = messages.filter { $0.role == .system }.map(\.content).filter { !$0.isEmpty }
        if !instructions.isEmpty { body["system_instruction"] = .string(instructions.joined(separator: "\n\n")) }
        let tools = tools(config, dialect: dialect)
        if !tools.isEmpty { body["tools"] = .array(tools) }
        var generation: [String: JSON] = [:]
        if let maxTokens = LLMTokenMetadataBuilder.maxCompletionTokens(from: config) {
            generation["max_output_tokens"] = .integer(maxTokens)
        }
        if !generation.isEmpty { body["generation_config"] = .object(generation) }

        let conversation = messages.filter { $0.role != .system }
        if let chain = ChainedProviderCall.chain(in: conversation) {
            body["previous_interaction_id"] = .string(chain.responseID)
            body["input"] = .array(continuation(conversation, from: chain.index))
        } else {
            body["input"] = .array(conversation.flatMap(content))
        }
        return .object(body)
    }

    private static func tools(_ config: LLMRequestConfig, dialect: ComputerUseNativeDialect?) -> [JSON] {
        var tools: [JSON] = []
        var predefined: Set<String> = []
        if let dialect {
            predefined = Set(ComputerUseNativeToolset.geminiMemberNames)
            tools.append(.object([
                "type": .string("computer_use"),
                "environment": .string((dialect.environment ?? .browser).rawValue),
                "excluded_predefined_functions": .array(dialect.geminiExcludedFunctionNames.map { .string($0) }),
                "enable_prompt_injection_detection": .boolean(true),
            ]))
        }
        for tool in config.availableTools where !predefined.contains(tool.name) {
            tools.append(.object([
                "type": .string("function"),
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parameters": ProviderHTTPStatus.parameterSchema(tool, raw: config.toolParameterSchemasByName[tool.name]),
            ]))
        }
        return tools
    }

    /// Everything after the assistant turn at `index`: a `function_result` step per tool result. Messages in between
    /// that aren't results ride along as text on the last result, since a turn of results can't carry other steps.
    private static func continuation(_ messages: [Message], from index: Int) -> [JSON] {
        let names = Dictionary(
            messages[index].toolCalls.compactMap { call in call.id.map { ($0, call.name) } },
            uniquingKeysWith: { first, _ in first }
        )
        var results: [[String: JSON]] = []
        var extra: [JSON] = []
        for message in messages[(index + 1)...] {
            guard message.role == .tool, let id = message.toolCallId else {
                extra += content(message)
                continue
            }
            var parts: [JSON] = [.object(["type": .string("text"), "text": .string(message.content)])]
            parts += images(message)
            var result: [String: JSON] = [
                "type": .string("function_result"),
                "call_id": .string(ChainedProviderCall(id).callID),
                "result": .array(parts),
            ]
            if let name = names[id] { result["name"] = .string(name) }
            if message.content == ComputerUseNativeToolset.haltText { result["is_error"] = .boolean(true) }
            results.append(result)
        }
        guard !results.isEmpty else { return extra }
        if !extra.isEmpty, case .array(let parts)? = results[results.count - 1]["result"] {
            results[results.count - 1]["result"] = .array(parts + extra)
        }
        return results.map(JSON.object)
    }

    /// A message as content blocks, labeled by who said it when that isn't the user.
    private static func content(_ message: Message) -> [JSON] {
        let text: String = switch message.role {
        case .assistant: message.content.isEmpty ? "" : "Assistant: \(message.content)"
        case .tool: "Result of \(message.toolCallId ?? "a tool call"): \(message.content)"
        case .user, .system: message.content
        }
        var blocks: [JSON] = []
        if !text.isEmpty { blocks.append(.object(["type": .string("text"), "text": .string(text)])) }
        return blocks + images(message)
    }

    private static func images(_ message: Message) -> [JSON] {
        message.images.compactMap { image in
            guard let data = image.imageData else { return nil }
            return .object([
                "type": .string("image"),
                "data": .string(data.base64EncodedString()),
                "mime_type": .string(image.mediaType ?? "image/png"),
            ])
        }
    }

    // MARK: - Response

    static func decode(_ json: JSON) throws -> Decoded {
        guard case .object(let root) = json else { throw LLMError.invalidResponse("Gemini Interactions: not an object") }
        if case .object(let error)? = root["error"], let message = string(error["message"]) {
            throw LLMError.invalidRequest("Gemini Interactions error: \(message)")
        }
        let status = string(root["status"])
        if status == "failed" {
            throw LLMError.invalidResponse("Gemini Interactions: the interaction failed")
        }
        let interactionID = string(root["id"])
        var text = ""
        var toolCalls: [ToolCall] = []
        var steps: [JSON] = []
        if case .array(let values)? = root["steps"] { steps = values } else if case .array(let values)? = root["outputs"] { steps = values }
        for step in steps {
            guard case .object(let fields) = step else { continue }
            switch string(fields["type"]) {
            case "model_output", "text":
                if let value = string(fields["text"]) { text += value }
                if case .array(let blocks)? = fields["content"] {
                    for case .object(let block) in blocks where string(block["type"]) == "text" {
                        text += string(block["text"]) ?? ""
                    }
                }
            case "function_call":
                guard let name = string(fields["name"]) else { continue }
                var arguments = fields["arguments"] ?? fields["args"] ?? .object([:])
                if case .string(let raw) = arguments { arguments = (try? ProviderHTTPStatus.decode(Data(raw.utf8))) ?? .object([:]) }
                let callID = string(fields["id"]) ?? string(fields["call_id"]) ?? UUID().uuidString
                toolCalls.append(ToolCall(
                    name: name,
                    arguments: arguments,
                    id: ChainedProviderCall(callID: callID, responseID: interactionID).toolCallID
                ))
            default:
                continue
            }
        }
        var usage: Usage?
        if case .object(let fields)? = root["usage"] {
            usage = Usage(
                inputTokens: int(fields["total_input_tokens"]),
                outputTokens: int(fields["total_output_tokens"]),
                totalTokens: int(fields["total_tokens"]),
                cachedTokens: int(fields["total_cached_tokens"])
            )
        }
        let finishReason = !toolCalls.isEmpty ? "tool_calls" : status == "incomplete" ? "length" : "stop"
        return Decoded(content: text, toolCalls: toolCalls, usage: usage, finishReason: finishReason)
    }

    private static func string(_ json: JSON?) -> String? {
        if case .string(let value)? = json { return value }
        return nil
    }

    private static func int(_ json: JSON?) -> Int? {
        switch json {
        case .integer(let value)?: return value
        case .double(let value)?: return Int(value)
        default: return nil
        }
    }
}
