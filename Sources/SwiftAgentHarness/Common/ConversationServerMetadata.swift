import Foundation

/// Server-derived data for a conversation, delivered by `GET /api/conversations/:id/server-metadata`. Not persisted in `ModelConversation`; safe to request alongside the main conversation resource.
public struct ConversationServerMetadata: Codable, Sendable, Equatable {
    public var contextCompactionGating: ContextCompactionGatingResponse

    public init(contextCompactionGating: ContextCompactionGatingResponse) {
        self.contextCompactionGating = contextCompactionGating
    }
}

/// Token gate and transform flags for context compaction; clients estimate total prompt tokens from messages with ``ContextCompactionGatingResponse/charactersPerToken`` and compare to ``proactiveThresholdTokens``.
public struct ContextCompactionGatingResponse: Codable, Sendable, Equatable {
    /// Proactive trigger threshold: `model_context_window − proactiveOutputReserveTokens − proactiveSafetyBufferTokens`.
    public var proactiveThresholdTokens: Int
    public var charactersPerToken: Double
    /// Agent model context window used to compute the proactive threshold.
    public var modelContextLimitTokens: Int
    /// `PromptConfig` per-mode `enableContextTransform`. When false, compaction preview no-ops with `context_transform_disabled`.
    public var enableContextTransform: Bool
    /// `contextCompaction.enabled` in server transform config; global compaction feature flag.
    public var contextCompactionConfigEnabled: Bool

    public init(
        proactiveThresholdTokens: Int,
        charactersPerToken: Double,
        modelContextLimitTokens: Int,
        enableContextTransform: Bool = true,
        contextCompactionConfigEnabled: Bool = true
    ) {
        self.proactiveThresholdTokens = proactiveThresholdTokens
        self.charactersPerToken = charactersPerToken
        self.modelContextLimitTokens = modelContextLimitTokens
        self.enableContextTransform = enableContextTransform
        self.contextCompactionConfigEnabled = contextCompactionConfigEnabled
    }
}
