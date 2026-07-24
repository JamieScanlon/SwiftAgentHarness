import Foundation
import Logging
import SwiftAgentKit
import OpenAI
import EasyJSON

// MARK: - Custom OpenAI LLM Implementation

/// A robust OpenAI-compatible LLM implementation that leverages the official
/// OpenAI library.
///
/// Conforms to the ``AdapterContract``: streaming tool-call deltas are
/// merged through ``ToolCallAccumulator`` (deduping the same `id` /
/// `(name, arguments)` if the upstream replays it across deltas); `.complete`
/// + `finish()` are emitted exactly once via ``StreamCompletionEmitter`` on
/// success; cancellation surfaces as `CancellationError` and is routed through
/// the same emitter so consumers see the `.complete`-once invariant on every
/// terminal path.
struct OpenAILLM: LLMProtocol, AdapterAuthProbing {
    typealias AuthProbeTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let openAI: OpenAI
    private let model: String
    private let capabilities: [LLMCapability]
    private let requestFeatures: ModelRequestFeatures
    /// When set, the first system message is expanded with ``SystemPrompt/generateSystemPrompt`` each request (skills, metadata, etc.), matching ``LMStudioLLM`` / ``OllamaLLM``.
    private let systemPrompt: SystemPrompt?
    private let logger: Logger?
    private let authProbeModelsURL: URL
    private let authProbeAPIKey: String
    private let authProbeTransport: AuthProbeTransport?
    private let supportsEagerToolInputStreaming: Bool
    private let authProbePermissiveForEmptyToken: Bool
    private let streamSource: any OpenAIChatStreamSourcing
    /// "Never timeout" represented as a very large finite interval.
    private static let effectivelyNoTimeoutInterval: TimeInterval = 60 * 60 * 24 * 365 * 10
    
    init(
        baseURL: String,
        apiKey: String,
        model: String,
        capabilities: [LLMCapability] = [.unknown],
        requestFeatures: ModelRequestFeatures = .unknown,
        systemPrompt: SystemPrompt? = nil,
        logger: Logger? = nil,
        authProbeTransport: AuthProbeTransport? = nil,
        supportsEagerToolInputStreaming: Bool = false,
        authProbePermissiveForEmptyToken: Bool = false,
        streamSource: (any OpenAIChatStreamSourcing)? = nil
    ) {
        let parsedURL = URL(string: baseURL)!
        self.model = model
        self.capabilities = capabilities
        self.requestFeatures = requestFeatures
        self.systemPrompt = systemPrompt
        self.logger = logger
        self.authProbeModelsURL = parsedURL.appendingPathComponent("models")
        self.authProbeAPIKey = apiKey
        self.authProbeTransport = authProbeTransport
        self.supportsEagerToolInputStreaming = supportsEagerToolInputStreaming
        self.authProbePermissiveForEmptyToken = authProbePermissiveForEmptyToken
        
        // Parse the base URL to extract host, port, and scheme
        let host = parsedURL.host ?? "api.openai.com"
        let port = parsedURL.port ?? (parsedURL.scheme == "https" ? 443 : 80)
        let scheme = parsedURL.scheme ?? "https"
        let basePath = parsedURL.path.isEmpty ? "/v1" : parsedURL.path
        
        // Create OpenAI Configuration
        let config = OpenAI.Configuration(
            token: apiKey,
            host: host,
            port: port,
            scheme: scheme,
            basePath: basePath,
            timeoutInterval: Self.effectivelyNoTimeoutInterval,
            customHeaders: [:],
            parsingOptions: []
        )
        
        let client = OpenAI(configuration: config)
        self.openAI = client
        self.streamSource = streamSource ?? LiveOpenAIChatStreamSource(client: client)
    }
    
    func getModelName() -> String {
        return model
    }
    
    func getCapabilities() -> [LLMCapability] {
        return capabilities
    }

    func getRequestFeatures() -> ModelRequestFeatures {
        requestFeatures
    }

    func validateAuth() async -> Bool {
        let token = authProbeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if authProbePermissiveForEmptyToken,
           token.isEmpty || token == "dummy_key" || token == "dummy-key" {
            return true
        }
        if token.isEmpty {
            return false
        }
        var request = URLRequest(url: authProbeModelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (_, response) = try await runAuthProbe(request: request)
            switch response.statusCode {
            case 401, 403:
                return false
            case 200 ... 299:
                return true
            default:
                return true
            }
        } catch {
            logger?.warning("OpenAI auth probe request failed (treated as indeterminate/allow): \(error)")
            return true
        }
    }
    
    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        
        guard getCapabilities().contains(.completion) || getCapabilities().contains(.unknown) else {
            throw LLMError.unsupportedCapability(.completion)
        }
        
