import EasyJSON
import Foundation
import Logging
import SwiftAgentKit

actor AnthropicLLM: LLMProtocol, AdapterAuthProbing {
    private let apiURL: URL
    private let apiKey: String
    private let model: String
    private let capabilities: [LLMCapability]
    private let requestFeatures: ModelRequestFeatures
    private let systemPrompt: SystemPrompt
    private let logger: Logger?
    private let streamSource: any AnthropicStreamSourcing
    private let supportsEagerToolInputStreaming: Bool
    private let authProbePermissiveForEmptyToken: Bool

    init(
        apiURL: URL,
        apiKey: String,
        model: String,
        capabilities: [LLMCapability] = [.unknown],
        requestFeatures: ModelRequestFeatures = .unknown,
        systemPrompt: SystemPrompt,
        logger: Logger? = nil,
        streamSource: any AnthropicStreamSourcing = DefaultAnthropicStreamSource(),
        supportsEagerToolInputStreaming: Bool = true,
        authProbePermissiveForEmptyToken: Bool = false
    ) {
        self.apiURL = apiURL
        self.apiKey = apiKey
        self.model = model
        self.capabilities = capabilities
        self.requestFeatures = requestFeatures
        self.systemPrompt = systemPrompt
        self.logger = logger
        self.streamSource = streamSource
        self.supportsEagerToolInputStreaming = supportsEagerToolInputStreaming
        self.authProbePermissiveForEmptyToken = authProbePermissiveForEmptyToken
    }

    nonisolated func getModelName() -> String { model }
    nonisolated func getCapabilities() -> [LLMCapability] { capabilities }
    nonisolated func getRequestFeatures() -> ModelRequestFeatures { requestFeatures }

    func validateAuth() async -> Bool {
        let token = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if authProbePermissiveForEmptyToken,
           token.isEmpty || token == "dummy_key" || token == "dummy-key" {
            return true
        }
        if token.isEmpty {
            return false
        }
        var request = URLRequest(url: apiURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return true }
            switch http.statusCode {
            case 401, 403: return false
            default: return true
            }
        } catch {
            logger?.warning("Anthropic auth probe failed (treated as indeterminate/allow): \(error)")
            return true
        }
    }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        guard capabilities.contains(.completion) || capabilities.contains(.unknown) else {
            throw LLMError.unsupportedCapability(.completion)
        }
        let body = try await buildRequestBody(messages: messages, config: config, stream: false)
        let responseData = try await postRequest(body: body)
        return try parseMessageResponse(data: responseData, config: config)
    }

    nonisolated func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        guard capabilities.contains(.completion) || capabilities.contains(.unknown) else {
            return AsyncThrowingStream { $0.finish(throwing: LLMError.unsupportedCapability(.completion)) }
        }
        return AsyncThrowingStream { continuation in
            Task {
                var emitter = NormalizedStreamEmitter(
                    continuation: continuation,
                    supportsEagerToolInputStreaming: self.supportsEagerToolInputStreaming
                )
                do {
                    let body = try await self.buildRequestBody(messages: messages, config: config, stream: true)
                    let events = self.streamSource.messageStream(
                        apiURL: self.apiURL,
                        apiKey: self.apiKey,
                        requestBody: body,
                        logger: self.logger
                    )
                    var fullContent = ""
                    var accumulator = ToolCallAccumulator()
                    var usage: AnthropicUsage?
                    for try await event in events {
                        if Task.isCancelled {
                            emitter.finishCancelled()
                            return
                        }
                        switch event {
                        case .contentDelta(let text):
                            fullContent += text
                            emitter.yield(.textDelta(text), availableTools: config.availableTools)
                        case .thinkingBlockStarted(let signature):
                            emitter.yield(.thinkingDelta("", signature: signature), availableTools: config.availableTools)
                        case .thinkingDelta(let text, let signature):
                            emitter.yield(.thinkingDelta(text, signature: signature), availableTools: config.availableTools)
                        case .toolCallStarted(let id, let name, let contentIndex):
                            emitter.yield(
                                .toolCallStarted(id: id, name: name, contentIndex: contentIndex),
                                availableTools: config.availableTools
                            )
                        case .toolInputDelta(let id, let name, let fragment):
                            emitter.yield(
                                .toolCallDelta(id: id, name: name, argumentsFragment: fragment),
                                availableTools: config.availableTools
                            )
                            accumulator.ingestNameAndArgs(id: id, name: name, argumentsFragment: fragment)
                        case .messageDelta(let u):
                            if let u {
                                usage = u
                                emitter.yield(
                                    .usage(u.normalizedUsage),
                                    availableTools: config.availableTools
                                )
                            }
                        case .error(let message):
                            let llmError = AnthropicErrorMapping.apiError(message: message)
                            emitter.yield(
                                .error(NormalizedStreamError(
                                    classification: DefaultProviderFailoverClassifier.classify(llmError),
                                    message: message
                                )),
                                availableTools: config.availableTools
                            )
                            return
                        case .messageStop:
                            break
                        }
                    }
                    let toolCalls = accumulator.finalize()
                    let stopReason: NormalizedStopReason = toolCalls.isEmpty ? .end : .toolUse
                    emitter.yield(.stop(stopReason), availableTools: config.availableTools)
                    let metadata = LLMTokenMetadataBuilder.build(
                        inputTokens: usage?.inputTokens,
                        outputTokens: usage?.outputTokens,
                        remainingContextTokens: nil,
                        totalTokens: nil,
                        cacheReadTokens: usage?.cacheReadInputTokens,
                        cacheWriteTokens: usage?.cacheCreationInputTokens,
                        usageIsProviderReported: usage != nil,
                        finishReason: stopReason.finishReasonRawValue
                    )
                    emitter.finishSuccess(
                        content: fullContent,
                        toolCalls: toolCalls,
                        availableTools: config.availableTools,
                        metadata: metadata
                    )
                } catch is CancellationError {
                    emitter.finishCancelled()
                } catch let error as LLMError {
                    emitter.finishFailed(with: error)
                } catch {
                    emitter.finishFailed(with: LLMError.networkError(error))
                }
            }
        }
    }

    private func postRequest(body: Data) async throws -> Data {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.networkError(URLError(.badServerResponse))
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw LLMError.authenticationFailed
        }
        if http.statusCode == 429 {
            throw LLMError.rateLimitExceeded
        }
        if http.statusCode >= 500 {
            throw LLMError.networkError(URLError(.networkConnectionLost))
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AnthropicErrorMapping.apiError(message: message)
        }
        return data
    }

    private func parseMessageResponse(data: Data, config: LLMRequestConfig) throws -> LLMResponse {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var contentParts: [String] = []
        var toolCalls: [ToolCall] = []
        if let contentBlocks = json["content"] as? [[String: Any]] {
            for block in contentBlocks {
                let type = block["type"] as? String ?? ""
                switch type {
                case "text":
                    if let text = block["text"] as? String { contentParts.append(text) }
                case "tool_use":
                    let name = block["name"] as? String ?? ""
                    let id = block["id"] as? String ?? UUID().uuidString
                    let input = block["input"] as? [String: Any] ?? [:]
                    let inputData = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
                    let args = (try? JSONDecoder().decode(JSON.self, from: inputData)) ?? .object([:])
                    toolCalls.append(ToolCall(name: name, arguments: args, id: id))
                default:
                    continue
                }
            }
        }
        let usageJSON = json["usage"] as? [String: Any]
        let reportedUsage = CanonicalUsageExtraction.anthropicUsage(from: usageJSON)
        let metadata = LLMTokenMetadataBuilder.build(
            inputTokens: reportedUsage?.inputTokens,
            outputTokens: reportedUsage?.outputTokens,
            remainingContextTokens: nil,
            totalTokens: nil,
            cacheReadTokens: reportedUsage?.cacheReadTokens,
            cacheWriteTokens: reportedUsage?.cacheWriteTokens,
            usageIsProviderReported: reportedUsage != nil
        )
        return LLMResponse(
            content: contentParts.joined(),
            toolCalls: toolCalls,
            metadata: metadata
        )
    }

    private func buildRequestBody(
        messages: [Message],
        config: LLMRequestConfig,
        stream: Bool
    ) async throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": LLMTokenMetadataBuilder.maxCompletionTokens(from: config) ?? 4096,
            "stream": stream,
        ]
        if let temperature = config.temperature { body["temperature"] = temperature }
        if let topP = config.topP { body["top_p"] = topP }
        let promptMetadata = SystemPromptDispatchCodec.extractPromptMetadata(from: config.additionalParameters)
        let providerStablePrefix = SystemPromptDispatchCodec.extractProviderStablePrefix(from: config.additionalParameters)
        let plan = try await SystemPromptDispatchCodec.resolve(
            messages: messages,
            systemPrompt: systemPrompt,
            promptMetadata: promptMetadata,
            providerStablePrefix: providerStablePrefix
        )
        if let systemText = plan.canonicalSystemText, !systemText.isEmpty {
            body["system"] = systemText
        }
        body["messages"] = try anthropicMessages(from: plan.resolvedMessages)
        if !config.availableTools.isEmpty {
            body["tools"] = config.availableTools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.toAnthropicInputSchema(
                        parameterSchema: config.toolParameterSchemasByName[tool.name]
                    ),
                ] as [String: Any]
            }
            let policy = ToolChoiceTranslation.effectivePolicy(
                config: config,
                features: requestFeatures,
                hasTools: true,
                model: model,
                logger: logger
            )
            if let toolChoice = Self.toolChoiceWire(for: policy) {
                body["tool_choice"] = toolChoice
            }
        }
        if let thinking = extractThinkingPayload(from: config.additionalParameters) {
            body["thinking"] = thinking
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Anthropic `tool_choice` value for an already-clamped policy.
    /// ``ToolInvocationPolicy/automatic`` is the provider default and emits nothing.
    nonisolated static func toolChoiceWire(for policy: ToolInvocationPolicy) -> [String: Any]? {
        switch policy {
        case .automatic: return nil
        case .required: return ["type": "any"]
        case .none: return ["type": "none"]
        case .specific(let toolName): return ["type": "tool", "name": toolName]
        }
    }

    private func anthropicMessages(from messages: [Message]) throws -> [[String: Any]] {
        messages.compactMap { message in
            switch message.role {
            case .user:
                return ["role": "user", "content": message.content]
            case .assistant:
                return ["role": "assistant", "content": message.content]
            case .system:
                return nil
            case .tool:
                guard let toolCallID = message.toolCallId else { return nil }
                return [
                    "role": "user",
                    "content": [
                        [
                            "type": "tool_result",
                            "tool_use_id": toolCallID,
                            "content": message.content,
                        ] as [String: Any],
                    ],
                ]
            }
        }
    }

    private func extractThinkingPayload(from additionalParameters: JSON?) -> [String: Any]? {
        let caps = getCapabilities()
        guard caps.contains(.thinking) || caps.contains(.reasoningRequired),
              let additionalParameters,
              case .object(let root) = additionalParameters,
              let rawThinkingConfig = root["thinkingConfig"] else {
            return nil
        }
        guard let thinkingConfig = parseThinkingConfig(rawThinkingConfig) else { return nil }
        switch thinkingConfig {
        case .disabled, .level(.off, _):
            return nil
        case .adaptive, .level(.minimal, _), .level(.low, _), .level(.medium, _), .level(.high, _), .level(.xhigh, _):
            var payload: [String: Any] = ["type": "enabled"]
            if case .level(_, let budgetTokens) = thinkingConfig, let budgetTokens, budgetTokens > 0 {
                payload["budget_tokens"] = budgetTokens
            }
            return payload
        }
    }

    private func parseThinkingConfig(_ raw: JSON) -> ThinkingConfig? {
        switch raw {
        case .string(let value):
            switch value {
            case "disabled": return .disabled
            case "adaptive": return .adaptive
            default: return nil
            }
        case .object(let object):
            guard case .string(let levelRaw)? = object["level"],
                  let level = ThinkingLevel(rawValue: levelRaw) else { return nil }
            let budgetTokens: Int?
            if case .integer(let tokenInt)? = object["budgetTokens"] {
                budgetTokens = tokenInt
            } else {
                budgetTokens = nil
            }
            return .level(level, budgetTokens: budgetTokens)
        default:
            return nil
        }
    }
}

