
import Foundation
import SwiftAgentKit

/// Identifies non-primary LLM calls (compaction, turn metadata, etc.) in server logs.
enum HarnessLLMRequestPurpose: String, Sendable {
    case contextCompactionSummarizeMiddle = "transform.contextCompaction.summarizeMiddle"
    case contextCompactionToolResult = "transform.contextCompaction.toolResult"
    case contextCompactionTurnSummary = "transform.contextCompaction.turnSummary"
    case memoryRecallSelector = "memory.recallSelector"
}

extension LLMRequestConfig {
    /// Tags outbound requests so `Sending … chat request` lines name the subsystem (compaction, etc.).
    static func harnessTagged(_ purpose: HarnessLLMRequestPurpose) -> LLMRequestConfig {
        LLMRequestConfig(
            additionalParameters: .object([
                LLMRequestPurposeKey.requestPurpose: .string(purpose.rawValue)
            ])
        )
    }
}