        let openAIMessages = try await openAIChatCompletionMessageParams(from: messages, config: config)
        logPromptCacheNoOpIfNeeded(config: config)
        
        let query = makeChatQuery(openAIMessages: openAIMessages, config: config, stream: false, includeStreamUsage: false)
        logOpenAIRequestPayloadIfDebug(query: query)
        
        do {
            let response = try await openAI.chats(query: query)
            let processed = processOpenAIResponse(response, availableTools: config.availableTools, config: config)
            logLLMResponsePayloadIfDebug(processed)
            return processed
        } catch let error as LLMError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Wrap unknown upstream-client errors so ``TransientErrorClassifier`` can recurse.
            // Per-HTTP-status precision is blocked on the upstream `OpenAI` client surface.
            throw LLMError.networkError(error)
        }
    }
    
    func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        
        guard getCapabilities().contains(.completion) || getCapabilities().contains(.unknown) else {
            return AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> { continuation in
                continuation.finish(throwing: LLMError.unsupportedCapability(.completion))
            }
        }
        
        return AsyncThrowingStream { continuation in
            Task {
                var emitter = NormalizedStreamEmitter(
                    continuation: continuation,
                    supportsEagerToolInputStreaming: self.supportsEagerToolInputStreaming
                )
                do {
                    let openAIMessages = try await self.openAIChatCompletionMessageParams(from: messages, config: config)
                    self.logPromptCacheNoOpIfNeeded(config: config)
                    
                    let query = makeChatQuery(openAIMessages: openAIMessages, config: config, stream: true, includeStreamUsage: true)
                    self.logOpenAIRequestPayloadIfDebug(query: query)
                    
                    var fullContent = ""
                    var accumulator = ToolCallAccumulator()
                    var usage: ChatResult.CompletionUsage?
                    var finishReason: String?
                    
                    for try await result in streamSource.chatStream(query: query) {
                        if let u = result.usage {
                            usage = u
                        }
                        if let fr = result.choices.first?.finishReason {
                            finishReason = fr.rawValue
                        }
                        let delta = result.choices.first?.delta
                        if let reasoning = delta?.reasoning, !reasoning.isEmpty {
                            emitter.yield(
                                .thinkingDelta(reasoning),
                                availableTools: config.availableTools
                            )
                        }
                        if let content = delta?.content, !content.isEmpty {
                            fullContent += content
                            emitter.yield(
                                .textDelta(content),
                                availableTools: config.availableTools
                            )
                        }
                        
                        // Handle tool calls from streaming response. The OpenAI client does
                        // not expose `delta.tool_calls[].index`, so we route through the
                        // ``ToolCallAccumulator`` name+args fragment path; dedupe collapses
                        // any replay of the same `id` / `(name, arguments)` pair on the
                        // `.complete` boundary.
                        if let deltaToolCalls = delta?.toolCalls {
                            for toolCall in deltaToolCalls {
                                let fn = toolCall.function
                                let argsFragment = fn?.arguments ?? ""
                                let name = fn?.name
                                let id = toolCall.id
                                if name != nil || !argsFragment.isEmpty {
                                    emitter.yield(
                                        .toolCallDelta(
                                            id: id,
                                            name: name,
                                            argumentsFragment: argsFragment
                                        ),
                                        availableTools: config.availableTools
                                    )
                                }
                                accumulator.ingestNameAndArgs(
                                    id: id,
                                    name: name,
                                    argumentsFragment: argsFragment
                                )
                            }
                        }
                    }
                    
                    if let usage {
                        emitter.yield(
                            .usage(
                                CanonicalUsageExtraction.openAICompatUsage(
                                    promptTokens: usage.promptTokens,
                                    completionTokens: usage.completionTokens,
                                    totalTokens: usage.totalTokens,
                                    cachedTokens: usage.promptTokensDetails?.cachedTokens
                                ) ?? NormalizedUsage(
                                    inputTokens: usage.promptTokens,
                                    outputTokens: usage.completionTokens
                                )
                            ),
                            availableTools: config.availableTools
                        )
                    }
                    let canonicalFinishReason = FinishReason.fromOpenAI(finishReason)
                    emitter.yield(
                        .stop(NormalizedStopReason(finishReason: canonicalFinishReason)),
                        availableTools: config.availableTools
                    )
                    let storedFinishReason: String? = {
                        guard let raw = finishReason else { return nil }
                        return canonicalFinishReason == .unknown ? raw : canonicalFinishReason.rawValue
                    }()
                    let metadata = openAIMetadata(usage: usage, config: config, finishReason: storedFinishReason)
                    let toolCalls = accumulator.finalize()
                    self.logLLMResponsePayloadIfDebug(
                        LLMResponse.llmResponse(from: fullContent, availableTools: config.availableTools)
                            .appending(toolCalls: toolCalls)
                            .updatingMetadata(with: metadata)
                    )
                    emitter.finishSuccess(
                        content: fullContent,
                        toolCalls: toolCalls,
                        availableTools: config.availableTools,
                        metadata: metadata
                    )
                    
                } catch is CancellationError {
                    emitter.finishCancelled()
                } catch {
                    // ``NormalizedStreamEmitter/finishFailed(with:)`` rethrows `LLMError`
                    // raw and wraps everything else as `LLMError.networkError(_:)` so
                    // ``TransientErrorClassifier`` can recurse.
                    emitter.finishFailed(with: error)
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    /// OpenAI-compatible: `estimated_context_left = model_context_limit - input_tokens - reserved_output_tokens`.
    /// `config.maxTokens` is treated as the model context limit (see ``HarnessRuntimeSession`` orchestrator config).
    /// Reserved output is `maxCompletionTokens` from ``LLMRequestConfig/additionalParameters`` when set, else
    /// actual completion tokens from the response.
    private func openAIMetadata(
        usage: ChatResult.CompletionUsage?,
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
            cacheReadTokens: usage?.promptTokensDetails?.cachedTokens,
            usageIsProviderReported: usage != nil,
            finishReason: finishReason
        )
    }
    
    private func openAIChatCompletionMessageParams(from messages: [Message], config: LLMRequestConfig) async throws -> [ChatQuery.ChatCompletionMessageParam] {
        let attachmentDispositions = extractAttachmentDispositions(from: config.additionalParameters)
        let promptMetadata = SystemPromptDispatchCodec.extractPromptMetadata(from: config.additionalParameters)
        let providerStablePrefix = SystemPromptDispatchCodec.extractProviderStablePrefix(from: config.additionalParameters)
        let plan = try await SystemPromptDispatchCodec.resolve(
            messages: messages,
            systemPrompt: systemPrompt,
            promptMetadata: promptMetadata,
            providerStablePrefix: providerStablePrefix
        )
        var openAIMessages: [ChatQuery.ChatCompletionMessageParam] = []
        openAIMessages.reserveCapacity(plan.resolvedMessages.count)
        for message in plan.resolvedMessages {
            let text: String
            if message.role == .system {
                text = message.content
            } else {
                text = message.content + attachmentDispositionSuffix(
                    imageNames: message.images.map(\.name),
                    dispositions: attachmentDispositions,
                    additionalParameters: config.additionalParameters
                )
            }
            let role = ChatQuery.ChatCompletionMessageParam.Role(rawValue: message.role.rawValue) ?? .user
            if role == .user {
                let visionImages = OpenAICompatibleVisionContent.inlineImagesWithData(
                    from: message.images,
                    dispositions: attachmentDispositions
                )
                if !visionImages.isEmpty {
                    var parts: [ChatQuery.ChatCompletionMessageParam.UserMessageParam.Content.ContentPart] = [
                        .text(.init(text: text))
                    ]
                    for image in visionImages {
                        guard let data = image.imageData else { continue }
                        parts.append(.image(.init(imageUrl: .init(
                            url: OpenAICompatibleVisionContent.dataURL(for: data),
                            detail: .auto
                        ))))
                    }
                    openAIMessages.append(.user(.init(content: .contentParts(parts))))
                    continue
                }
            }
            if let param = ChatQuery.ChatCompletionMessageParam(
                role: role,
                content: text,
                toolCalls: message.toolCalls.map({ $0.toOpenAIToolCall() }),
                toolCallId: message.toolCallId
            ) {
                openAIMessages.append(param)
            }
        }
        return openAIMessages
    }

    /// Test hook: encodes chat messages for the given request (no network).
    func testEncodedChatMessagesJSON(from messages: [Message], config: LLMRequestConfig) async throws -> Data {
        let params = try await openAIChatCompletionMessageParams(from: messages, config: config)
        return try JSONEncoder().encode(params)
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
        AttachmentProjectionDispatchCodec.extractDispositions(from: additionalParameters)
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
                  disposition != "inline" else {
                return nil
            }
            return "\(name):\(disposition)"
        }
        guard !projected.isEmpty else { return "" }
        return "\n\n[Attachment projection]\n" + projected.joined(separator: "\n")
    }

    private func makeChatQuery(
        openAIMessages: [ChatQuery.ChatCompletionMessageParam],
        config: LLMRequestConfig,
        stream: Bool,
        includeStreamUsage: Bool
    ) -> ChatQuery {
        let tools = config.availableTools.isEmpty ? nil : config.availableTools.map { tool in
            let schema = config.toolParameterSchemasByName[tool.name]
            let strict = config.toolSchemaStrictByName[tool.name] ?? false
            return ChatQuery.ChatCompletionToolParam(
                function: tool.toOpenAIFunction(parameterSchema: schema, strict: strict)
            )
        }
        let streamOptions = stream && includeStreamUsage ? ChatQuery.StreamOptions(includeUsage: true) : nil
        let reasoningEffort = extractReasoningEffort(from: config.additionalParameters)
        let toolChoice = Self.toolChoice(
            for: ToolChoiceTranslation.effectivePolicy(
                config: config,
                features: requestFeatures,
                hasTools: tools != nil,
                model: model,
                logger: logger
            )
        )
        return ChatQuery(
            messages: openAIMessages,
            model: .init(stringLiteral: model),
            reasoningEffort: reasoningEffort,
            maxCompletionTokens: LLMTokenMetadataBuilder.maxCompletionTokens(from: config),
            temperature: config.temperature,
            toolChoice: toolChoice,
            tools: tools,
            topP: config.topP,
            stream: stream,
            streamOptions: streamOptions
        )
    }

    /// Translates an already-clamped ``ToolInvocationPolicy`` into OpenAI's `tool_choice`.
    /// ``ToolInvocationPolicy/automatic`` is left to the provider default (`nil`).
    static func toolChoice(
        for policy: ToolInvocationPolicy
    ) -> ChatQuery.ChatCompletionFunctionCallOptionParam? {
        switch policy {
        case .automatic: return nil
        case .required: return .required
        case .none: return ChatQuery.ChatCompletionFunctionCallOptionParam.none
        case .specific(let toolName): return .function(toolName)
        }
    }

    func extractReasoningEffort(from additionalParameters: JSON?) -> ChatQuery.ReasoningEffort? {
        let caps = getCapabilities()
        guard caps.contains(.thinking) || caps.contains(.reasoningRequired),
              let additionalParameters,
              case .object(let root) = additionalParameters,
              let rawThinkingConfig = root["thinkingConfig"] else {
            return nil
        }
        guard let thinkingConfig = parseThinkingConfig(rawThinkingConfig) else {
            return nil
        }
        switch thinkingConfig {
        case .disabled:
            return ChatQuery.ReasoningEffort.none
        case .adaptive:
            return nil
        case .level(.off, _):
            return ChatQuery.ReasoningEffort.none
        case .level(.minimal, _):
            return .minimal
        case .level(.low, _):
            return .low
        case .level(.medium, _):
            return .medium
        case .level(.high, _), .level(.xhigh, _):
            return .high
        }
    }

    private func parseThinkingConfig(_ raw: JSON) -> ThinkingConfig? {
        switch raw {
        case .string(let value):
            switch value {
            case "disabled":
                return .disabled
            case "adaptive":
                return .adaptive
            default:
                return nil
            }
        case .object(let object):
            guard case .string(let levelRaw)? = object["level"],
                  let level = ThinkingLevel(rawValue: levelRaw) else {
                return nil
            }
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
    
    private func processOpenAIResponse(_ response: ChatResult, availableTools: [ToolDefinition], config: LLMRequestConfig) -> LLMResponse {
        guard let choice = response.choices.first else {
            return LLMResponse(content: "No response generated", toolCalls: [])
        }
        
        let content = choice.message.content ?? ""
        let finishReason = choice.finishReason
        
        // Use LLMProtocol's helper method to parse tool calls from content
        let contentResponse = LLMResponse.llmResponse(from: content, availableTools: availableTools)
        
        // Also check for OpenAI's standard tool_calls format
        var toolCalls = [ToolCall]()
        if let openAIToolCalls = choice.message.toolCalls {
            for toolCall in openAIToolCalls {
                let arguments = toolCall.function.arguments
                let parsedArgs = parseJSONArguments(arguments)
                let id = toolCall.id
                let newToolCall = ToolCall(
                    name: toolCall.function.name,
                    arguments: parsedArgs,
                    id: id
                )
                toolCalls.append(newToolCall)
            }
        }
        
        // Canonicalize the finish reason via the contract's ``FinishReason`` mapper.
        // Unmapped values pass through verbatim so debugging information is preserved.
        let canonicalFinishReason = FinishReason.fromOpenAI(finishReason)
        let storedFinishReason: String = canonicalFinishReason == .unknown ? finishReason : canonicalFinishReason.rawValue
        let metadata = openAIMetadata(usage: response.usage, config: config, finishReason: storedFinishReason)
        
        return contentResponse.appending(toolCalls: toolCalls).updatingMetadata(with: metadata)
    }

    private func runAuthProbe(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let authProbeTransport {
            return try await authProbeTransport(request)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse("Non-HTTP response during OpenAI auth probe")
        }
        return (data, http)
    }

    private func logPromptCacheNoOpIfNeeded(config: LLMRequestConfig) {
        guard let additional = config.additionalParameters,
              case .object(let root) = additional,
              case .string(let mode)? = root[PromptCacheKnobKey.mode],
              mode != "none" else {
            return
        }
        logger?.debug("Prompt-cache plan is a no-op for current OpenAI adapter transport")
    }

    private func logOpenAIRequestPayloadIfDebug(query: ChatQuery) {
        guard logger?.logLevel ?? .info <= .debug, DebugPayloadLogging.isEnabled() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(query),
              let body = String(data: data, encoding: .utf8) else {
            logger?.debug("[OpenAILLM] Failed to encode OpenAI request payload for debug logging")
            return
        }
        logger?.debug("[OpenAILLM] Request payload: \(body)")
    }

    private func logLLMResponsePayloadIfDebug(_ response: LLMResponse) {
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
            "[OpenAILLM] Response payload: content=\(response.content) toolCalls=[\(toolCalls)] metadata=\(String(describing: response.metadata))"
        )
    }
    
    private func parseJSONArguments(_ jsonString: String) -> JSON {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSON.self, from: data) else {
            return .object([:])
        }
        return json
    }
}

