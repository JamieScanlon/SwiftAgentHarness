import Foundation
import SwiftAgentKit

/// Token-based eligibility for context compaction.
///
/// Proactive trigger model:
/// - `effective_context_window = model_context_window − proactiveOutputReserveTokens`
/// - `proactiveThresholdTokens = effective_context_window − proactiveSafetyBufferTokens`
/// - Trigger fires when `total_prompt_tokens > proactiveThresholdTokens`.
/// - `total_prompt_tokens` comes from the previous successful LLM response (`lastPromptTokens`)
///   when available; otherwise estimated from the outgoing payload via `charactersPerToken`.
public enum ContextCompactionPolicy: Sendable {
    /// Resolves advanced summarization strategy only; provider/backend selection is handled by
    /// compaction-provider factory seams during transformer construction.
    public static func resolvedStrategy(
        config: ContextCompactionConfiguration,
        branchParentConversationID: UUID?,
        explicitFocusQuery: String?
    ) -> ContextCompactionStrategy {
        _ = branchParentConversationID
        _ = explicitFocusQuery
        guard let configured = ContextCompactionStrategy(rawValue: config.defaultSummarizationStrategy) else {
            return .default
        }
        switch configured {
        case .iterativeDelta, .focused:
            return .default
        default:
            return configured
        }
    }

    public static func resolvedCachePolicy(config: ContextCompactionConfiguration) -> ContextCompactionCachePolicy {
        ContextCompactionCachePolicy(
            enabled: config.cacheAwarePruningEnabled,
            stablePrefixMessageCount: max(0, config.cacheStablePrefixMessageCount),
            ttlSeconds: config.cachePruningTTLSeconds
        )
    }

    public static func resolvedDeterministicHygienePolicy(
        config: ContextCompactionConfiguration
    ) -> ContextCompactionDeterministicHygienePolicy {
        ContextCompactionDeterministicHygienePolicy(
            toolResultPruningEnabled: config.deterministicToolResultPruningEnabled,
            attachmentDocumentHygiene: ContextCompactionAttachmentDocumentHygienePolicy(
                enabled: config.deterministicAttachmentDocumentHygieneEnabled,
                maxImagesPerMessage: max(0, config.deterministicMaxImagesPerMessage),
                documentCharacterThreshold: max(0, config.deterministicDocumentCharacterThreshold),
                imagePlaceholder: config.deterministicImagePlaceholder,
                documentPlaceholder: config.deterministicDocumentPlaceholder
            )
        )
    }

    public static func resolvedSplitOptions(
        modelContextLimitTokens: Int,
        config: ContextCompactionConfiguration
    ) -> ContextCompactionSplitOptions {
        let threshold = proactiveThresholdTokens(
            modelContextLimitTokens: modelContextLimitTokens,
            config: config
        )
        let fraction = max(0, min(1, config.tailTokenBudgetFraction))
        return ContextCompactionSplitOptions(
            headMinMessageCount: config.headMinMessageCount,
            tailMinMessageCount: config.tailMinMessageCount,
            tailTokenBudget: max(1, Int(floor(Double(threshold) * fraction))),
            charactersPerToken: config.charactersPerToken
        )
    }

    public static func resolvedSummaryBudgetTokens(
        tokensCompressed: Int,
        config: ContextCompactionConfiguration
    ) -> Int {
        if config.compactionSummaryBudgetProportionalEnabled {
            return max(2_000, min(Int(Double(tokensCompressed) * 0.20), 12_000))
        }
        return config.compactionSummaryBudgetTokens
    }

    public static func focusedCompactionInstructionBlock(topic: String) -> String {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return """
        The user has requested focused compaction on the topic: "\(trimmed)".
        Allocate approximately 60–70% of the summary budget to content related to this topic.
        Aggressively summarize everything else.
        """
    }

    public static func resolvedPreCompactionMemoryFlushPolicy(
        config: ContextCompactionConfiguration
    ) -> ContextEnginePreCompactionMemoryFlushPolicyInput {
        ContextEnginePreCompactionMemoryFlushPolicyInput(
            enabled: config.preCompactionMemoryFlushEnabled,
            maxFlushedMemoryEntries: max(1, config.preCompactionMemoryFlushMaxEntries)
        )
    }

