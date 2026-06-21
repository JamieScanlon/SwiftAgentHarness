//
//  Conforms to the ``AdapterContract``: replaces three legacy
//  `NSError(domain: "LMStudioLLM", …)` failure sites with typed `LLMError` via
//  ``LMStudioErrorMapping``; accumulates SSE tool-call deltas through
//  ``ToolCallAccumulator``; emits exactly one `.complete` then `finish()` via
//  ``StreamCompletionEmitter`` on success; throws `CancellationError` on
//  consumer cancellation. The streaming SSE source is injected via
//  ``LMStudioStreamSourcing`` so contract tests can run without the network.
//

import EasyJSON
import Foundation
import Logging
import SwiftAgentKit

actor LMStudioLLM: LLMProtocol, AdapterAuthProbing {
    
    let model: String
    let serverURL: URL
    let capabilities: [LLMCapability]
    let requestFeatures: ModelRequestFeatures
    let DEFAULT_MAX_TOKENS: Int = 131072
    /// "Never timeout" represented as a very large finite interval.
    let EFFECTIVELY_NO_TIMEOUT_INTERVAL: TimeInterval = 60 * 60 * 24 * 365 * 10
    
    private let systemPrompt: SystemPrompt
    private let logger: Logger?
    private let streamSource: any LMStudioStreamSourcing
    
    init(
        model: String,
        serverURL: URL,
        capabilities: [LLMCapability] = [.unknown],
        requestFeatures: ModelRequestFeatures = .unknown,
        systemPrompt: SystemPrompt,
        logger: Logger? = nil,
        streamSource: any LMStudioStreamSourcing = DefaultLMStudioStreamSource()
    ) {
        self.model = model
        self.serverURL = serverURL
        self.capabilities = capabilities
        self.requestFeatures = requestFeatures
        self.systemPrompt = systemPrompt
        self.logger = logger
        self.streamSource = streamSource
        logger?.info("Initialized LMStudioLLM - Model: \(model), ServerURL: \(serverURL.absoluteString), Capabilities: \(capabilities.map { $0.rawValue })")
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
    /// Cancellation is surfaced as `CancellationError`; provider failures are
    /// mapped to typed ``LLMError`` (request encoding via
    /// ``LMStudioErrorMapping/requestEncodingFailure(_:)``; transport failures
    /// via ``LLMError/networkError(_:)`` so `TransientErrorClassifier` can
    /// recurse).
    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        
        logger?.info("Starting non-streaming chat request\(LLMRequestPurposeReader.logSuffix(from: config)) - Model: \(model), Message count: \(messages.count)")
        
        guard getCapabilities().contains(.completion) || getCapabilities().contains(.unknown) else {
            logger?.error("Unsupported LLM capability: \(getCapabilities())")
            throw LLMError.unsupportedCapability(.completion)
        }
        
        let requestBody = await createLMStudioChatRequest(messages: messages, config: config, stream: false)
        
        logger?.debug("Preparing HTTP request - URL: \(serverURL.absoluteString)/api/v0/chat/completions, Model: \(model), MaxTokens: \(requestBody.maxTokens)")
        
        let apiManager = RestAPIManager(
            baseURL: serverURL,
            sseTimeoutInterval: EFFECTIVELY_NO_TIMEOUT_INTERVAL,
            logger: logger
        )
        
        do {
            let requestDict: [String: Any]
            do {
                var mutable = try requestBodyToDictionary(requestBody)
                applyRequestKnobs(to: &mutable, config: config)
                requestDict = mutable
            } catch {
                throw LMStudioErrorMapping.requestEncodingFailure(error)
            }
            logger?.debug("Request body converted to dictionary")
            logRequestPayloadIfDebug(requestDict)
            
            let lmStudioResponse: LMStudioChatResponse = try await apiManager.decodableRequest(
                "api/v0/chat/completions",
                method: .post,
                parameters: requestDict
            )
            
            logger?.debug("Successfully decoded response - Choices: \(lmStudioResponse.choices.count), Usage: \(lmStudioResponse.usage?.totalTokens ?? 0) tokens")
            
            let processed = processLMStudioResponse(lmStudioResponse, availableTools: config.availableTools, config: config)
            logLLMResponsePayloadIfDebug(processed)
            return processed
        } catch let error as LLMError {
            logger?.error("LM Studio API request failed: \(error.localizedDescription)")
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Wrap unknown upstream-client errors so ``TransientErrorClassifier`` can recurse.
            // Per-HTTP-status precision is blocked on `RestAPIManager` exposing status codes.
            logger?.error("LM Studio API request failed: \(error.localizedDescription)")
            throw LLMError.networkError(error)
        }
    }
    
    /// Stream responses from the LLM with multiple messages.
    ///
    /// Contract: yields zero or more `.stream(LLMResponse)` chunks followed by
    /// **exactly one** `.complete(LLMResponse)` on success, then
    /// `continuation.finish()` (via ``StreamCompletionEmitter``). Cancellation
    /// finishes the stream with `CancellationError` and emits no `.complete`.
    /// SSE / payload errors map to ``LLMError`` via ``LMStudioErrorMapping``.
    nonisolated func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        
        guard getCapabilities().contains(.completion) || getCapabilities().contains(.unknown) else {
            logger?.error("Unsupported LLM capability: \(getCapabilities())")
            return AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> { continuation in
                continuation.finish(throwing: LLMError.unsupportedCapability(.completion))
            }
        }
        
        return AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> { continuation in
            let emitter = StreamCompletionEmitter(continuation: continuation)
            
            Task {
                self.logger?.info("Starting streaming chat request\(LLMRequestPurposeReader.logSuffix(from: config)) - Model: \(self.model), Message count: \(messages.count)")
                
                let requestBody = await self.createLMStudioChatRequest(messages: messages, config: config, stream: true)
                
                self.logger?.debug("Preparing streaming HTTP request - URL: \(self.serverURL.absoluteString)/api/v0/chat/completions, Model: \(self.model)")
                
                // Convert request body to dictionary for the SSE source. The encoding
                // error is the only `throws` site in the streaming path; we map it locally
                // through ``LMStudioErrorMapping`` and finish via the emitter so the
                // contract's `LLMError`-only error surface is preserved. The downstream
                // SSE source is non-throwing (`AsyncStream`).
                var requestDictAny: [String: Any]
                do {
                    requestDictAny = try self.requestBodyToDictionary(requestBody)
                    self.applyRequestKnobs(to: &requestDictAny, config: config)
                    requestDictAny["stream_options"] = ["include_usage": true]
                    self.logger?.debug("Streaming request body converted to dictionary")
                    self.logRequestPayloadIfDebug(requestDictAny)
                } catch {
                    self.logger?.error("Failed to convert streaming request body: \(error.localizedDescription)")
                    emitter.finishFailed(with: LMStudioErrorMapping.requestEncodingFailure(error))
                    return
                }
                
                let requestDict = self.convertToSendableDictionary(requestDictAny)
                
                let stream = await self.streamSource.sseStream(
                    baseURL: self.serverURL,
                    endpoint: "api/v0/chat/completions",
                    parameters: requestDict,
                    sseTimeoutInterval: self.EFFECTIVELY_NO_TIMEOUT_INTERVAL,
                    logger: self.logger
                )
                
                self.logger?.debug("Streaming connection established, starting to process SSE messages")
                
                var fullContent = ""
                var accumulator = ToolCallAccumulator()
                var chunkCount = 0
                var validChunksReceived = 0
                var streamUsage: LMStudioUsage?
                var lastFinishReason: String?
                
                for await jsonDict in stream {
                    if Task.isCancelled {
                        self.logger?.warning("Streaming task was cancelled")
                        emitter.finishCancelled()
                        return
                    }
                    
                    chunkCount += 1
                    
                    if let u = Self.usageFromSSEPayload(jsonDict) {
                        streamUsage = u
                    }
                    
                    self.logger?.debug("Received SSE chunk \(chunkCount) - Keys: \(jsonDict.keys.joined(separator: ", "))")
                    if let jsonData = try? JSONSerialization.data(withJSONObject: jsonDict as Any),
                       let jsonString = String(data: jsonData, encoding: .utf8) {
                        self.logger?.debug("SSE chunk \(chunkCount) content: \(jsonString.prefix(500))")
                    }
                    
                    // Check for SSE error events (event: error)
                    if let sseEvent = jsonDict["_sse_event"] as? String, sseEvent == "error" {
                        let errorMessage: String
                        if let errorValue = jsonDict["error"],
                           let errorDict = errorValue as? [String: any Sendable],
                           let message = errorDict["message"] as? String {
                            errorMessage = message
                        } else if let message = jsonDict["message"] as? String {
                            errorMessage = message
                        } else {
                            errorMessage = "Unknown error from LM Studio"
                        }
                        self.logger?.error("SSE error event received in chunk \(chunkCount) - Message: \(errorMessage)")
                        emitter.finishFailed(with: LMStudioErrorMapping.sseErrorEvent(message: errorMessage))
                        return
                    }
                    
                    // Check for error responses in data payload
                    if let errorValue = jsonDict["error"],
                       let errorDict = errorValue as? [String: any Sendable] {
                        let errorMessage = (errorDict["message"] as? String) ?? "Unknown error"
                        let errorType = (errorDict["type"] as? String) ?? "Unknown"
                        self.logger?.error("SSE chunk \(chunkCount) contains error - Type: \(errorType), Message: \(errorMessage)")
                        emitter.finishFailed(with: LMStudioErrorMapping.sseErrorEvent(message: errorMessage))
                        return
                    }
                    
                    // Extract choices array
                    guard let choicesValue = jsonDict["choices"] else {
                        self.logger?.debug("No choices found in SSE chunk \(chunkCount) - Available keys: \(jsonDict.keys.joined(separator: ", "))")
                        continue
                    }
                    
                    guard let choicesArray = choicesValue as? [[String: any Sendable]] else {
                        self.logger?.debug("Choices value is not an array in SSE chunk \(chunkCount) - Type: \(type(of: choicesValue))")
                        continue
                    }
                    
                    guard let firstChoice = choicesArray.first else {
                        self.logger?.debug("Choices array is empty in SSE chunk \(chunkCount)")
                        continue
                    }
                    
                    validChunksReceived += 1
                    
                    // Extract delta content
                    if let deltaValue = firstChoice["delta"],
                       let delta = deltaValue as? [String: any Sendable],
                       let contentValue = delta["content"],
                       let content = contentValue as? String {
                        
                        self.logger?.debug("Received delta content: '\(content)' (length: \(content.count))")
                        
                        fullContent += content
                        
                        let chunkResponse = NormalizedEventMapper.streamChunk(
                            for: .contentDelta(content),
                            availableTools: config.availableTools
                        )

                        self.logger?.debug("Yielding stream chunk with content length: \(chunkResponse.content.count), fullContent length: \(fullContent.count)")

                        emitter.yieldStream(chunkResponse)
                    }
                    
                    // Handle tool-call deltas via the contract accumulator (index-keyed,
                    // mirroring the OpenAI streaming shape).
                    if let deltaValue = firstChoice["delta"],
                       let delta = deltaValue as? [String: any Sendable],
                       let toolCallsValue = delta["tool_calls"],
                       let deltaToolCalls = toolCallsValue as? [[String: any Sendable]] {
                        
                        self.logger?.debug("Received tool call delta - Count: \(deltaToolCalls.count)")
                        
                        for toolCallDict in deltaToolCalls {
                            let indexValue = toolCallDict["index"]
                            let index = (indexValue as? Int) ?? (indexValue as? NSNumber)?.intValue ?? 0
                            
                            let idDelta = toolCallDict["id"] as? String
                            
                            var nameDelta: String?
                            var argsDelta: String?
                            if let functionValue = toolCallDict["function"],
                               let function = functionValue as? [String: any Sendable] {
                                nameDelta = function["name"] as? String
                                argsDelta = function["arguments"] as? String
                            }
                            if nameDelta != nil || !(argsDelta ?? "").isEmpty {
                                emitter.yieldStream(
                                    NormalizedEventMapper.streamChunk(
                                        for: .toolCallDelta(
                                            id: idDelta,
                                            name: nameDelta,
                                            argumentsFragment: argsDelta ?? ""
                                        ),
                                        availableTools: config.availableTools
                                    )
                                )
                            }
                            
                            accumulator.ingestIndexed(
                                index: index,
                                idDelta: idDelta,
                                nameDelta: nameDelta,
                                argumentsDelta: argsDelta
                            )
                        }
                    }
                    
                    // Final chunk?
                    if let finishReasonValue = firstChoice["finish_reason"],
                       let finishReason = finishReasonValue as? String {
                        lastFinishReason = finishReason
                        self.logger?.info("Received finish reason: \(finishReason) - Processing final response")
                        
                        let canonicalFinishReason = FinishReason.fromLMStudio(finishReason)
                        let storedFinishReason = canonicalFinishReason == .unknown ? finishReason : canonicalFinishReason.rawValue
                        let metadata = Self.lmStudioOpenAIMetadata(usage: streamUsage, config: config, finishReason: storedFinishReason)
                        let finalResponse = LLMResponse.llmResponse(from: fullContent, availableTools: config.availableTools)
                            .appending(toolCalls: accumulator.finalize())
                            .updatingMetadata(with: metadata)
                        self.logLLMResponsePayloadIfDebug(finalResponse)
                        emitter.finishSuccess(with: finalResponse)
                        return
                    }
                }
                
                self.logger?.info("Stream ended - Total chunks processed: \(chunkCount), Valid chunks: \(validChunksReceived), Content length: \(fullContent.count)")
                
                // No-valid-choices guards: ended without ever observing a usable choice.
                if validChunksReceived == 0 && chunkCount > 0 {
                    self.logger?.error("Stream ended after receiving \(chunkCount) chunks, but none contained valid choices")
                    emitter.finishFailed(with: LMStudioErrorMapping.noValidChoices(chunkCount: chunkCount))
                    return
                }
                
                if chunkCount == 0 {
                    self.logger?.error("Stream ended without receiving any chunks")
                    emitter.finishFailed(with: LMStudioErrorMapping.noValidChoices(chunkCount: 0))
                    return
                }
                
                // Stream ended cleanly without an explicit `finish_reason` chunk but with
                // accumulated content; surface that as the terminal `.complete`.
                if !fullContent.isEmpty {
                    let canonicalFinishReason = FinishReason.fromLMStudio(lastFinishReason)
                    let storedFinishReason: String? = {
                        guard let raw = lastFinishReason else { return nil }
                        return canonicalFinishReason == .unknown ? raw : canonicalFinishReason.rawValue
                    }()
                    let metadata = Self.lmStudioOpenAIMetadata(usage: streamUsage, config: config, finishReason: storedFinishReason)
                    let finalResponse = LLMResponse.llmResponse(from: fullContent, availableTools: config.availableTools)
                        .appending(toolCalls: accumulator.finalize())
                        .updatingMetadata(with: metadata)
                    self.logLLMResponsePayloadIfDebug(finalResponse)
                    emitter.finishSuccess(with: finalResponse)
                    return
                }
                
                self.logger?.warning("Stream ended with no content received")
                continuation.finish()
            }
        }
    }
    
    // MARK: - Private
    
    nonisolated private func requestBodyToDictionary(_ requestBody: LMStudioChatRequest) throws -> [String: Any] {
        let encoder = JSONEncoder()
        let data = try encoder.encode(requestBody)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LMStudioErrorMapping.requestEncodingFailure(
                LMStudioInternalError.dictionaryConversionFailed
            )
        }
        return dict
    }
    
    nonisolated private func convertToSendableDictionary(_ dict: [String: Any]) -> [String: any Sendable] {
        var result: [String: any Sendable] = [:]
        for (key, value) in dict {
            if let sendableValue = convertToSendable(value) {
                result[key] = sendableValue
            }
        }
        return result
    }
    
    nonisolated private func convertToSendable(_ value: Any) -> (any Sendable)? {
        switch value {
        case let string as String:
            return string
        case let int as Int:
            return int
        case let double as Double:
            return double
        case let bool as Bool:
            return bool
        case let array as [Any]:
            return array.compactMap { convertToSendable($0) } as [any Sendable]
        case let dict as [String: Any]:
            return convertToSendableDictionary(dict)
        default:
            return nil
        }
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

    nonisolated private func extractAttachmentDispositions(from additionalParameters: JSON?) -> [String: String] {
        guard let additionalParameters,
              case .object(let root) = additionalParameters,
              let projection = root["contextEngineAttachmentProjection"],
              case .object(let projectionObject) = projection,
              let decisionsJSON = projectionObject["decisions"],
              case .array(let decisions) = decisionsJSON else {
            return [:]
        }
        var output: [String: String] = [:]
        for decision in decisions {
            guard case .object(let object) = decision,
                  case .string(let name)? = object["attachmentName"],
                  case .string(let disposition)? = object["disposition"] else {
                continue
            }
            output[name] = disposition
        }
        return output
    }

    nonisolated private func attachmentDispositionSuffix(
        imageNames: [String],
        dispositions: [String: String]
    ) -> String {
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
    
    private func createLMStudioChatRequest(messages: [Message], config: LLMRequestConfig, stream: Bool) async -> LMStudioChatRequest {
        let attachmentDispositions = extractAttachmentDispositions(from: config.additionalParameters)
        
        // Convert messages to LM Studio format
        var lmStudioMessages: [LMStudioMessage] = []
        for message in messages {
            switch message.role {
            case .system:
                let systemPromptText: String
                do {
                    let promptMetadata = extractSystemPromptMetadata(from: config.additionalParameters)
                    systemPromptText = try await systemPrompt.generateSystemPrompt(
                        withUserSystemPrompt: message.content,
                        additionalMetadata: promptMetadata
                    )
                } catch {
                    self.logger?.error("Failed to generate system prompt: \(error)")
                    systemPromptText = ""
                }
                lmStudioMessages.append(LMStudioMessage(role: "system", content: systemPromptText))
            case .user:
                lmStudioMessages.append(LMStudioMessage(
                    role: "user",
                    content: message.content + attachmentDispositionSuffix(
                        imageNames: message.images.map(\.name),
                        dispositions: attachmentDispositions
                    )
                ))
            case .assistant:
                let toolCalls: [LMStudioToolCall]? = message.toolCalls.isEmpty ? nil : message.toolCalls.map { toolCall in
                    self.convertToolCallToLMStudioFormat(toolCall)
                }
                if let toolCalls = toolCalls, !toolCalls.isEmpty {
                    logger?.debug("Assistant message includes \(toolCalls.count) tool call(s)")
                }
                lmStudioMessages.append(LMStudioMessage(
                    role: "assistant",
                    content: message.content + attachmentDispositionSuffix(
                        imageNames: message.images.map(\.name),
                        dispositions: attachmentDispositions
                    ),
                    toolCalls: toolCalls
                ))
            case .tool:
                lmStudioMessages.append(LMStudioMessage(role: "tool", content: message.content, toolCallId: message.toolCallId))
            }
        }
        
        // Convert tools to LM Studio format (OpenAI-compatible)
        let tools: [LMStudioTool]? = (getCapabilities().contains(.tools) || getCapabilities().contains(.unknown)) && !config.availableTools.isEmpty
            ? config.availableTools.map { tool in
                LMStudioTool(
                    type: "function",
                    function: LMStudioFunction(
                        name: tool.name,
                        description: tool.description,
                        parameters: tool.toLMStudioParameters()
                    )
                )
            }
            : nil
        
        logger?.info("Creating LM Studio chat request\(LLMRequestPurposeReader.logSuffix(from: config)) - Model: \(model), Messages: \(lmStudioMessages.count), Tools: \(tools?.count ?? 0), Stream: \(stream), MaxTokens: \(config.maxTokens ?? DEFAULT_MAX_TOKENS)")
        
        let roleCounts = Dictionary(grouping: lmStudioMessages, by: { $0.role })
            .mapValues { $0.count }
        logger?.debug("Message role distribution: \(roleCounts)")
        
        if let tools = tools, !tools.isEmpty {
            logger?.debug("Tool definitions: \(tools.map { $0.function.name }.joined(separator: ", "))")
        }
        
        return LMStudioChatRequest(
            model: model,
            messages: lmStudioMessages,
            temperature: config.temperature,
            maxTokens: config.maxTokens ?? DEFAULT_MAX_TOKENS,
            topP: config.topP,
            stream: stream,
            tools: tools
        )
    }

    nonisolated private func applyRequestKnobs(to body: inout [String: Any], config: LLMRequestConfig) {
        if let responseFormat = extractResponseFormat(from: config.additionalParameters) {
            switch responseFormat {
            case "json_object":
                body["response_format"] = ["type": "json_object"]
            case "text":
                body["response_format"] = ["type": "text"]
            default:
                break
            }
        }
        if let parallelToolCalls = extractParallelToolCalls(from: config.additionalParameters) {
            body["parallel_tool_calls"] = parallelToolCalls
        }
        if let reasoningEffort = extractReasoningEffort(from: config.additionalParameters) {
            body["reasoning_effort"] = reasoningEffort
        }
        if let promptCache = extractPromptCache(from: config.additionalParameters) {
            body["prompt_cache"] = promptCache
        }
        let policy = ToolChoiceTranslation.effectivePolicy(
            config: config,
            features: requestFeatures,
            hasTools: body["tools"] != nil,
            model: model,
            logger: logger
        )
        if let toolChoice = Self.toolChoiceWire(for: policy) {
            body["tool_choice"] = toolChoice
        }
    }

    /// OpenAI-compatible `tool_choice` wire value for an already-clamped policy.
    /// ``ToolInvocationPolicy/automatic`` is the provider default and emits nothing.
    nonisolated static func toolChoiceWire(for policy: ToolInvocationPolicy) -> Any? {
        switch policy {
        case .automatic: return nil
        case .required: return "required"
        case .none: return "none"
        case .specific(let toolName): return ["type": "function", "function": ["name": toolName]]
        }
    }

    nonisolated private func extractResponseFormat(from additionalParameters: JSON?) -> String? {
        guard let additionalParameters,
              case .object(let root) = additionalParameters,
              case .string(let value)? = root["responseFormat"] else {
            return nil
        }
        return value
    }

    nonisolated private func extractParallelToolCalls(from additionalParameters: JSON?) -> Bool? {
        guard let additionalParameters,
              case .object(let root) = additionalParameters else {
            return nil
        }
        if case .boolean(let value)? = root["parallelToolCalls"] {
            return value
        }
        return nil
    }

    nonisolated private func extractReasoningEffort(from additionalParameters: JSON?) -> String? {
        guard let additionalParameters,
              case .object(let root) = additionalParameters,
              let rawThinkingConfig = root["thinkingConfig"] else {
            return nil
        }
        switch parseThinkingConfig(rawThinkingConfig) {
        case .disabled:
            return "none"
        case .adaptive:
            return nil
        case .level(.off, _):
            return "none"
        case .level(.minimal, _):
            return "minimal"
        case .level(.low, _):
            return "low"
        case .level(.medium, _):
            return "medium"
        case .level(.high, _), .level(.xhigh, _):
            return "high"
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

    nonisolated private func extractPromptCache(from additionalParameters: JSON?) -> [String: Any]? {
        let caps = Set(getCapabilities())
        let supportsPromptCache = caps.contains(.promptCacheEphemeral) || caps.contains(.promptCachePersistent) || caps.contains(.unknown)
        guard supportsPromptCache else {
            return nil
        }
        guard let additionalParameters,
              case .object(let root) = additionalParameters else {
            return nil
        }
        guard case .string(let mode)? = root[PromptCacheKnobKey.mode] else {
            return nil
        }
        guard mode == "ephemeral" || mode == "persistent" else {
            return nil
        }
        var payload: [String: Any] = ["mode": mode]
        if case .integer(let stablePrefix)? = root[PromptCacheKnobKey.stablePrefixMessageCount] {
            payload["stable_prefix_messages"] = stablePrefix
        }
        return payload
    }
    
    /// OpenAI-compatible usage and remaining-context estimate (same as ``OpenAILLM``).
    nonisolated private static func lmStudioOpenAIMetadata(
        usage: LMStudioUsage?,
        config: LLMRequestConfig,
        finishReason: String?
    ) -> LLMMetadata {
        let reservedFromRequest = LLMTokenMetadataBuilder.maxCompletionTokens(from: config)
        let reservedOutput = reservedFromRequest ?? usage?.completionTokens
        let remaining = LLMTokenMetadataBuilder.openAIRemainingContext(
            modelContextLimit: config.maxTokens,
            promptTokens: usage?.promptTokens,
            reservedOutputTokens: reservedOutput
        )
        return LLMTokenMetadataBuilder.build(
            inputTokens: usage?.promptTokens,
            outputTokens: usage?.completionTokens,
            remainingContextTokens: remaining,
            totalTokens: usage?.totalTokens,
            contextWindowTokens: config.maxTokens,
            finishReason: finishReason
        )
    }
    
    /// Parses OpenAI-shaped `usage` from an SSE JSON payload when present (e.g. final chunk with `include_usage`).
    nonisolated private static func usageFromSSEPayload(_ dict: [String: any Sendable]) -> LMStudioUsage? {
        guard let usage = dict["usage"] as? [String: any Sendable] else { return nil }
        func int(_ any: Any?) -> Int? {
            if let i = any as? Int { return i }
            if let n = any as? NSNumber { return n.intValue }
            return nil
        }
        return LMStudioUsage(
            promptTokens: int(usage["prompt_tokens"]),
            completionTokens: int(usage["completion_tokens"]),
            totalTokens: int(usage["total_tokens"])
        )
    }
    
    private func processLMStudioResponse(_ response: LMStudioChatResponse, availableTools: [ToolDefinition], config: LLMRequestConfig) -> LLMResponse {
        guard let choice = response.choices.first else {
            logger?.warning("LM Studio response has no choices - Response ID: \(response.id ?? "unknown"), Choices count: \(response.choices.count)")
            return LLMResponse(content: "No response generated", toolCalls: [])
        }
        
        let content = choice.message.content ?? ""
        let finishReason = choice.finishReason
        
        if content.isEmpty {
            logger?.warning("LM Studio response has empty content - Finish reason: \(finishReason ?? "none")")
        }
        
        logger?.debug("Processing response - Content length: \(content.count), Finish reason: \(finishReason ?? "none"), Tool calls in message: \(choice.message.toolCalls?.count ?? 0)")
        
        let contentResponse = LLMResponse.llmResponse(from: content, availableTools: availableTools)
        
        // Also check for LM Studio's standard tool_calls format (OpenAI-compatible)
        var toolCalls = [ToolCall]()
        if let lmStudioToolCalls = choice.message.toolCalls {
            logger?.debug("Processing \(lmStudioToolCalls.count) tool calls from response")
            for (index, toolCall) in lmStudioToolCalls.enumerated() {
                let arguments = toolCall.function.arguments
                let parsedArgs = parseJSONArguments(arguments)
                
                if case .object(let dict) = parsedArgs, dict.isEmpty && !arguments.isEmpty {
                    logger?.warning("Failed to parse tool call arguments for '\(toolCall.function.name)' - Raw arguments: \(arguments.prefix(200))")
                }
                
                let id = toolCall.id
                let newToolCall = ToolCall(
                    name: toolCall.function.name,
                    arguments: parsedArgs,
                    id: id
                )
                toolCalls.append(newToolCall)
                logger?.debug("Processed tool call \(index + 1)/\(lmStudioToolCalls.count): \(toolCall.function.name)")
            }
        }
        
        let canonicalFinishReason = FinishReason.fromLMStudio(finishReason)
        let storedFinishReason: String? = {
            guard let raw = finishReason else { return nil }
            return canonicalFinishReason == .unknown ? raw : canonicalFinishReason.rawValue
        }()
        let metadata = Self.lmStudioOpenAIMetadata(usage: response.usage, config: config, finishReason: storedFinishReason)
        
        logger?.info("Response processed successfully - Total tokens: \(metadata.totalTokens ?? 0), Tool calls: \(toolCalls.count)")
        
        return contentResponse.appending(toolCalls: toolCalls).updatingMetadata(with: metadata)
    }
    
    nonisolated private func parseJSONArguments(_ jsonString: String) -> JSON {
        guard !jsonString.isEmpty else {
            return .object([:])
        }
        
        guard let data = jsonString.data(using: .utf8) else {
            return .object([:])
        }
        
        guard let json = try? JSONDecoder().decode(JSON.self, from: data) else {
            return .object([:])
        }
        
        return json
    }

    nonisolated private func logRequestPayloadIfDebug(_ payload: [String: Any]) {
        guard logger?.logLevel ?? .info <= .debug, DebugPayloadLogging.isEnabled() else { return }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            logger?.debug("[LMStudioLLM] Failed to encode request payload for debug logging")
            return
        }
        logger?.debug("[LMStudioLLM] Request payload: \(text)")
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
            "[LMStudioLLM] Response payload: content=\(response.content) toolCalls=[\(toolCalls)] metadata=\(String(describing: response.metadata))"
        )
    }
    
    /// Converts a ToolCall to LM Studio format
    nonisolated private func convertToolCallToLMStudioFormat(_ toolCall: ToolCall) -> LMStudioToolCall {
        let argumentsString: String
        if let jsonData = try? JSONEncoder().encode(toolCall.arguments),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            argumentsString = jsonString
        } else {
            argumentsString = "{}"
        }
        
        let function = LMStudioFunctionCall(
            name: toolCall.name,
            arguments: argumentsString
        )
        
        return LMStudioToolCall(
            id: toolCall.id ?? UUID().uuidString,
            type: "function",
            function: function
        )
    }
}

