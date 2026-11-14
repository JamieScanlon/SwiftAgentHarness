import EasyJSON
import Foundation
import SwiftAgentKit

/// OpenAI's Responses API, for a computer-use session on OpenAI's `computer` tool.
///
/// A `computer_call` becomes one `computer` tool call carrying its `actions` and `pending_safety_checks`; its result
/// goes back as a `computer_call_output` with the screenshot, acknowledging the pending checks only when the
/// result says the user confirmed them. Turns continue from the stored response, so only what came after the
/// latest assistant turn is sent.
enum OpenAIResponsesComputerCodec {
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

    static func requestBody(
        model: String,
        messages: [Message],
        config: LLMRequestConfig,
        reasoningEffort: String?
    ) -> JSON {
        var body: [String: JSON] = [
            "model": .string(model),
            "store": .boolean(true),
            "truncation": .string("auto"),
            "tools": .array(tools(config)),
        ]
        let instructions = messages.filter { $0.role == .system }.map(\.content).filter { !$0.isEmpty }
        if !instructions.isEmpty { body["instructions"] = .string(instructions.joined(separator: "\n\n")) }
        let conversation = messages.filter { $0.role != .system }
        if let chain = ChainedProviderCall.chain(in: conversation) {
            body["previous_response_id"] = .string(chain.responseID)
            body["input"] = .array(continuation(conversation, from: chain.index))
        } else {
            body["input"] = .array(transcript(conversation))
        }
        if let maxTokens = LLMTokenMetadataBuilder.maxCompletionTokens(from: config) {
            body["max_output_tokens"] = .integer(maxTokens)
        }
        if let reasoningEffort { body["reasoning"] = .object(["effort": .string(reasoningEffort)]) }
        return .object(body)
    }

    private static func tools(_ config: LLMRequestConfig) -> [JSON] {
        var tools: [JSON] = [.object(["type": .string(ComputerUseNativeToolset.openAIComputer.rawValue)])]
        for tool in config.availableTools where tool.name != ComputerUseNativeToolset.name {
            tools.append(.object([
                "type": .string("function"),
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parameters": ProviderHTTPStatus.parameterSchema(tool, raw: config.toolParameterSchemasByName[tool.name]),
                "strict": .boolean(false),
            ]))
        }
        return tools
    }

    /// Everything after the assistant turn at `index`, as Responses input items.
    private static func continuation(_ messages: [Message], from index: Int) -> [JSON] {
        let calls = Dictionary(
            messages[index].toolCalls.compactMap { call in call.id.map { ($0, call) } },
            uniquingKeysWith: { first, _ in first }
        )
        var items: [JSON] = []
        var notes: [JSON] = []
        func flushNotes() {
            guard !notes.isEmpty else { return }
            items.append(.object(["role": .string("user"), "content": .array(notes)]))
            notes = []
        }
        for message in messages[(index + 1)...] {
            guard message.role == .tool, let id = message.toolCallId else {
                flushNotes()
                items.append(contentsOf: transcript([message]))
                continue
            }
            let call = calls[id]
            let callID = ChainedProviderCall(id).callID
            if call?.name == ComputerUseNativeToolset.name {
                var lines = message.content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                let acknowledged = lines.contains(ComputerUseOpenAIToolProvider.acknowledgedLine)
                lines.removeAll { $0 == ComputerUseOpenAIToolProvider.acknowledgedLine || $0 == "OK" }
                if let screenshot = message.images.lazy.compactMap(ProviderHTTPStatus.dataURL).first {
                    var output: [String: JSON] = [
                        "type": .string("computer_call_output"),
                        "call_id": .string(callID),
                        "output": .object(["type": .string("computer_screenshot"), "image_url": .string(screenshot), "detail": .string("original")]),
                    ]
                    if acknowledged, case .object(let arguments)? = call?.arguments,
                       case .array(let checks)? = arguments["pending_safety_checks"], !checks.isEmpty {
                        output["acknowledged_safety_checks"] = .array(checks)
                    }
                    items.append(.object(output))
                }
                let note = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !note.isEmpty { notes.append(.object(["type": .string("input_text"), "text": .string("Computer call \(callID): \(note)")])) }
            } else {
                // A function's output can hold images, so a screenshot stays with the call it answers.
                let urls = message.images.compactMap(ProviderHTTPStatus.dataURL)
                let output: JSON = urls.isEmpty
                    ? .string(message.content)
                    : .array(
                        (message.content.isEmpty ? [] : [.object(["type": .string("input_text"), "text": .string(message.content)])])
                            + urls.map { .object(["type": .string("input_image"), "image_url": .string($0), "detail": .string("auto")]) }
                    )
                items.append(.object([
                    "type": .string("function_call_output"),
                    "call_id": .string(callID),
                    "output": output,
                ]))
            }
        }
        flushNotes()
        return items
    }

