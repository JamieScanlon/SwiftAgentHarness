import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Canonical usage extraction")
struct CanonicalUsageExtractionTests {
    @Test("Anthropic usage JSON maps cache read and write tokens")
    func anthropicUsageJSON() {
        let usage = CanonicalUsageExtraction.anthropicUsage(from: [
            "input_tokens": 1200,
            "output_tokens": 80,
            "cache_read_input_tokens": 900,
            "cache_creation_input_tokens": 300,
        ])
        #expect(usage?.inputTokens == 1200)
        #expect(usage?.outputTokens == 80)
        #expect(usage?.cacheReadTokens == 900)
        #expect(usage?.cacheWriteTokens == 300)
    }

    @Test("Metadata round-trip preserves provider-reported cache usage")
    func metadataRoundTrip() {
        let metadata = LLMTokenMetadataBuilder.build(
            inputTokens: 500,
            outputTokens: 25,
            remainingContextTokens: nil,
            totalTokens: 525,
            cacheReadTokens: 400,
            cacheWriteTokens: 100,
            usageIsProviderReported: true
        )
        let extracted = CanonicalUsageExtraction.from(metadata: metadata)
        #expect(extracted?.cacheReadTokens == 400)
        #expect(extracted?.cacheWriteTokens == 100)
        #expect(CanonicalUsageExtraction.valuesAreProviderReported(from: metadata))
    }

    @Test("Missing cache fields return nil usage signal")
    func missingCacheFields() {
        let metadata = LLMMetadata(promptTokens: 10, completionTokens: 5)
        #expect(CanonicalUsageExtraction.cacheReadTokens(from: metadata) == nil)
        #expect(CanonicalUsageExtraction.cacheWriteTokens(from: metadata) == nil)
        #expect(CanonicalUsageExtraction.valuesAreProviderReported(from: metadata) == false)
    }

    @Test("OpenAI compat cached tokens parse from prompt_tokens_details")
    func openAICompatCachedTokens() {
        let usage: [String: any Sendable] = [
            "prompt_tokens": 100,
            "completion_tokens": 20,
            "total_tokens": 120,
            "prompt_tokens_details": ["cached_tokens": 64],
        ]
        let cached = CanonicalUsageExtraction.openAICompatCachedTokens(from: usage)
        let normalized = CanonicalUsageExtraction.openAICompatUsage(
            promptTokens: 100,
            completionTokens: 20,
            totalTokens: 120,
            cachedTokens: cached
        )
        #expect(cached == 64)
        #expect(normalized?.cacheReadTokens == 64)
        #expect(normalized?.cacheWriteTokens == nil)
    }
}