// MARK: - LM Studio Stream Source seam

/// Test seam for ``LMStudioLLM`` — the adapter routes its SSE source through this
/// protocol so contract tests can inject scripted SSE payloads without standing
/// up a real `RestAPIManager` / network transport. Mirrors the
/// ``OllamaChatStreamSourcing`` pattern.
///
/// Default conformance is ``DefaultLMStudioStreamSource``, which constructs a
/// fresh `RestAPIManager` per call and delegates to its `sseRequest(...)` API.
protocol LMStudioStreamSourcing: Sendable {
    func sseStream(
        baseURL: URL,
        endpoint: String,
        parameters: [String: any Sendable],
        sseTimeoutInterval: TimeInterval,
        logger: Logger?
    ) async -> AsyncStream<[String: any Sendable]>
}

struct DefaultLMStudioStreamSource: LMStudioStreamSourcing {
    func sseStream(
        baseURL: URL,
        endpoint: String,
        parameters: [String: any Sendable],
        sseTimeoutInterval: TimeInterval,
        logger: Logger?
    ) async -> AsyncStream<[String: any Sendable]> {
        let apiManager = RestAPIManager(
            baseURL: baseURL,
            sseTimeoutInterval: sseTimeoutInterval,
            logger: logger
        )
        return await apiManager.sseRequest(endpoint, method: .post, parameters: parameters)
    }
}

