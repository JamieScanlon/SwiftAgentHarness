import EasyJSON
import Foundation
import Logging
import SwiftAgentKit

actor AnthropicLLM: LLMProtocol, AdapterAuthProbing {
    typealias AuthProbeTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let messagesURL: URL
    private let modelsURL: URL
    private let apiKey: String
    private let model: String
    private let capabilities: [LLMCapability]
    private let requestFeatures: ModelRequestFeatures
    private let systemPrompt: SystemPrompt
    private let logger: Logger?
    private let streamSource: any AnthropicStreamSourcing
    private let supportsEagerToolInputStreaming: Bool
    private let authProbePermissiveForEmptyToken: Bool
    private let authProbeTransport: AuthProbeTransport?

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
        authProbePermissiveForEmptyToken: Bool = false,
        authProbeTransport: AuthProbeTransport? = nil
    ) {
        self.messagesURL = AnthropicEndpointURLs.messagesURL(from: apiURL)
        self.modelsURL = AnthropicEndpointURLs.modelsURL(from: apiURL)
        self.apiKey = apiKey
        self.model = model
        self.capabilities = capabilities
        self.requestFeatures = requestFeatures
        self.systemPrompt = systemPrompt
        self.logger = logger
        self.streamSource = streamSource
        self.supportsEagerToolInputStreaming = supportsEagerToolInputStreaming
        self.authProbePermissiveForEmptyToken = authProbePermissiveForEmptyToken
        self.authProbeTransport = authProbeTransport
    }

    nonisolated func getModelName() -> String { model }
    nonisolated func getCapabilities() -> [LLMCapability] { capabilities }
    nonisolated func getRequestFeatures() -> ModelRequestFeatures { requestFeatures }

    /// Test hook: resolved Messages API URL (no network).
    nonisolated func testMessagesURL() -> URL { messagesURL }

    /// Test hook: resolved Models API URL used by auth probe (no network).
    nonisolated func testModelsURL() -> URL { modelsURL }

    func validateAuth() async -> Bool {
        let token = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if authProbePermissiveForEmptyToken,
           token.isEmpty || token == "dummy_key" || token == "dummy-key" {
            return true
        }
        if token.isEmpty {
            return false
        }
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        do {
            let (_, response) = try await runAuthProbe(request: request)
            switch response.statusCode {
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
                        apiURL: self.messagesURL,
                        apiKey: self.apiKey,
                        requestBody: body,
                        logger: self.logger
                    )
                    var fullContent = ""
                    var accumulator = ToolCallAccumulator()
                    var usage: AnthropicUsage?
                    var stopReasonRaw: String?
                    var sawStreamEvent = false
                    var sawThinking = false
                    var announcedToolUseBlocks: Set<String> = []
                    for try await event in events {
                        if Task.isCancelled {
                            emitter.finishCancelled()
                            return
                        }
                        sawStreamEvent = true
                        switch event {
                        case .contentDelta(let text):
                            fullContent += text
                            emitter.yield(.textDelta(text), availableTools: config.availableTools)
                        case .thinkingBlockStarted(let signature):
                            sawThinking = true
                            emitter.yield(.thinkingDelta("", signature: signature), availableTools: config.availableTools)
                        case .thinkingDelta(let text, let signature):
                            sawThinking = true
                            emitter.yield(.thinkingDelta(text, signature: signature), availableTools: config.availableTools)
                        case .toolCallStarted(let id, let name, let contentIndex):
                            announcedToolUseBlocks.insert(id ?? "index:\(contentIndex.map(String.init) ?? "?")")
                            accumulator.ingestNameAndArgs(id: id, name: name, argumentsFragment: "")
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
                        case .messageDelta(let u, let stopReason):
                            if let stopReason, !stopReason.isEmpty {
                                stopReasonRaw = stopReason
                            }
                            if let u {
                                usage = u
                                emitter.yield(
                                    .usage(u.normalizedUsage),
                                    availableTools: config.availableTools
                                )
                            }
                        case .error(let message):
                            emitter.finishFailed(with: AnthropicErrorMapping.sseErrorEvent(message: message))
                            return
                        case .messageStop:
                            break
                        }
                    }
                    let toolCalls = accumulator.finalize()
                    if let failure = Self.degenerateStreamFailure(
                        sawStreamEvent: sawStreamEvent,
                        text: fullContent,
                        sawThinking: sawThinking,
                        announcedToolUseBlockCount: announcedToolUseBlocks.count,
                        toolCalls: toolCalls,
                        stopReasonRaw: stopReasonRaw
                    ) {
                        self.logger?.error("\(failure.detail)")
                        emitter.finishFailed(with: failure)
                        return
                    }
                    let canonicalFinish = FinishReason.fromAnthropic(stopReasonRaw)
                    let stopReason: NormalizedStopReason = {
                        if stopReasonRaw != nil {
                            return NormalizedStopReason(finishReason: canonicalFinish)
                        }
                        return toolCalls.isEmpty ? .end : .toolUse
                    }()
                    emitter.yield(.stop(stopReason), availableTools: config.availableTools)
                    let storedFinishReason: String = {
                        if canonicalFinish == .unknown, let stopReasonRaw, !stopReasonRaw.isEmpty {
                            return stopReasonRaw
                        }
                        return stopReason.finishReasonRawValue
                    }()
                    let metadata = LLMTokenMetadataBuilder.build(
                        inputTokens: usage?.inputTokens,
                        outputTokens: usage?.outputTokens,
                        remainingContextTokens: nil,
                        totalTokens: nil,
                        cacheReadTokens: usage?.cacheReadInputTokens,
                        cacheWriteTokens: usage?.cacheCreationInputTokens,
                        usageIsProviderReported: usage != nil,
                        finishReason: storedFinishReason
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

    /// Diagnoses a stream that terminated without delivering anything the caller can act on.
    ///
    /// Returns `nil` when the turn is legitimately empty — a provider-reported terminal
    /// `stop_reason` with no text is rare but real, and must still complete as a success.
    /// A non-`nil` result means the turn has to fail: completing it would persist a blank
    /// assistant message stamped with a successful finish reason, which is indistinguishable
    /// from the model choosing to say nothing.
    ///
    /// The dropped-tool-call check is evidence-based — it compares announced `tool_use` content
    /// blocks against assembled calls, and never consults `stop_reason`, which providers set
    /// inconsistently enough that failing a turn on it would reject good responses.
    nonisolated static func degenerateStreamFailure(
        sawStreamEvent: Bool,
        text: String,
        sawThinking: Bool,
        announcedToolUseBlockCount: Int,
        toolCalls: [ToolCall],
        stopReasonRaw: String?
    ) -> DegenerateStreamError? {
        func failure(_ kind: DegenerateStreamError.Kind, _ detail: String) -> DegenerateStreamError {
            DegenerateStreamError(kind: kind, provider: "Anthropic", detail: detail)
        }
        // Checked before the content check: losing one call out of several is broken even
        // though the surviving calls and any text would otherwise look like a healthy turn.
        if announcedToolUseBlockCount > toolCalls.count {
            return failure(
                .announcedToolCallLost,
                """
                Anthropic stream announced \(announcedToolUseBlockCount) tool_use content \
                block(s) but assembled \(toolCalls.count) tool call(s)
                """
            )
        }
        if !text.isEmpty || !toolCalls.isEmpty || sawThinking {
            return nil
        }
        if !sawStreamEvent {
            return failure(.noEvents, "Anthropic stream completed with no SSE events")
        }
        if stopReasonRaw == nil {
            return failure(.noOutcome, "Anthropic stream produced no text, tool calls, or stop_reason")
        }
        return nil
    }

    /// Test hook: encodes a Messages request body for the given messages (no network).
    func testEncodedRequestBody(from messages: [Message], config: LLMRequestConfig) async throws -> Data {
        try await buildRequestBody(messages: messages, config: config, stream: false)
    }

    private func runAuthProbe(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let authProbeTransport {
            return try await authProbeTransport(request)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.networkError(URLError(.badServerResponse))
        }
        return (data, http)
    }

    private func postRequest(body: Data) async throws -> Data {
        var request = URLRequest(url: messagesURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 120
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await URLSession.shared.data(for: request)
        try AnthropicErrorMapping.validate(response, body: data)
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
        let stopReasonRaw = json["stop_reason"] as? String
        let canonicalFinish = FinishReason.fromAnthropic(stopReasonRaw)
        let storedFinishReason: String? = {
            guard let stopReasonRaw, !stopReasonRaw.isEmpty else { return nil }
            if canonicalFinish == .unknown { return stopReasonRaw }
            return canonicalFinish.rawValue
        }()
        let metadata = LLMTokenMetadataBuilder.build(
            inputTokens: reportedUsage?.inputTokens,
            outputTokens: reportedUsage?.outputTokens,
            remainingContextTokens: nil,
            totalTokens: nil,
            cacheReadTokens: reportedUsage?.cacheReadTokens,
            cacheWriteTokens: reportedUsage?.cacheWriteTokens,
            usageIsProviderReported: reportedUsage != nil,
            finishReason: storedFinishReason
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
            body["system"] = AnthropicPromptCacheWire.systemPayload(
                systemText: systemText,
                additionalParameters: config.additionalParameters
            )
        }
        body["messages"] = try anthropicMessages(from: plan.resolvedMessages, config: config)
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

    private func anthropicMessages(from messages: [Message], config: LLMRequestConfig) throws -> [[String: Any]] {
        let dispositions = AttachmentProjectionDispatchCodec.extractDispositions(from: config.additionalParameters)
        var encoded: [[String: Any]] = []
        encoded.reserveCapacity(messages.count)
        for message in messages {
            switch message.role {
            case .user:
                encoded.append(try encodeUserMessage(message, dispositions: dispositions, config: config))
            case .assistant:
                encoded.append(try encodeAssistantMessage(message))
            case .system:
                continue
            case .tool:
                guard let toolCallID = message.toolCallId else { continue }
                encoded.append([
                    "role": "user",
                    "content": [
                        [
                            "type": "tool_result",
                            "tool_use_id": toolCallID,
                            "content": message.content,
                        ] as [String: Any],
                    ],
                ])
            }
        }
        return encoded
    }

    private func encodeUserMessage(
        _ message: Message,
        dispositions: [String: String],
        config: LLMRequestConfig
    ) throws -> [String: Any] {
        let text = message.content + attachmentDispositionSuffix(
            imageNames: message.images.map(\.name),
            dispositions: dispositions,
            additionalParameters: config.additionalParameters
        )
        let imageBlocks = AnthropicVisionContent.imageContentBlocks(
            from: message.images,
            dispositions: dispositions
        )
        if imageBlocks.isEmpty {
            return ["role": "user", "content": text]
        }
        var parts: [[String: Any]] = [["type": "text", "text": text]]
        parts.append(contentsOf: imageBlocks)
        return ["role": "user", "content": parts]
    }

    private func encodeAssistantMessage(_ message: Message) throws -> [String: Any] {
        if message.toolCalls.isEmpty {
            return ["role": "assistant", "content": message.content]
        }
        var blocks: [[String: Any]] = []
        if !message.content.isEmpty {
            blocks.append(["type": "text", "text": message.content])
        }
        for toolCall in message.toolCalls {
            let input = try toolCallArgumentsDictionary(toolCall.arguments)
            blocks.append([
                "type": "tool_use",
                "id": toolCall.id ?? UUID().uuidString,
                "name": toolCall.name,
                "input": input,
            ])
        }
        return ["role": "assistant", "content": blocks]
    }

    private func toolCallArgumentsDictionary(_ arguments: JSON) throws -> [String: Any] {
        let data = try JSONEncoder().encode(arguments)
        let object = try JSONSerialization.jsonObject(with: data)
        return (object as? [String: Any]) ?? [:]
    }

    nonisolated private func attachmentDispositionSuffix(
        imageNames: [String],
        dispositions: [String: String],
        additionalParameters: JSON?
    ) -> String {
        if AttachmentProjectionDispatchCodec.hasMaterializedBlocks(in: additionalParameters) {
            return ""
        }
        let projected = imageNames.compactMap { name -> String? in
            guard let disposition = dispositions[name],
                  disposition != ConversationAttachmentProjectionDisposition.inline.rawValue else {
                return nil
            }
            return "\(name):\(disposition)"
        }
        guard !projected.isEmpty else { return "" }
        return "\n\n[Attachment projection]\n" + projected.joined(separator: "\n")
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
    case messageDelta(usage: AnthropicUsage?, stopReason: String?)
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
                    // An SSE turn is never idempotent, and a cached entry replays as a
                    // truncated body with no events. Response caching is a Model Pool
                    // decision, not a transport default.
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    do {
                        try AnthropicErrorMapping.validate(response, body: nil)
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                    var decoder = AnthropicSSEFrameDecoder()
                    for try await line in bytes.lines {
                        for event in decoder.consume(line: line) {
                            continuation.yield(event)
                        }
                    }
                    // A body that ends without its terminating blank line still holds a
                    // complete frame; dropping it loses the final delta or stop reason.
                    for event in decoder.flush() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as LLMError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: LLMError.networkError(error))
                }
            }
        }
    }
}

/// Assembles SSE lines into frames and maps each complete frame to stream events.
///
/// Split out of ``DefaultAnthropicStreamSource`` so frame boundaries — including a body that
/// ends without its terminating blank line — are exercisable without a network transport.
struct AnthropicSSEFrameDecoder {
    private var eventName: String?
    private var dataLines: [String] = []

    init() {}

    mutating func consume(line: String) -> [AnthropicStreamEvent] {
        if line.hasPrefix("event:") {
            eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            return []
        }
        if line.hasPrefix("data:") {
            dataLines.append(String(line.dropFirst(5).trimmingCharacters(in: .whitespaces)))
            return []
        }
        if line.isEmpty {
            return flush()
        }
        return []
    }

    /// Emits whatever frame is still buffered. Called at end-of-body so a stream that closes
    /// without a trailing blank line does not silently drop its last frame.
    mutating func flush() -> [AnthropicStreamEvent] {
        defer {
            eventName = nil
            dataLines = []
        }
        let payload = dataLines.joined(separator: "\n")
        guard !payload.isEmpty else { return [] }
        return AnthropicSSEParser.events(fromJSONLine: payload, eventName: eventName)
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
            let stopReason = (object["delta"] as? [String: Any])?["stop_reason"] as? String
            if let usage = object["usage"] as? [String: Any] {
                return [.messageDelta(usage: AnthropicUsage(usageJSON: usage), stopReason: stopReason)]
            }
            return [.messageDelta(usage: nil, stopReason: stopReason)]
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

/// Maps Anthropic HTTP status codes and SSE error events to typed ``LLMError``.
enum AnthropicErrorMapping {
    static func validate(_ response: URLResponse, body: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse("Non-HTTP response from Anthropic")
        }
        let status = http.statusCode
        switch status {
        case 200...299:
            return
        case 408, 504:
            throw LLMError.timeout
        case 429:
            throw LLMError.rateLimitExceeded
        case 401, 403:
            throw LLMError.authenticationFailed
        case 404:
            throw LLMError.modelNotFound("Anthropic HTTP 404")
        case 500...599:
            throw LLMError.networkError(URLError(.badServerResponse))
        default:
            let message = body.flatMap { String(data: $0, encoding: .utf8) } ?? "HTTP \(status)"
            throw LLMError.invalidRequest("Anthropic HTTP \(status): \(message)")
        }
    }

    static func sseErrorEvent(message: String) -> LLMError {
        .invalidResponse("Anthropic SSE error: \(message)")
    }

    static func apiError(message: String) -> LLMError {
        .invalidResponse("Anthropic API error: \(message)")
    }

    static func map(_ raw: Error) -> LLMError {
        if let llmError = raw as? LLMError { return llmError }
        return .networkError(raw)
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