    /// Messages as plain conversation items, for a request with no stored response to continue from.
    private static func transcript(_ messages: [Message]) -> [JSON] {
        messages.map { message in
            switch message.role {
            case .assistant:
                var text = message.content
                for call in message.toolCalls {
                    text += "\n[called \(call.name)]"
                }
                return .object(["role": .string("assistant"), "content": .string(text)])
            case .system:
                return .object(["role": .string("developer"), "content": .string(message.content)])
            case .user, .tool:
                var content: [JSON] = []
                let text = message.role == .tool ? "Result of \(message.toolCallId ?? "a tool call"): \(message.content)" : message.content
                if !text.isEmpty { content.append(.object(["type": .string("input_text"), "text": .string(text)])) }
                for url in message.images.compactMap(ProviderHTTPStatus.dataURL) {
                    content.append(.object(["type": .string("input_image"), "image_url": .string(url), "detail": .string("auto")]))
                }
                return .object(["role": .string("user"), "content": .array(content)])
            }
        }
    }

    // MARK: - Response

    static func decode(_ json: JSON) throws -> Decoded {
        guard case .object(let root) = json else { throw LLMError.invalidResponse("OpenAI Responses: not an object") }
        if case .object(let error)? = root["error"], case .string(let message)? = error["message"] {
            throw LLMError.invalidRequest("OpenAI Responses error: \(message)")
        }
        let responseID = string(root["id"])
        var text = ""
        var toolCalls: [ToolCall] = []
        if case .array(let output)? = root["output"] {
            for item in output {
                guard case .object(let fields) = item else { continue }
                switch string(fields["type"]) {
                case "message":
                    guard case .array(let parts)? = fields["content"] else { continue }
                    for part in parts {
                        guard case .object(let part) = part else { continue }
                        if let value = string(part["text"]) ?? string(part["refusal"]) { text += value }
                    }
                case "computer_call":
                    var arguments: [String: JSON] = [:]
                    if case .array(let actions)? = fields["actions"] {
                        arguments["actions"] = .array(actions)
                    } else if let action = fields["action"] {
                        arguments["actions"] = .array([action])
                    }
                    if case .array(let checks)? = fields["pending_safety_checks"], !checks.isEmpty {
                        arguments["pending_safety_checks"] = .array(checks)
                    }
                    let callID = string(fields["call_id"]) ?? string(fields["id"]) ?? UUID().uuidString
                    toolCalls.append(ToolCall(
                        name: ComputerUseNativeToolset.name,
                        arguments: .object(arguments),
                        id: ChainedProviderCall(callID: callID, responseID: responseID).toolCallID
                    ))
                case "function_call":
                    guard let name = string(fields["name"]) else { continue }
                    let raw = string(fields["arguments"]) ?? "{}"
                    let arguments = (try? ProviderHTTPStatus.decode(Data(raw.utf8))) ?? .object([:])
                    let callID = string(fields["call_id"]) ?? string(fields["id"]) ?? UUID().uuidString
                    toolCalls.append(ToolCall(
                        name: name,
                        arguments: arguments,
                        id: ChainedProviderCall(callID: callID, responseID: responseID).toolCallID
                    ))
                default:
                    continue
                }
            }
        }
        var usage: Usage?
        if case .object(let fields)? = root["usage"] {
            var cached: Int?
            if case .object(let details)? = fields["input_tokens_details"] { cached = int(details["cached_tokens"]) }
            usage = Usage(
                inputTokens: int(fields["input_tokens"]),
                outputTokens: int(fields["output_tokens"]),
                totalTokens: int(fields["total_tokens"]),
                cachedTokens: cached
            )
        }
        var finishReason = toolCalls.isEmpty ? "stop" : "tool_calls"
        if string(root["status"]) == "incomplete" {
            if case .object(let details)? = root["incomplete_details"], string(details["reason"]) == "max_output_tokens" {
                finishReason = "length"
            } else {
                finishReason = "content_filter"
            }
        }
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