// MARK: - LM Studio Internal Errors

/// Internal sentinel underlying ``LMStudioErrorMapping/requestEncodingFailure(_:)``
/// when `JSONSerialization` returns an unexpected (non-dictionary) shape. Kept
/// internal and intentionally minimal because the contract surface is the typed
/// `LLMError` produced by `LMStudioErrorMapping`.
enum LMStudioInternalError: Error, LocalizedError {
    case dictionaryConversionFailed
    
    var errorDescription: String? {
        switch self {
        case .dictionaryConversionFailed:
            return "Failed to convert request body to dictionary"
        }
    }
}

// MARK: - LM Studio Request/Response Models

private struct LMStudioChatRequest: Codable {
    let model: String
    let messages: [LMStudioMessage]
    let temperature: Double?
    let maxTokens: Int
    let topP: Double?
    let stream: Bool
    let tools: [LMStudioTool]?
}

private struct LMStudioMessage: Codable {
    let role: String
    let content: String
    let toolCallId: String?
    let toolCalls: [LMStudioToolCall]?
    
    init(role: String, content: String, toolCallId: String? = nil, toolCalls: [LMStudioToolCall]? = nil) {
        self.role = role
        self.content = content
        self.toolCallId = toolCallId
        self.toolCalls = toolCalls
    }
    
    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCallId = "tool_call_id"
        case toolCalls = "tool_calls"
    }
}

