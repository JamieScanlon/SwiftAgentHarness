import Foundation
import SwiftAgentKit

struct NormalizedUsage: Sendable, Equatable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var reasoningTokens: Int?
}

enum NormalizedStopReason: String, Sendable, Equatable {
    case end
    case toolUse
    case maxTokens
    case stopSequence

    init(finishReason: FinishReason) {
        switch finishReason {
        case .toolCalls: self = .toolUse
        case .length: self = .maxTokens
        case .stop, .unknown, .contentFilter, .cancelled, .error: self = .end
        }
    }

    var finishReasonRawValue: String {
        switch self {
        case .end: FinishReason.stop.rawValue
        case .toolUse: FinishReason.toolCalls.rawValue
        case .maxTokens: FinishReason.length.rawValue
        case .stopSequence: "stop_sequence"
        }
    }
}

struct NormalizedStreamError: Sendable, Equatable {
    var classification: ProviderFailoverClassification
    var message: String?
    var retryAfterMs: Int?

    func asLLMError() -> LLMError {
        switch classification {
        case .transient, .rateLimited:
            return .rateLimitExceeded
        case .credentialExhausted:
            return .quotaExceeded
        case .authError:
            return .authenticationFailed
        case .modelNotFound:
            return .modelNotFound(message ?? "model not found")
        case .contextOverflow:
            return .invalidRequest(message ?? "context overflow")
        case .policyBlocked, .permanent:
            if let message { return .invalidRequest(message) }
            return .invalidRequest("permanent provider error")
        }
    }
}

/// Internal canonical adapter event shape used before projecting into `LLMResponse` stream chunks.
enum NormalizedEvent: Sendable, Equatable {
    case textDelta(String)
    case thinkingDelta(String, signature: String? = nil)
    case toolCallStarted(id: String?, name: String?, contentIndex: Int?)
    case toolCallDelta(id: String?, name: String?, argumentsFragment: String)
    case toolCallCompleted(id: String?, name: String?, arguments: String)
    case usage(NormalizedUsage)
    case stop(NormalizedStopReason)
    case error(NormalizedStreamError)
}

struct NormalizedStreamTail: Sendable, Equatable {
    var usage: NormalizedUsage?
    var stop: NormalizedStopReason?

    func apply(to metadata: LLMMetadata?) -> LLMMetadata {
        let merged = LLMTokenMetadataBuilder.merging(
            base: metadata,
            usage: usage,
            usageIsProviderReported: usage != nil
        )
        guard let merged else {
            let inputTokens = metadata?.promptTokens
            let outputTokens = metadata?.completionTokens
            let totalTokens: Int?
            if let inputTokens, let outputTokens {
                totalTokens = inputTokens + outputTokens
            } else {
                totalTokens = metadata?.totalTokens
            }
            return LLMTokenMetadataBuilder.build(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                remainingContextTokens: metadata?.remainingContextTokens,
                totalTokens: totalTokens,
                contextWindowTokens: metadata?.contextWindowTokens,
                extraModelMetadata: metadata?.modelMetadata,
                finishReason: stop?.finishReasonRawValue ?? metadata?.finishReason
            )
        }
        return LLMTokenMetadataBuilder.build(
            inputTokens: merged.promptTokens,
            outputTokens: merged.completionTokens,
            remainingContextTokens: LLMTokenMetadataBuilder.effectiveRemainingContextTokens(from: merged) ?? metadata?.remainingContextTokens,
            totalTokens: merged.totalTokens,
            contextWindowTokens: merged.contextWindowTokens ?? metadata?.contextWindowTokens,
            extraModelMetadata: merged.modelMetadata,
            cacheReadTokens: CanonicalUsageExtraction.cacheReadTokens(from: merged),
            cacheWriteTokens: CanonicalUsageExtraction.cacheWriteTokens(from: merged),
            usageIsProviderReported: CanonicalUsageExtraction.valuesAreProviderReported(from: merged),
            finishReason: stop?.finishReasonRawValue ?? merged.finishReason ?? metadata?.finishReason
        )
    }
}

enum NormalizedEventProjector {
    static func streamChunks(
        for event: NormalizedEvent,
        availableTools: [ToolDefinition],
        toolState: inout ToolCallStreamingState
    ) -> [LLMResponse] {
        switch event {
        case .textDelta(let content):
            return [
                LLMResponse
                    .llmResponse(from: content, availableTools: availableTools)
                    .removingToolCalls()
                    .markingIncomplete(),
            ]
        case .thinkingDelta(let reasoning, _):
            return [LLMResponse.streamChunk("", streamingFragment: .reasoning(reasoning))]
        case .toolCallStarted(let id, let name, let contentIndex):
            return [LLMResponse.streamToolCallStarted(id: id, name: name, contentIndex: contentIndex)]
        case .toolCallDelta(let id, let name, let argumentsFragment):
            return toolState.projectDelta(id: id, name: name, argumentsFragment: argumentsFragment)
        case .toolCallCompleted(let id, let name, let arguments):
            return [LLMResponse.streamToolCallCompleted(id: id, name: name, arguments: arguments)]
        case .usage, .stop, .error:
            return []
        }
    }

