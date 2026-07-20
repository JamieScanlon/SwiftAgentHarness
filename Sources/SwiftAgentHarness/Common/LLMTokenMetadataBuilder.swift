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
    static let cacheReadTokens = "cacheReadTokens"
    static let cacheWriteTokens = "cacheWriteTokens"
    static let usageIsProviderReported = "usageIsProviderReported"
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
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        usageIsProviderReported: Bool = false,
        finishReason: String? = nil
    ) -> LLMMetadata {
        var merged: [String: JSON] = [:]
        if let extraModelMetadata, case .object(let o) = extraModelMetadata {
            merged = o
        }
        if let remainingContextTokens {
            merged[LLMMetadataKeys.remainingContextTokens] = .integer(remainingContextTokens)
        }
        if let cacheReadTokens, cacheReadTokens >= 0 {
            merged[LLMMetadataKeys.cacheReadTokens] = .integer(cacheReadTokens)
        }
        if let cacheWriteTokens, cacheWriteTokens >= 0 {
            merged[LLMMetadataKeys.cacheWriteTokens] = .integer(cacheWriteTokens)
        }
        if usageIsProviderReported {
            merged[LLMMetadataKeys.usageIsProviderReported] = .boolean(true)
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

    static func merging(
        base: LLMMetadata?,
        usage: NormalizedUsage?,
        usageIsProviderReported: Bool = false
    ) -> LLMMetadata? {
        guard let usage else { return base }
        let inputTokens = usage.inputTokens ?? base?.promptTokens
        let outputTokens = usage.outputTokens ?? base?.completionTokens
        let totalTokens: Int?
        if let inputTokens, let outputTokens {
            totalTokens = inputTokens + outputTokens
        } else {
            totalTokens = base?.totalTokens
        }
        let reported = usageIsProviderReported
            || CanonicalUsageExtraction.valuesAreProviderReported(from: base)
            || usage.cacheReadTokens != nil
            || usage.cacheWriteTokens != nil
        return build(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            remainingContextTokens: effectiveRemainingContextTokens(from: base),
            totalTokens: totalTokens,
            contextWindowTokens: base?.contextWindowTokens,
            extraModelMetadata: base?.modelMetadata,
            cacheReadTokens: usage.cacheReadTokens ?? CanonicalUsageExtraction.cacheReadTokens(from: base),
            cacheWriteTokens: usage.cacheWriteTokens ?? CanonicalUsageExtraction.cacheWriteTokens(from: base),
            usageIsProviderReported: reported,
            finishReason: base?.finishReason
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