private struct LMStudioTool: Codable {
    let type: String
    let function: LMStudioFunction
}

private struct LMStudioFunction: Codable {
    let name: String
    let description: String
    let parameters: LMStudioParameters
}

private struct LMStudioParameters: Codable {
    let type: String
    let properties: [String: LMStudioProperty]
    let required: [String]
}

private struct LMStudioProperty: Codable {
    let type: String
    let description: String
}

private struct LMStudioChatResponse: Codable {
    let id: String?
    let object: String?
    let created: Int?
    let model: String?
    let choices: [LMStudioChoice]
    let usage: LMStudioUsage?
}

private struct LMStudioChoice: Codable {
    let index: Int?
    let message: LMStudioMessageResponse
    let finishReason: String?
}

private struct LMStudioMessageResponse: Codable {
    let role: String?
    let content: String?
    let toolCalls: [LMStudioToolCall]?
}

private struct LMStudioToolCall: Codable {
    let id: String
    let type: String
    let function: LMStudioFunctionCall
}

private struct LMStudioFunctionCall: Codable {
    let name: String
    let arguments: String
}

private struct LMStudioUsage: Codable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
}

// MARK: - Extension for ToolDefinition

extension ToolDefinition {
    fileprivate func toLMStudioParameters() -> LMStudioParameters {
        var properties: [String: LMStudioProperty] = [:]
        var required: [String] = []
        
        for param in parameters {
            properties[param.name] = LMStudioProperty(
                type: param.type,
                description: param.description
            )
            if param.required {
                required.append(param.name)
            }
        }
        
        return LMStudioParameters(
            type: "object",
            properties: properties,
            required: required
        )
    }
}