enum AnthropicStreamEvent: Sendable {
    case contentDelta(String)
    case thinkingDelta(String, signature: String?)
    case thinkingBlockStarted(signature: String?)
    case toolCallStarted(id: String?, name: String?, contentIndex: Int?)
    case toolInputDelta(id: String?, name: String?, fragment: String)
    case messageDelta(AnthropicUsage?)
    case messageStop
    case error(String)
}

struct AnthropicUsage: Sendable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?

    init(
        inputTokens: Int?,
        outputTokens: Int?,
        cacheReadInputTokens: Int? = nil,
        cacheCreationInputTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
    }

    init(usageJSON: [String: Any]) {
        self.inputTokens = usageJSON["input_tokens"] as? Int
        self.outputTokens = usageJSON["output_tokens"] as? Int
        self.cacheReadInputTokens = usageJSON["cache_read_input_tokens"] as? Int
        self.cacheCreationInputTokens = usageJSON["cache_creation_input_tokens"] as? Int
    }

    var normalizedUsage: NormalizedUsage {
        NormalizedUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadInputTokens,
            cacheWriteTokens: cacheCreationInputTokens,
            reasoningTokens: nil
        )
    }
}

protocol AnthropicStreamSourcing: Sendable {
    func messageStream(
        apiURL: URL,
        apiKey: String,
        requestBody: Data,
        logger: Logger?
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error>
}

struct DefaultAnthropicStreamSource: AnthropicStreamSourcing {
    func messageStream(
        apiURL: URL,
        apiKey: String,
        requestBody: Data,
        logger: Logger?
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var request = URLRequest(url: apiURL)
                    request.httpMethod = "POST"
                    request.httpBody = requestBody
                    request.timeoutInterval = 300
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: LLMError.networkError(URLError(.badServerResponse)))
                        return
                    }
                    if http.statusCode == 401 || http.statusCode == 403 {
                        continuation.finish(throwing: LLMError.authenticationFailed)
                        return
                    }
                    if http.statusCode == 429 {
                        continuation.finish(throwing: LLMError.rateLimitExceeded)
                        return
                    }
                    if http.statusCode >= 500 {
                        continuation.finish(throwing: LLMError.networkError(URLError(.networkConnectionLost)))
                        return
                    }
                    guard (200 ... 299).contains(http.statusCode) else {
                        continuation.finish(throwing: AnthropicErrorMapping.apiError(message: "HTTP \(http.statusCode)"))
                        return
                    }
                    var eventName: String?
                    var dataLines: [String] = []
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            dataLines.append(String(line.dropFirst(5).trimmingCharacters(in: .whitespaces)))
                        } else if line.isEmpty {
                            let payload = dataLines.joined(separator: "\n")
                            if !payload.isEmpty {
                                for event in AnthropicSSEParser.events(fromJSONLine: payload, eventName: eventName) {
                                    continuation.yield(event)
                                }
                            }
                            eventName = nil
                            dataLines = []
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: LLMError.networkError(error))
                }
            }
        }
    }
}