// MARK: - Extension for OpenAI

extension ToolDefinition {
    func toOpenAIFunction(parameterSchema: JSON? = nil, strict: Bool = false) -> ChatQuery.ChatCompletionToolParam.FunctionDefinition {
        var params: JSONSchema?
        if let parameterSchema,
           let schema = ToolSchemaWireCodec.openAIJSONSchema(from: parameterSchema) {
            params = schema
        } else if parameters.isEmpty == false {
            var props: Dictionary<String, AnyJSONDocument> = Dictionary<String, AnyJSONDocument>()
            for p in parameters {
                props[p.name] = .init(["type": p.type])
            }
            let required: [String] = parameters.compactMap({
                if $0.required {
                    return $0.name
                } else {
                    return nil
                }
            })
            
            let dict: [String: AnyJSONDocument] = [
                "type": .init("object"),
                "properties": .init(props),
                "required": .init(required)
            ]
            params = .object(dict)
        }
        return .init(
            name: name,
            description: description,
            parameters: params,
            strict: strict
        )
    }
}

/// Test seam for ``OpenAILLM/stream(_:config:)`` without opening real sockets.
protocol OpenAIChatStreamSourcing: Sendable {
    func chatStream(query: ChatQuery) -> AsyncThrowingStream<ChatStreamResult, Error>
}

private final class LiveOpenAIChatStreamSource: @unchecked Sendable, OpenAIChatStreamSourcing {
    private let client: OpenAI

    init(client: OpenAI) {
        self.client = client
    }

    func chatStream(query: ChatQuery) -> AsyncThrowingStream<ChatStreamResult, Error> {
        client.chatsStream(query: query)
    }
}

extension ToolCall {
    func toOpenAIToolCall() -> ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam {
        // Convert the JSON arguments to a string
        let argumentsString: String
        if let jsonData = try? JSONEncoder().encode(arguments),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            argumentsString = jsonString
        } else {
            argumentsString = "{}"
        }
        
        let function = ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam.FunctionCall(
            arguments: argumentsString,
            name: name
        )
        
        return ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam(
            id: self.id ?? UUID().uuidString,
            function: function
        )
    }
}


