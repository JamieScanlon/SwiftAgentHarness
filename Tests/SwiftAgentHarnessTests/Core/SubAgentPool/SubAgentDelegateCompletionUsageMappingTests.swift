import Foundation
import SwiftAgentKit
import SwiftAgentKitACP
import Testing
@testable import SwiftAgentHarness

@Suite("SubAgentDelegateCompletionUsageMapping")
struct SubAgentDelegateCompletionUsageMappingTests {
    @Test("LLMMetadata maps token fields")
    func llmMetadataMapsTokens() {
        let metadata = LLMMetadata(promptTokens: 100, completionTokens: 50, totalTokens: 150)
        let usage = SubAgentDelegateCompletionUsageMapping.from(llmMetadata: metadata)
        #expect(usage?.promptTokens == 100)
        #expect(usage?.completionTokens == 50)
        #expect(usage?.totalTokens == 150)
        #expect(usage?.costUSD == nil)
    }

    @Test("LLMMetadata without token signal returns nil")
    func llmMetadataWithoutSignalReturnsNil() {
        #expect(SubAgentDelegateCompletionUsageMapping.from(llmMetadata: nil) == nil)
        #expect(SubAgentDelegateCompletionUsageMapping.from(llmMetadata: LLMMetadata()) == nil)
    }

    @Test("ACP usageUpdate maps used tokens and USD cost")
    func acpUsageUpdateMapsTokensAndCost() {
        let usage = SubAgentDelegateCompletionUsageMapping.from(
            used: 250,
            size: 4096,
            cost: ACPUsageCost(amount: 0.015, currency: "USD")
        )
        #expect(usage?.totalTokens == 250)
        #expect(usage?.costUSD == 0.015)
    }

    @Test("ACP usageUpdate ignores non-USD cost")
    func acpUsageUpdateIgnoresNonUSDCost() {
        let usage = SubAgentDelegateCompletionUsageMapping.from(
            used: 0,
            size: 4096,
            cost: ACPUsageCost(amount: 0.015, currency: "EUR")
        )
        #expect(usage == nil)
    }

    @Test("ACP usageUpdate with zero used and no cost returns nil")
    func acpUsageUpdateWithoutSignalReturnsNil() {
        #expect(SubAgentDelegateCompletionUsageMapping.from(used: 0, size: 4096, cost: nil) == nil)
    }

    @Test("merge prefers latest non-nil fields")
    func mergePrefersLatestNonNilFields() {
        let existing = DelegateCompletionUsagePayload(totalTokens: 100, costUSD: 0.01)
        let update = DelegateCompletionUsagePayload(totalTokens: 200, costUSD: nil)
        let merged = SubAgentDelegateCompletionUsageMapping.merging(existing, with: update)
        #expect(merged?.totalTokens == 200)
        #expect(merged?.costUSD == 0.01)
    }
}