    static func toolArgumentsJSONString(for toolCall: ToolCall) -> String {
        if let data = try? JSONEncoder().encode(toolCall.arguments),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "{}"
    }
}

struct ToolCallStreamingState: Sendable {
    var supportsEager: Bool
    private var startedKeys: Set<String> = []

    init(supportsEager: Bool) {
        self.supportsEager = supportsEager
    }

    mutating func projectDelta(
        id: String?,
        name: String?,
        argumentsFragment: String
    ) -> [LLMResponse] {
        let key = id ?? name ?? ""
        if supportsEager {
            var chunks: [LLMResponse] = []
            if !key.isEmpty, startedKeys.insert(key).inserted, name != nil {
                chunks.append(LLMResponse.streamToolCallStarted(id: id, name: name, contentIndex: nil))
            }
            if name != nil || !argumentsFragment.isEmpty {
                chunks.append(
                    LLMResponse.streamChunk(
                        "",
                        streamingFragment: .toolCall(id: id, name: name, argumentsFragment: argumentsFragment)
                    )
                )
            }
            return chunks
        }
        guard !key.isEmpty else { return [] }
        if startedKeys.insert(key).inserted {
            return [LLMResponse.streamToolCallStarted(id: id, name: name, contentIndex: nil)]
        }
        return []
    }

    mutating func completedChunks(for toolCalls: [ToolCall]) -> [LLMResponse] {
        toolCalls.map { call in
            LLMResponse.streamToolCallCompleted(
                id: call.id,
                name: call.name,
                arguments: NormalizedEventProjector.toolArgumentsJSONString(for: call)
            )
        }
    }
}

struct NormalizedStreamEmitter {
    private var toolState: ToolCallStreamingState
    private var tail = NormalizedStreamTail()
    private let streamEmitter: StreamCompletionEmitter

    init(
        continuation: AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error>.Continuation,
        supportsEagerToolInputStreaming: Bool
    ) {
        streamEmitter = StreamCompletionEmitter(continuation: continuation)
        toolState = ToolCallStreamingState(supportsEager: supportsEagerToolInputStreaming)
    }

    mutating func yield(_ event: NormalizedEvent, availableTools: [ToolDefinition]) {
        switch event {
        case .error(let streamError):
            streamEmitter.finishFailed(with: streamError.asLLMError())
        case .usage(let usage):
            tail.usage = usage
        case .stop(let reason):
            tail.stop = reason
        default:
            let chunks = NormalizedEventProjector.streamChunks(
                for: event,
                availableTools: availableTools,
                toolState: &toolState
            )
            for chunk in chunks {
                streamEmitter.yieldStream(chunk)
            }
        }
    }

    mutating func finishSuccess(
        content: String,
        toolCalls: [ToolCall],
        availableTools: [ToolDefinition],
        metadata: LLMMetadata?
    ) {
        if !toolState.supportsEager {
            for chunk in toolState.completedChunks(for: toolCalls) {
                streamEmitter.yieldStream(chunk)
            }
        }
        var response = LLMResponse.llmResponse(from: content, availableTools: availableTools)
            .appending(toolCalls: toolCalls)
        response = response.updatingMetadata(with: tail.apply(to: metadata))
        streamEmitter.finishSuccess(with: response)
    }

    mutating func finishSuccess(with response: LLMResponse) {
        if !toolState.supportsEager, !response.toolCalls.isEmpty {
            for chunk in toolState.completedChunks(for: response.toolCalls) {
                streamEmitter.yieldStream(chunk)
            }
        }
        let merged = response.updatingMetadata(with: tail.apply(to: response.metadata))
        streamEmitter.finishSuccess(with: merged)
    }

    func finishCancelled() {
        streamEmitter.finishCancelled()
    }

    func finishFailed(with error: Error) {
        streamEmitter.finishFailed(with: error)
    }
}

enum NormalizedEventMapper {
    static func streamChunk(for event: NormalizedEvent, availableTools: [ToolDefinition]) -> LLMResponse {
        var state = ToolCallStreamingState(supportsEager: true)
        return NormalizedEventProjector.streamChunks(for: event, availableTools: availableTools, toolState: &state).first
            ?? LLMResponse(content: "", isComplete: false)
    }
}
