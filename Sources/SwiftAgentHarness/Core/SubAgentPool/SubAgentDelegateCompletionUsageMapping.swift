import Foundation
import SwiftAgentKit
import SwiftAgentKitACP

enum SubAgentDelegateCompletionUsageMapping {
    static func from(llmMetadata: LLMMetadata?) -> DelegateCompletionUsagePayload? {
        guard let llmMetadata else { return nil }
        let promptTokens = llmMetadata.promptTokens
        let completionTokens = llmMetadata.completionTokens
        let totalTokens = llmMetadata.totalTokens
        guard hasUsageSignal(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            costUSD: nil
        ) else {
            return nil
        }
        return DelegateCompletionUsagePayload(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            costUSD: nil
        )
    }

    static func from(used: Int, size: Int, cost: ACPUsageCost?) -> DelegateCompletionUsagePayload? {
        _ = size
        let totalTokens = used > 0 ? used : nil
        let costUSD: Double? = {
            guard let cost, cost.currency.uppercased() == "USD" else { return nil }
            return cost.amount
        }()
        guard hasUsageSignal(
            promptTokens: nil,
            completionTokens: nil,
            totalTokens: totalTokens,
            costUSD: costUSD
        ) else {
            return nil
        }
        return DelegateCompletionUsagePayload(
            promptTokens: nil,
            completionTokens: nil,
            totalTokens: totalTokens,
            costUSD: costUSD
        )
    }

    static func merging(
        _ existing: DelegateCompletionUsagePayload?,
        with update: DelegateCompletionUsagePayload?
    ) -> DelegateCompletionUsagePayload? {
        guard let update else { return existing }
        guard let existing else { return update }
        return DelegateCompletionUsagePayload(
            promptTokens: update.promptTokens ?? existing.promptTokens,
            completionTokens: update.completionTokens ?? existing.completionTokens,
            totalTokens: update.totalTokens ?? existing.totalTokens,
            costUSD: update.costUSD ?? existing.costUSD
        )
    }

    private static func hasUsageSignal(
        promptTokens: Int?,
        completionTokens: Int?,
        totalTokens: Int?,
        costUSD: Double?
    ) -> Bool {
        (promptTokens ?? 0) > 0
            || (completionTokens ?? 0) > 0
            || (totalTokens ?? 0) > 0
            || (costUSD ?? 0) > 0
    }
}
