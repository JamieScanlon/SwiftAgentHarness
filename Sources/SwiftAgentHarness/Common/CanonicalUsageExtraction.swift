import EasyJSON
import Foundation
import SwiftAgentKit

enum CanonicalUsageExtraction {
    static func from(metadata: LLMMetadata?) -> NormalizedUsage? {
        guard let metadata else { return nil }
        let inputTokens = metadata.promptTokens
        let outputTokens = metadata.completionTokens
        let cacheRead = cacheReadTokens(from: metadata)
        let cacheWrite = cacheWriteTokens(from: metadata)
        let hasSignal = inputTokens != nil
            || outputTokens != nil
            || cacheRead != nil
            || cacheWrite != nil
        guard hasSignal else { return nil }
        return NormalizedUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            reasoningTokens: nil
        )
    }

    static func cacheReadTokens(from metadata: LLMMetadata?) -> Int? {
        nonNegativeInt(from: metadata, key: LLMMetadataKeys.cacheReadTokens)
    }

    static func cacheWriteTokens(from metadata: LLMMetadata?) -> Int? {
        nonNegativeInt(from: metadata, key: LLMMetadataKeys.cacheWriteTokens)
    }

    static func valuesAreProviderReported(from metadata: LLMMetadata?) -> Bool {
        guard let metadata,
              let modelMeta = metadata.modelMetadata,
              case .object(let dict) = modelMeta,
              case .boolean(let reported) = dict[LLMMetadataKeys.usageIsProviderReported]
        else { return false }
        return reported
    }

    static func anthropicUsage(from usageJSON: [String: Any]?) -> NormalizedUsage? {
        guard let usageJSON else { return nil }
        return NormalizedUsage(
            inputTokens: intValue(usageJSON["input_tokens"]),
            outputTokens: intValue(usageJSON["output_tokens"]),
            cacheReadTokens: intValue(usageJSON["cache_read_input_tokens"]),
            cacheWriteTokens: intValue(usageJSON["cache_creation_input_tokens"]),
            reasoningTokens: nil
        )
    }

    static func openAICompatUsage(
        promptTokens: Int?,
        completionTokens: Int?,
        totalTokens: Int?,
        cachedTokens: Int?
    ) -> NormalizedUsage? {
        let cacheRead = cachedTokens.flatMap { $0 > 0 ? $0 : nil }
        let hasSignal = promptTokens != nil
            || completionTokens != nil
            || totalTokens != nil
            || cacheRead != nil
        guard hasSignal else { return nil }
        return NormalizedUsage(
            inputTokens: promptTokens,
            outputTokens: completionTokens,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: nil,
            reasoningTokens: nil
        )
    }

    static func openAICompatCachedTokens(from usage: [String: any Sendable]) -> Int? {
        guard let details = usage["prompt_tokens_details"] as? [String: any Sendable] else { return nil }
        return intValue(details["cached_tokens"])
    }

    private static func nonNegativeInt(from metadata: LLMMetadata?, key: String) -> Int? {
        guard let metadata,
              let modelMeta = metadata.modelMetadata,
              case .object(let dict) = modelMeta,
              case .integer(let value) = dict[key],
              value >= 0
        else { return nil }
        return value
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let value = any as? Int, value >= 0 { return value }
        if let value = any as? NSNumber {
            let intValue = value.intValue
            return intValue >= 0 ? intValue : nil
        }
        return nil
    }
}
