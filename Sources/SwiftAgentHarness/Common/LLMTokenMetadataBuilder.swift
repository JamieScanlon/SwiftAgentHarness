import EasyJSON
import Foundation
import SwiftAgentKit

/// Builds ``LLMMetadata`` with input/output token counts and estimated remaining context.
///
/// When SwiftAgentKit exposes a dedicated property for remaining context, prefer wiring it on ``LLMMetadata`` directly;
/// until then, `remainingContextTokens` is also stored under ``LLMMetadataKeys/remainingContextTokens`` in
/// ``LLMMetadata/modelMetadata`` for JSON-oriented consumers. Input/output counts use ``LLMMetadata/promptTokens`` and
/// ``LLMMetadata/completionTokens``.
enum LLMMetadataKeys {
    static let remainingContextTokens = "remainingContextTokens"
}

enum LLMTokenMetadataBuilder {

    /// Prefer `modelMetadata.remainingContextTokens` (OpenAI-style budget) when present; otherwise SwiftAgentKit’s computed ``LLMMetadata/remainingContextTokens`` (e.g. Ollama).
    static func effectiveRemainingContextTokens(from metadata: LLMMetadata?) -> Int? {
        guard let meta = metadata else { return nil }
        if let modelMeta = meta.modelMetadata,
           case .object(let dict) = modelMeta,
           case .integer(let r) = dict[LLMMetadataKeys.remainingContextTokens] {
            return r
        }
        return meta.remainingContextTokens
    }

    static func build(
        inputTokens: Int?,
        outputTokens: Int?,
        remainingContextTokens: Int?,
        totalTokens: Int?,
        contextWindowTokens: Int? = nil,
        extraModelMetadata: JSON? = nil,
        finishReason: String? = nil
    ) -> LLMMetadata {
        var merged: [String: JSON] = [:]
        if let extraModelMetadata, case .object(let o) = extraModelMetadata {
            merged = o
        }
        if let remainingContextTokens {
            merged[LLMMetadataKeys.remainingContextTokens] = .integer(remainingContextTokens)
        }
        let modelMeta: JSON? = merged.isEmpty ? nil : .object(merged)
        return LLMMetadata(
            promptTokens: inputTokens,
            completionTokens: outputTokens,
            totalTokens: totalTokens,
            contextWindowTokens: contextWindowTokens,
            modelMetadata: modelMeta,
            finishReason: finishReason
        )
    }

    /// OpenAI-style: `model_context_limit - input_tokens - reserved_output_tokens`.
    /// `reservedOutputTokens` should be the completion budget when known (e.g. `max_completion_tokens` on the request);
    /// otherwise falls back to actual completion tokens from the response.
    static func openAIRemainingContext(
        modelContextLimit: Int?,
        promptTokens: Int?,
        reservedOutputTokens: Int?
    ) -> Int? {
        guard let limit = modelContextLimit, let prompt = promptTokens else { return nil }
        let reserved = reservedOutputTokens ?? 0
        return max(0, limit - prompt - reserved)
    }

    static func maxCompletionTokens(from config: LLMRequestConfig) -> Int? {
        guard let additionalParameters = config.additionalParameters,
              case .object(let dict) = additionalParameters,
              let raw = dict["maxCompletionTokens"] else {
            return nil
        }
        switch raw {
        case .integer(let i):
            return i
        case .double(let d):
            return Int(d)
        default:
            return nil
        }
    }
}