    public static func resolvedIdentifierPreservationPolicy(
        config: ContextCompactionConfiguration
    ) -> ContextCompactionIdentifierPreservationPolicy {
        let mode = ContextCompactionIdentifierPreservationMode(
            rawValue: config.compactionIdentifierPreservationMode
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        ) ?? .strict
        let custom = config.compactionIdentifierPreservationCustomInstructions
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ContextCompactionIdentifierPreservationPolicy(
            mode: mode,
            customInstructions: custom.isEmpty ? nil : custom
        )
    }

    /// Rough token estimate: UTF-8 byte count divided by `charactersPerToken`, summed across the messages.
    public static func estimatedMiddleTokens(_ middle: [Message], charactersPerToken: Double) -> Int {
        estimatedTotalPromptTokens(messages: middle, charactersPerToken: charactersPerToken)
    }

    /// Total prompt token estimate over an entire outgoing payload (head + middle + tail + system).
    /// Computed identically to ``estimatedMiddleTokens`` but documented as the right helper for the
    /// proactive trigger when no real `lastPromptTokens` is available.
    public static func estimatedTotalPromptTokens(messages: [Message], charactersPerToken: Double) -> Int {
        let divisor = max(0.5, charactersPerToken)
        let raw = messages.reduce(0) { $0 + $1.content.utf8.count }
        return Int(ceil(Double(raw) / divisor))
    }

    /// Resolves the prompt-token count to use for the proactive trigger:
    /// - Returns `lastActualPromptTokens` when non-nil (real provider count from the last
    ///   successful LLM response).
    /// - Falls back to ``estimatedTotalPromptTokens`` over `messages` otherwise.
    ///
    /// Note: `lastActualPromptTokens` is a single field on `HarnessRuntimeSession` that resets on every
    /// orchestrator rebuild (model change OR conversation switch). The first turn after a switch
    /// therefore uses the estimate path. See `HarnessRuntimeSession.lastPromptTokens`.
    public static func resolvedTotalPromptTokens(
        messages: [Message],
        lastActualPromptTokens: Int?,
        charactersPerToken: Double
    ) -> Int {
        if let actual = lastActualPromptTokens {
            return actual
        }
        return estimatedTotalPromptTokens(messages: messages, charactersPerToken: charactersPerToken)
    }

    /// `model_context_window − proactiveOutputReserveTokens`, clamped to ≥ 1.
    public static func effectiveContextWindow(
        modelContextLimitTokens: Int,
        config: ContextCompactionConfiguration
    ) -> Int {
        max(1, modelContextLimitTokens - config.proactiveOutputReserveTokens)
    }

    /// Proactive trigger threshold: `effective_context_window − proactiveSafetyBufferTokens`,
    /// clamped to ≥ 1. The trigger fires when total prompt tokens strictly exceed this value.
    public static func proactiveThresholdTokens(
        modelContextLimitTokens: Int,
        config: ContextCompactionConfiguration
    ) -> Int {
        let effective = effectiveContextWindow(
            modelContextLimitTokens: modelContextLimitTokens,
            config: config
        )
        return max(1, effective - config.proactiveSafetyBufferTokens)
    }

    /// True when total prompt tokens exceed ``proactiveThresholdTokens``.
    public static func proactiveTriggerFires(
        messages: [Message],
        modelContextLimitTokens: Int,
        lastActualPromptTokens: Int?,
        config: ContextCompactionConfiguration
    ) -> Bool {
        let prompt = resolvedTotalPromptTokens(
            messages: messages,
            lastActualPromptTokens: lastActualPromptTokens,
            charactersPerToken: config.charactersPerToken
        )
        let threshold = proactiveThresholdTokens(
            modelContextLimitTokens: modelContextLimitTokens,
            config: config
        )
        return prompt > threshold
    }

    /// Context window floor for metrics on ``ContextTransformInput/effectiveContextLimitTokens``:
    /// the smaller of the agent's max context and the summarizer's configured max.
    public static func effectiveContextLimitForCompactionTrigger(
        agentContextLimitTokens: Int,
        summarizerContextLimitTokens: Int
    ) -> Int {
        max(1, min(agentContextLimitTokens, summarizerContextLimitTokens))
    }
}
