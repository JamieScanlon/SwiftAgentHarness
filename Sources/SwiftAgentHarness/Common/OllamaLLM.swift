//
//  Conforms to the ``AdapterContract``: routes streaming tool-call
//  accumulation through ``ToolCallAccumulator`` (collapses Ollama's done-chunk
//  duplicate tool list); throws `CancellationError` on consumer cancellation;
//  emits exactly one `.complete` then `finish()` via
//  ``StreamCompletionEmitter`` on success; wraps unknown stream / send errors
//  via `LLMError.networkError(_:)`. Per-HTTP-status precision is handled by
//  ``OllamaHTTPStatusMapping``.
//

import EasyJSON
import Foundation
import Logging
import OllamaKit
import SwiftAgentKit

actor OllamaLLM: LLMProtocol, AdapterAuthProbing {
    
    let model: String
    let serverURL: URL
    let capabilities: [LLMCapability]
    let requestFeatures: ModelRequestFeatures
    let DEFAUT_MAX_TOKENS: Int = 131072
    let requestTimeoutInterval: TimeInterval?
    
    private let systemPrompt: SystemPrompt
    private let logger: Logger?
    private let streamSource: any OllamaChatStreamSourcing
    private let supportsEagerToolInputStreaming: Bool
    
    init(
        model: String,
        serverURL: URL,
        capabilities: [LLMCapability] = [.unknown],
        requestFeatures: ModelRequestFeatures = .unknown,
        systemPrompt: SystemPrompt,
        requestTimeoutInterval: TimeInterval? = nil,
        logger: Logger? = nil,
        streamSource: any OllamaChatStreamSourcing = DefaultOllamaChatStreamSource(),
        supportsEagerToolInputStreaming: Bool = false
    ) {
        self.model = model
        self.serverURL = serverURL
        self.capabilities = capabilities
        self.requestFeatures = requestFeatures
        self.systemPrompt = systemPrompt
        self.requestTimeoutInterval = requestTimeoutInterval
        self.logger = logger
        self.streamSource = streamSource
        self.supportsEagerToolInputStreaming = supportsEagerToolInputStreaming
    }
    
    /// Returns the model name for this LLM instance
    nonisolated func getModelName() -> String {
        return model
    }
    
    nonisolated func getCapabilities() -> [SwiftAgentKit.LLMCapability] {
        return capabilities
    }

    nonisolated func getRequestFeatures() -> ModelRequestFeatures {
        requestFeatures
    }

    nonisolated func validateAuth() async -> Bool {
        true
    }
    
    /// Send multiple messages to the LLM and get a response.
    ///
    /// Contract: returns one `LLMResponse` with `isComplete: true`, or throws.
    /// Cancellation is surfaced as `CancellationError`; provider failures map to
    /// `LLMError` via ``OllamaHTTPStatusMapping`` (HTTP statuses) or
    /// ``LLMError/networkError(_:)`` (unknown transport failures).
    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        
        guard getCapabilities().contains(.completion) || getCapabilities().contains(.unknown) else {
            logger?.error("Unsupported LLM capability: \(getCapabilities())")
            throw LLMError.unsupportedCapability(.completion)
        }
        
        let model = getModelName()
        logPromptCacheNoOpIfNeeded(config: config)
        let requestData = try await createOllamaChatRequest(model: model, messages: messages, config: config)
        logRequestPayloadIfDebug(requestData)
        var partialResponse: String = ""
        var fullThinking: String = ""
        var accumulator = ToolCallAccumulator()
        
        do {
            for try await chunk in streamSource.chatStream(
                baseURL: serverURL,
                requestData: requestData,
                timeout: requestTimeoutInterval,
                logger: logger
            ) {
                if Task.isCancelled { throw CancellationError() }
                let messageContent = chunk.message?.content
                
                let chunkToolCalls: [ToolCall] = (chunk.message?.toolCalls ?? []).compactMap { $0.toolCall() }
                if !chunkToolCalls.isEmpty {
                    accumulator.ingestFinalList(chunkToolCalls)
                }
                
                partialResponse += (messageContent ?? "")
                fullThinking += (chunk.message?.thinking ?? "")
                
                if chunk.done == true {
                    let approxChars = messages.reduce(0) { $0 + $1.content.count }
                    let toolCalls = accumulator.finalize()
                    logger?.info("[OllamaLLM] Done (send)\(LLMRequestPurposeReader.logSuffix(from: config)) - doneReason: \(chunk.doneReason ?? "nil"), toolCalls: \(toolCalls.count), contentLength: \(partialResponse.count), thinkingLength: \(fullThinking.count)")
                    logger?.debug("[OllamaLLM] usage: prompt_eval_count=\(chunk.promptEvalCount.map(String.init) ?? "nil") eval_count=\(chunk.evalCount.map(String.init) ?? "nil") messagesInRequest=\(messages.count) approxCharsInMessages=\(approxChars)")
                    let numCtx = requestData.options?.numCtx ?? config.maxTokens ?? DEFAUT_MAX_TOKENS
                    let metadata = ollamaMetadata(from: chunk, numCtx: numCtx)
                    let response = LLMResponse.llmResponse(from: partialResponse, availableTools: config.availableTools)
                        .appending(toolCalls: toolCalls)
                        .updatingMetadata(with: metadata)
                    logLLMResponsePayloadIfDebug(response)
                    return response
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LLMError {
            throw error
        } catch {
            // Wrap unknown transport-layer failures so ``TransientErrorClassifier`` can recurse.
            // ``OllamaHTTPStatusMapping`` already produces typed `LLMError` for status-code
            // failures inside the lenient stream.
            throw LLMError.networkError(error)
        }
        
        // Stream ended without a `done` chunk (server-side disconnect). Surface whatever
        // partial content we have without sentinel-text injection — the contract forbids
        // synthesised content tokens (`_CANCELLED_`).
        let response = LLMResponse.llmResponse(from: partialResponse, availableTools: config.availableTools)
            .appending(toolCalls: accumulator.finalize())
        logLLMResponsePayloadIfDebug(response)
        return response
    }
    
    /// Stream responses from the LLM with multiple messages.
    ///
    /// Contract: yields zero or more `.stream(LLMResponse)` chunks followed by
    /// **exactly one** `.complete(LLMResponse)` on success, then
    /// `continuation.finish()`. Cancellation finishes the stream with
    /// `CancellationError`; unknown transport failures are wrapped as
    /// `LLMError.networkError(_:)` via ``StreamCompletionEmitter``.
    nonisolated func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        
        guard getCapabilities().contains(.completion) || getCapabilities().contains(.unknown) else {
            logger?.error("Unsupported LLM capability: \(getCapabilities())")
            return AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> { continuation in
                continuation.finish(throwing: LLMError.unsupportedCapability(.completion))
            }
        }
        
        let model = getModelName()
        logPromptCacheNoOpIfNeeded(config: config)
        return AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> { continuation in
            Task {
                var emitter = NormalizedStreamEmitter(
                    continuation: continuation,
                    supportsEagerToolInputStreaming: self.supportsEagerToolInputStreaming
                )
                
                let requestData = try await createOllamaChatRequest(model: model, messages: messages, config: config)
                self.logRequestPayloadIfDebug(requestData)
                var fullContent: String = ""
                var fullThinking: String = ""
                var accumulator = ToolCallAccumulator()
                var sawDoneChunk = false
                var hasEmittedAnyDelta = false
                
                do {
                    for try await chunk in streamSource.chatStream(
                        baseURL: serverURL,
                        requestData: requestData,
                        timeout: requestTimeoutInterval,
                        logger: logger
                    ) {
                        if Task.isCancelled {
                            emitter.finishCancelled()
                            return
                        }
                        let messageContent = chunk.message?.content
                        let thinkingDelta = chunk.message?.thinking ?? ""
                        let chunkToolCalls: [ToolCall] = (chunk.message?.toolCalls ?? []).compactMap { $0.toolCall() }
                        if !chunkToolCalls.isEmpty {
                            accumulator.ingestFinalList(chunkToolCalls)
                        }
                        
                        fullContent += (messageContent ?? "")
                        
                        if !thinkingDelta.isEmpty {
                            fullThinking += thinkingDelta
                            emitter.yield(
                                .thinkingDelta(thinkingDelta),
                                availableTools: config.availableTools
                            )
                        }
                        
                        if chunk.done == true {
                            sawDoneChunk = true
                            let approxChars = messages.reduce(0) { $0 + $1.content.count }
                            let toolCalls = accumulator.finalize()
                            let terminalDelta = messageContent ?? ""
                            if !hasEmittedAnyDelta, !terminalDelta.isEmpty {
                                emitter.yield(
                                    .textDelta(terminalDelta),
                                    availableTools: config.availableTools
                                )
                            }
                            logger?.info("[OllamaLLM] Done (stream)\(LLMRequestPurposeReader.logSuffix(from: config)) - doneReason: \(chunk.doneReason ?? "nil"), toolCalls: \(toolCalls.count), contentLength: \(fullContent.count), thinkingLength: \(fullThinking.count)")
                            logger?.debug("[OllamaLLM] usage: prompt_eval_count=\(chunk.promptEvalCount.map(String.init) ?? "nil") eval_count=\(chunk.evalCount.map(String.init) ?? "nil") messagesInRequest=\(messages.count) approxCharsInMessages=\(approxChars)")
                            let numCtx = requestData.options?.numCtx ?? config.maxTokens ?? DEFAUT_MAX_TOKENS
                            let metadata = ollamaMetadata(from: chunk, numCtx: numCtx)
                            emitter.yield(
                                .usage(NormalizedUsage(
                                    inputTokens: chunk.promptEvalCount,
                                    outputTokens: chunk.evalCount
                                )),
                                availableTools: config.availableTools
                            )
                            if let failure = DegenerateResponseGuard.failure(
                                provider: "Ollama",
                                text: fullContent,
                                toolCalls: toolCalls,
                                sawReasoning: !fullThinking.isEmpty,
                                providerReportedStop: chunk.doneReason?.isEmpty == false
                            ) {
                                logger?.error("\(failure.detail)")
                                emitter.finishFailed(with: failure)
                                return
                            }
                            let stopReason: NormalizedStopReason = toolCalls.isEmpty ? .end : .toolUse
                            emitter.yield(.stop(stopReason), availableTools: config.availableTools)
                            let finalResponse = LLMResponse.llmResponse(from: fullContent, availableTools: config.availableTools)
                                .appending(toolCalls: toolCalls)
                                .updatingMetadata(with: metadata)
                            self.logLLMResponsePayloadIfDebug(finalResponse)
                            emitter.finishSuccess(
                                content: fullContent,
                                toolCalls: toolCalls,
                                availableTools: config.availableTools,
                                metadata: metadata
                            )
                            return
                        } else {
                            let delta = messageContent ?? ""
                            // `/api/chat` often sends chunks with empty content (keepalives / framing); skip streaming those.
                            guard !delta.isEmpty else { continue }
                            hasEmittedAnyDelta = true
                            emitter.yield(
                                .textDelta(delta),
                                availableTools: config.availableTools
                            )
                        }
                    }
                } catch is CancellationError {
                    emitter.finishCancelled()
                    return
                } catch {
                    logger?.error("\(error)")
                    emitter.finishFailed(with: error)
                    return
                }
                
                let trailingToolCalls = accumulator.finalize()
                if !sawDoneChunk, !fullContent.isEmpty || !trailingToolCalls.isEmpty || !fullThinking.isEmpty {
                    // Stream ended without a `done` chunk (server disconnected). Surface the
                    // partial content as the terminal `.complete` without sentinel-text
                    // injection — the contract forbids synthesised content tokens. Tool calls and
                    // reasoning count as content here; checking text alone dropped a tool-only turn.
                    let finalResponse = LLMResponse.llmResponse(from: fullContent, availableTools: config.availableTools)
                        .appending(toolCalls: trailingToolCalls)
                    self.logLLMResponsePayloadIfDebug(finalResponse)
                    emitter.finishSuccess(with: finalResponse)
                    return
                }
                
                // Finishing silently here would end the turn with neither a `.complete` nor an
                // error — the DEF-135 shape one level up from an empty success.
                let failure = DegenerateStreamError(
                    kind: hasEmittedAnyDelta ? .noOutcome : .noEvents,
                    provider: "Ollama",
                    detail: "Ollama stream ended with no content, tool calls, or done chunk"
                )
                logger?.error("\(failure.detail)")
                emitter.finishFailed(with: failure)
            }
        }
    }
    
    // MARK: - Private
    
    /// Ollama: `contextWindowTokens` = `num_ctx`; remaining is ``LLMMetadata/remainingContextTokens`` (`num_ctx − prompt_eval_count`).
    nonisolated private func ollamaMetadata(from chunk: OllamaChatStreamChunk, numCtx: Int) -> LLMMetadata {
        let totalTokens: Int?
        switch (chunk.promptEvalCount, chunk.evalCount) {
        case let (p?, c?):
            totalTokens = p + c
        case let (p?, nil):
            totalTokens = p
        case let (nil, c?):
            totalTokens = c
        default:
            totalTokens = nil
        }
        let canonicalFinishReason = FinishReason.fromOllama(chunk.doneReason)
        return LLMTokenMetadataBuilder.build(
            inputTokens: chunk.promptEvalCount,
            outputTokens: chunk.evalCount,
            remainingContextTokens: nil,
            totalTokens: totalTokens,
            contextWindowTokens: numCtx,
            finishReason: canonicalFinishReason == .unknown ? chunk.doneReason : canonicalFinishReason.rawValue
        )
    }
    
    private func createOllamaChatRequest(model: String, messages: [Message], config: LLMRequestConfig) async throws -> OKChatRequestData {
        let attachmentDispositions = extractAttachmentDispositions(from: config.additionalParameters)
        let promptMetadata = SystemPromptDispatchCodec.extractPromptMetadata(from: config.additionalParameters)
        let providerStablePrefix = SystemPromptDispatchCodec.extractProviderStablePrefix(from: config.additionalParameters)
        let plan = try await SystemPromptDispatchCodec.resolve(
            messages: messages,
            systemPrompt: systemPrompt,
            promptMetadata: promptMetadata,
            providerStablePrefix: providerStablePrefix
        )
        var ollamaMessages: [OKChatRequestData.Message] = []
        for message in plan.resolvedMessages {
            switch message.role {
            case .system:
                ollamaMessages.append(.init(role: message.role.toOllamaKitRole(), content: message.content))
            default:
                let projectedImages = message.images.filter { image in
                    guard let disposition = attachmentDispositions[image.name] else { return true }
                    return disposition == ConversationAttachmentProjectionDisposition.inline.rawValue
                }
                ollamaMessages.append(.init(
                    role: message.role.toOllamaKitRole(),
                    content: message.content,
                    images: projectedImages.compactMap { $0.base64EncodedImage }
                ))
            }
        }
        
        let tools: [JSON]? = (getCapabilities().contains(.tools) || getCapabilities().contains(.unknown))
            ? config.availableTools.map { tool in
                tool.toOllamaJSON(parameterSchema: config.toolParameterSchemasByName[tool.name])
            }
            : nil
        // OllamaKit has no wire `tool_choice`; resolve only to clamp + warn-log when forcing is requested but unsupported.
        _ = ToolChoiceTranslation.effectivePolicy(
            config: config,
            features: requestFeatures,
            hasTools: !(tools?.isEmpty ?? true),
            model: model,
            logger: logger
        )
        logger?.info("Sending OllamaKit chat request\(LLMRequestPurposeReader.logSuffix(from: config)) - Model: \(model), Tools: \( tools?.count ?? 0)")
        let thinkingEnabled = extractThinkingEnabled(from: config.additionalParameters)
        let responseFormat = extractResponseFormat(from: config.additionalParameters)
        
        let caps = getCapabilities()
        let think: Bool? = {
            if caps.contains(.thinking) { return thinkingEnabled }
            if caps.contains(.reasoningRequired) { return true }
            return nil
        }()
        let format: JSON? = {
            switch responseFormat {
            case "json_object":
                return .string("json")
            default:
                return nil
            }
        }()
        var ollamaRequestData = OKChatRequestData(model: model, messages: ollamaMessages, tools: tools, think: think, format: format)
        ollamaRequestData.options = OKCompletionOptions(numCtx: config.maxTokens ?? DEFAUT_MAX_TOKENS)
        return ollamaRequestData
    }
    
    nonisolated private func extractSystemPromptMetadata(from additionalParameters: JSON?) -> [String: String] {
        guard let additionalParameters,
              case .object(let root) = additionalParameters,
              let metadataJSON = root["contextEngineSystemPromptMetadata"] ?? root["systemPromptMetadata"],
              case .object(let metadataObject) = metadataJSON else {
            return [:]
        }
        
        var metadata: [String: String] = [:]
        for (key, value) in metadataObject {
            switch value {
            case .string(let stringValue):
                metadata[key] = stringValue
            case .integer(let integerValue):
                metadata[key] = String(integerValue)
            case .double(let doubleValue):
                metadata[key] = String(doubleValue)
            case .boolean(let booleanValue):
                metadata[key] = String(booleanValue)
            case .array, .object:
                continue
            }
        }
        
        return metadata
    }

    nonisolated private func extractThinkingEnabled(from additionalParameters: JSON?) -> Bool? {
        guard let additionalParameters,
              case .object(let root) = additionalParameters else {
            return nil
        }
        guard let thinkingJSON = root["thinkingConfig"] else {
            return nil
        }
        switch parseThinkingConfig(thinkingJSON) {
        case .disabled, .level(.off, _):
            return false
        case .adaptive,
                .level(.minimal, _),
                .level(.low, _),
                .level(.medium, _),
                .level(.high, _),
                .level(.xhigh, _):
            return true
        }
    }

    nonisolated private func parseThinkingConfig(_ raw: JSON) -> ThinkingConfig {
        switch raw {
        case .string(let value):
            switch value {
            case "adaptive":
                return .adaptive
            case "disabled":
                return .disabled
            default:
                return .disabled
            }
        case .object(let object):
            guard case .string(let levelRaw)? = object["level"],
                  let level = ThinkingLevel(rawValue: levelRaw) else {
                return .disabled
            }
            let budgetTokens: Int?
            if case .integer(let value)? = object["budgetTokens"] {
                budgetTokens = value
            } else {
                budgetTokens = nil
            }
            return .level(level, budgetTokens: budgetTokens)
        default:
            return .disabled
        }
    }

    nonisolated private func extractResponseFormat(from additionalParameters: JSON?) -> String? {
        guard let additionalParameters,
              case .object(let root) = additionalParameters,
              let responseFormatJSON = root["responseFormat"],
              case .string(let value) = responseFormatJSON else {
            return nil
        }
        return value
    }

    nonisolated private func extractAttachmentDispositions(from additionalParameters: JSON?) -> [String: String] {
        AttachmentProjectionDispatchCodec.extractDispositions(from: additionalParameters)
    }

    nonisolated static func testEncodedChatRequestBody(_ requestData: OKChatRequestData) throws -> Data {
        try OllamaChatStreamSupport.encodedChatRequestBody(requestData)
    }

    nonisolated static func testMakeChatRequest(
        baseURL: URL,
        requestData: OKChatRequestData,
        timeout: TimeInterval?
    ) throws -> URLRequest {
        try OllamaChatStreamSupport.makeChatRequest(baseURL: baseURL, requestData: requestData, timeout: timeout)
    }

    nonisolated private func logPromptCacheNoOpIfNeeded(config: LLMRequestConfig) {
        guard let additional = config.additionalParameters,
              case .object(let root) = additional,
              case .string(let mode)? = root[PromptCacheKnobKey.mode],
              mode != "none" else {
            return
        }
        logger?.debug("Prompt-cache plan is a no-op for Ollama adapter")
    }

    nonisolated private func logRequestPayloadIfDebug(_ requestData: OKChatRequestData) {
        guard logger?.logLevel ?? .info <= .debug, DebugPayloadLogging.isEnabled() else { return }
        guard let data = try? OllamaChatStreamSupport.encodedChatRequestBody(requestData),
              let text = String(data: data, encoding: .utf8) else {
            logger?.debug("[OllamaLLM] Failed to encode request payload for debug logging")
            return
        }
        logger?.debug("[OllamaLLM] Request payload: \(text)")
    }

    nonisolated private func logLLMResponsePayloadIfDebug(_ response: LLMResponse) {
        guard logger?.logLevel ?? .info <= .debug, DebugPayloadLogging.isEnabled() else { return }
        let toolCalls = response.toolCalls.map { toolCall in
            let args: String
            if let data = try? JSONEncoder().encode(toolCall.arguments),
               let json = String(data: data, encoding: .utf8) {
                args = json
            } else {
                args = String(describing: toolCall.arguments)
            }
            return "{id:\(toolCall.id ?? "nil"),name:\(toolCall.name),arguments:\(args)}"
        }.joined(separator: ",")
        logger?.debug(
            "[OllamaLLM] Response payload: content=\(response.content) toolCalls=[\(toolCalls)] metadata=\(String(describing: response.metadata))"
        )
    }
}

extension OKChatResponse.Message.ToolCall {
    func toolCall() -> ToolCall? {
        guard let name = function?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        return ToolCall(name: name, arguments: function?.arguments ?? .object([:]))
    }
}

// MARK: - Lenient Ollama /api/chat stream (OllamaKit strict decode fails on chunks without `model`)

/// Mirrors Ollama's streaming NDJSON objects; fields are optional so keepalives / partial objects do not abort the stream.
/// OllamaKit decodes every line as ``OKChatResponse``, which requires `model` and terminates the stream on decode failure.
struct OllamaChatStreamChunk: Decodable, Sendable {
    var model: String?
    var createdAt: Date?
    var message: OKChatResponse.Message?
    var done: Bool?
    var doneReason: String?
    var totalDuration: Int?
    var loadDuration: Int?
    var promptEvalCount: Int?
    var promptEvalDuration: Int?
    var evalCount: Int?
    var evalDuration: Int?
}

/// Test seam for ``OllamaLLM`` — the adapter routes its NDJSON stream through this
/// protocol so contract tests can inject scripted chunk sequences without standing
/// up a real `URLSession` transport.
///
/// Default conformance is ``DefaultOllamaChatStreamSource``, which delegates to
/// ``OllamaChatStreamSupport/lenientStream(baseURL:requestData:timeout:logger:)``.
protocol OllamaChatStreamSourcing: Sendable {
    func chatStream(
        baseURL: URL,
        requestData: OKChatRequestData,
        timeout: TimeInterval?,
        logger: Logger?
    ) -> AsyncThrowingStream<OllamaChatStreamChunk, Error>
}

struct DefaultOllamaChatStreamSource: OllamaChatStreamSourcing {
    func chatStream(
        baseURL: URL,
        requestData: OKChatRequestData,
        timeout: TimeInterval?,
        logger: Logger?
    ) -> AsyncThrowingStream<OllamaChatStreamChunk, Error> {
        OllamaChatStreamSupport.lenientStream(
            baseURL: baseURL,
            requestData: requestData,
            timeout: timeout,
            logger: logger
        )
    }
}

enum OllamaChatStreamSupport {
    /// "Never timeout" is represented as a very large finite duration because Foundation APIs require finite intervals.
    private static let effectivelyNoTimeoutInterval: TimeInterval = 60 * 60 * 24 * 365 * 10

    /// Matches ``JSONDecoder`` settings in OllamaKit (`convertFromSnakeCase` + ISO8601 dates).
    static func jsonDecoderForChunks() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateString) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: dateString) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date string \(dateString)")
        }
        return decoder
    }

    static func makeChatRequest(baseURL: URL, requestData: OKChatRequestData, timeout: TimeInterval?) throws -> URLRequest {
        let url = baseURL.appendingPathComponent("api").appendingPathComponent("chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encodedChatRequestBody(requestData)
        if let timeout, timeout > 0 {
            request.timeoutInterval = timeout
        } else {
            request.timeoutInterval = effectivelyNoTimeoutInterval
        }
        // Chat turns are never idempotent; a URL-cache replay would serve a stale or
        // truncated body. Response caching is a Model Pool decision, not a transport default.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    /// OllamaKit 1.0.6 exposes `think` on `OKChatRequestData` but does not encode it.
    /// Inject it explicitly so outbound `/api/chat` always carries the effective value.
    static func encodedChatRequestBody(_ requestData: OKChatRequestData) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let encoded = try encoder.encode(requestData)
        guard let think = requestData.think else {
            return encoded
        }
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            return encoded
        }
        object["think"] = think
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }

    static func validateHTTPResponse(_ response: URLResponse) throws {
        try OllamaHTTPStatusMapping.validate(response)
    }

    /// Same brace-matching strategy as OllamaKit `OKHTTPClient.extractNextJSON`.
    static func extractNextJSONObject(from buffer: inout Data) -> Data? {
        var isEscaped = false
        var isWithinString = false
        var nestingDepth = 0
        var objectStartIndex = buffer.startIndex
        for (index, byte) in buffer.enumerated() {
            let character = Character(UnicodeScalar(byte))
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                isWithinString.toggle()
            } else if !isWithinString {
                switch character {
                case "{":
                    nestingDepth += 1
                    if nestingDepth == 1 {
                        objectStartIndex = index
                    }
                case "}":
                    nestingDepth -= 1
                    if nestingDepth == 0 {
                        let range = objectStartIndex..<buffer.index(after: index)
                        let jsonObject = buffer.subdata(in: range)
                        buffer.removeSubrange(range)
                        return jsonObject
                    }
                default:
                    break
                }
            }
        }
        return nil
    }

    static func lenientStream(
        baseURL: URL,
        requestData: OKChatRequestData,
        timeout: TimeInterval?,
        logger: Logger?
    ) -> AsyncThrowingStream<OllamaChatStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let request = try makeChatRequest(baseURL: baseURL, requestData: requestData, timeout: timeout)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try validateHTTPResponse(response)
                    let decoder = jsonDecoderForChunks()
                    var buffer = Data()
                    for try await byte in bytes {
                        buffer.append(byte)
                        while let chunkData = extractNextJSONObject(from: &buffer) {
                            do {
                                let chunk = try decoder.decode(OllamaChatStreamChunk.self, from: chunkData)
                                continuation.yield(chunk)
                            } catch {
                                let byteCount = chunkData.count
                                logger?.warning(
                                    "Ollama chat stream: skipped JSON object that failed lenient decode",
                                    metadata: [
                                        "error": .string(String(describing: error)),
                                        "byteCount": .stringConvertible(byteCount)
                                    ]
                                )
                                let payloadForDebug: String = {
                                    if let s = String(data: chunkData, encoding: .utf8) {
                                        return s
                                    }
                                    return "non-utf8 (\(byteCount) bytes, base64): \(chunkData.base64EncodedString())"
                                }()
                                logger?.debug(
                                    "Ollama chat stream: full malformed JSON object (lenient decode failed)",
                                    metadata: [
                                        "error": .string(String(describing: error)),
                                        "byteCount": .stringConvertible(byteCount),
                                        "payload": .string(payloadForDebug)
                                    ]
                                )
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

/**
 This is the format Ollama expects for tool calls"
 {
     'type': 'function',
     'function': {
         'name': '<name>',
         'description': '<description>',
         'parameters': {
             'type': 'object',
             'properties': {
                 '<property_name>': {
                     'type': 'string',
                     'description': '<property_decription>',
                 },
             },
             'required': ['<property_name>'],
         },
     },
 }
 */
extension ToolDefinition {
    
    func toOllamaJSON(parameterSchema: JSON? = nil) -> JSON {
        let parametersValue: JSON
        if let parameterSchema {
            parametersValue = parameterSchema
        } else {
            let requiredValue: [JSON] = parameters.compactMap {
                if $0.required {
                    return JSON.string($0.name)
                } else {
                    return nil
                }
            }
            var temp: [String: JSON] = [:]
            for param in parameters {
                let tempValue: JSON = .object([
                    "type": JSON.string(param.type),
                    "description": JSON.string(param.description),
                ])
                temp[param.name] = tempValue
            }
            let propValue: JSON = .object(temp)
            parametersValue = .object([
                "type": JSON.string("object"),
                "properties": propValue,
                "required": JSON.array(requiredValue)
            ])
        }
        let functionValue: JSON = .object([
            "name": JSON.string(name),
            "description": JSON.string(description),
            "parameters": parametersValue
        ])
        return .object(["type": JSON.string("function"), "function": functionValue])
    }
}

/// Maps the HTTP status from an Ollama call to a typed ``LLMError`` so
/// ``TransientErrorClassifier`` (and other downstream consumers) can decide whether
/// the failure is retryable.
///
/// - 408 / 504 → ``LLMError/timeout`` (transient)
/// - 429 → ``LLMError/rateLimitExceeded`` (transient)
/// - 401 / 403 → ``LLMError/authenticationFailed`` (terminal)
/// - 404 → ``LLMError/modelNotFound(_:)`` (terminal)
/// - 5xx → ``LLMError/networkError(_:)`` wrapping `URLError(.badServerResponse)` (transient
///   via classifier recursion through `URLError` families)
/// - other 4xx → ``LLMError/invalidRequest(_:)`` (terminal)
/// - non-`HTTPURLResponse` → ``LLMError/invalidResponse(_:)`` (terminal)
enum OllamaHTTPStatusMapping {
    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse("Non-HTTP response from Ollama")
        }
        let status = http.statusCode
        switch status {
        case 200...299:
            return
        case 408, 504:
            throw LLMError.timeout
        case 429:
            let retryAfter = retryAfterSeconds(from: http)
            throw RetryAfterRateLimitError(retryAfterSeconds: retryAfter, underlying: LLMError.rateLimitExceeded)
        case 401, 403:
            throw LLMError.authenticationFailed
        case 404:
            throw LLMError.modelNotFound("Ollama HTTP 404")
        case 500...599:
            throw LLMError.networkError(URLError(.badServerResponse))
        default:
            throw LLMError.invalidRequest("Ollama HTTP \(status)")
        }
    }

    private static func retryAfterSeconds(from response: HTTPURLResponse) -> Double? {
        guard let headerValue = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !headerValue.isEmpty else {
            return nil
        }
        if let seconds = Double(headerValue) {
            return max(0, seconds)
        }
        let formatters: [DateFormatter] = {
            let rfc1123 = DateFormatter()
            rfc1123.locale = Locale(identifier: "en_US_POSIX")
            rfc1123.timeZone = TimeZone(secondsFromGMT: 0)
            rfc1123.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"

            let rfc850 = DateFormatter()
            rfc850.locale = Locale(identifier: "en_US_POSIX")
            rfc850.timeZone = TimeZone(secondsFromGMT: 0)
            rfc850.dateFormat = "EEEE',' dd-MMM-yy HH':'mm':'ss z"

            let asctime = DateFormatter()
            asctime.locale = Locale(identifier: "en_US_POSIX")
            asctime.timeZone = TimeZone(secondsFromGMT: 0)
            asctime.dateFormat = "EEE MMM d HH':'mm':'ss yyyy"
            return [rfc1123, rfc850, asctime]
        }()
        for formatter in formatters {
            if let target = formatter.date(from: headerValue) {
                return max(0, target.timeIntervalSinceNow)
            }
        }
        return nil
    }
}