enum AnthropicSSEParser {
    static func events(fromJSONLine jsonLine: String, eventName: String?) -> [AnthropicStreamEvent] {
        guard let data = jsonLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        let type = object["type"] as? String ?? eventName ?? ""
        switch type {
        case "content_block_start":
            if let block = object["content_block"] as? [String: Any] {
                let blockType = block["type"] as? String ?? ""
                if blockType == "tool_use" {
                    let id = block["id"] as? String
                    let name = block["name"] as? String
                    let index = object["index"] as? Int
                    return [.toolCallStarted(id: id, name: name, contentIndex: index)]
                }
                if blockType == "thinking" {
                    let signature = block["signature"] as? String
                    return [.thinkingBlockStarted(signature: signature)]
                }
            }
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String
            else { return [] }
            switch deltaType {
            case "text_delta":
                if let text = delta["text"] as? String { return [.contentDelta(text)] }
            case "thinking_delta":
                if let thinking = delta["thinking"] as? String {
                    let signature = delta["signature"] as? String
                    return [.thinkingDelta(thinking, signature: signature)]
                }
            case "input_json_delta":
                if let fragment = delta["partial_json"] as? String {
                    return [.toolInputDelta(id: nil, name: nil, fragment: fragment)]
                }
            default:
                return []
            }
        case "message_delta":
            if let usage = object["usage"] as? [String: Any] {
                return [.messageDelta(AnthropicUsage(usageJSON: usage))]
            }
            return [.messageDelta(nil)]
        case "message_stop":
            return [.messageStop]
        case "error":
            let message = (object["error"] as? [String: Any])?["message"] as? String ?? "Anthropic stream error"
            return [.error(message)]
        default:
            return []
        }
        return []
    }
}

enum AnthropicErrorMapping {
    static func apiError(message: String) -> LLMError {
        LLMError.networkError(NSError(domain: "AnthropicLLM", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
    }
}

private extension ToolDefinition {
    func toAnthropicInputSchema(parameterSchema: JSON? = nil) -> [String: Any] {
        if let parameterSchema {
            return ToolSchemaWireCodec.anthropicInputSchema(from: parameterSchema)
        }
        var properties: [String: Any] = [:]
        var required: [String] = []
        for param in parameters {
            properties[param.name] = [
                "type": param.type,
                "description": param.description,
            ]
            if param.required {
                required.append(param.name)
            }
        }
        return [
            "type": "object",
            "properties": properties,
            "required": required,
        ]
    }
}
