import Foundation

/// Feature-flag bundle for Phase 6 behaviors (default: off / no-op).
public struct ModelPoolAdvancedConfiguration: Sendable {
    public var budget: BudgetPolicy
    public var failover: FailoverPolicy
    public var promptCache: PromptCachePolicy
    public var responseCache: ResponseCachePolicy
    public var substitution: ModelSubstitutionPolicy

    public init(
        budget: BudgetPolicy = ModelPoolBudgetConfiguration.safeDefaults.resolvedPolicy(),
        failover: FailoverPolicy = ModelPoolFailoverConfiguration.specDefaults.resolvedPolicy(),
        promptCache: PromptCachePolicy = .disabled,
        responseCache: ResponseCachePolicy = .disabled,
        substitution: ModelSubstitutionPolicy = .disabled
    ) {
        self.budget = budget
        self.failover = failover
        self.promptCache = promptCache
        self.responseCache = responseCache
        self.substitution = substitution
    }
}

public enum BudgetPolicy: Sendable {
    public enum ProjectedCostFallback: Sendable {
        /// Allow calls when projected cost is unknown (`projectedCostUSD == nil`).
        case allowWhenUnknown
        /// Deny calls when projected cost is unknown.
        case denyWhenUnknown
    }

    /// No spend tracking or rejection.
    case disabled
    /// Enforced budget caps at dispatch/settlement.
    ///
    /// - Parameters:
    ///   - maxUSDPerCall: Reject when projected single-call cost would exceed this cap.
    ///   - maxUSDPerConversation: Reject when conversation cumulative + projected spend exceeds this cap.
    ///   - maxUSDGlobal: Reject when global cumulative + projected spend exceeds this cap.
    ///   - maxUSDPerAccount: Reject when account cumulative + projected spend exceeds this cap.
    ///   - projectedCostFallback: Behavior when projected cost is unavailable.
    case enabled(
        maxUSDPerCall: Double?,
        maxUSDPerConversation: Double?,
        maxUSDGlobal: Double? = nil,
        maxUSDPerAccount: Double? = nil,
        projectedCostFallback: ProjectedCostFallback = .allowWhenUnknown
    )
}

public struct FailoverPolicy: Sendable {
    /// Maximum number of retry attempts after the initial call. When `> 0`, identical-binding
    /// retries are applied for transient failures (classified by ``TransientErrorClassifier``).
    /// `0` (default) preserves today's behavior: ``StandardModelLLMFactory`` skips
    /// ``RetryingLLM`` entirely, so neither backoff nor pre-first-chunk stream gating apply.
    public var maxRetries: Int
    /// Initial backoff delay before the second attempt. Doubled per attempt up to ``maxDelay``.
    public var baseDelay: TimeInterval
    /// Hard cap for any per-attempt sleep (after exponential growth + jitter).
    public var maxDelay: TimeInterval
    /// Random ± fraction applied to each delay (e.g. `0.25` multiplies the computed delay
    /// by a uniform draw from `[0.75, 1.25]`). Clamped to `[0, 1]`. `0` disables jitter.
    public var jitterFraction: Double
    public var rotationStrategy: AuthProfileRotationStrategy
    public var billingCooldown: TimeInterval
    public var rateLimitCooldown: TimeInterval

    public init(
        maxRetries: Int = 0,
        baseDelay: TimeInterval = 0.25,
        maxDelay: TimeInterval = 8.0,
        jitterFraction: Double = 0.25,
        rotationStrategy: AuthProfileRotationStrategy = .fillFirst,
        billingCooldown: TimeInterval = 3600,
        rateLimitCooldown: TimeInterval = 900
    ) {
        self.maxRetries = max(0, maxRetries)
        self.baseDelay = max(0, baseDelay)
        self.maxDelay = max(0, maxDelay)
        self.jitterFraction = max(0, min(1, jitterFraction))
        self.rotationStrategy = rotationStrategy
        self.billingCooldown = billingCooldown
        self.rateLimitCooldown = rateLimitCooldown
    }
}

public enum ResponseCachePolicy: Sendable {
    case disabled
    /// Opt-in idempotent response cache (future).
    case enabled(
        maxEntries: Int,
        ttlSeconds: Double? = nil,
        stablePrefixMessageCount: Int? = nil
    )
}
