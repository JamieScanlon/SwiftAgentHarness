import Foundation

public enum ContextPruningMode: String, Sendable, Equatable {
    case off
    case cacheTTL
}

public struct ContextPruningPolicy: Sendable, Equatable {
    public let mode: ContextPruningMode
    public let ttlSeconds: Double?
    public let keepRecentToolResults: Int
    public let targetTools: Set<String>?

    public init(
        mode: ContextPruningMode,
        ttlSeconds: Double?,
        keepRecentToolResults: Int,
        targetTools: Set<String>?
    ) {
        self.mode = mode
        self.ttlSeconds = ttlSeconds
        self.keepRecentToolResults = keepRecentToolResults
        self.targetTools = targetTools
    }
}

public enum ContextPruningPolicyResolver: Sendable {
    public static func resolve(
        config: ContextCompactionConfiguration,
        providerEligibility: ProviderCacheTTLEligibility = .none
    ) -> ContextPruningPolicy {
        let mode = resolvedMode(config: config)
        let ttl = resolvedTTLSeconds(config: config, providerEligibility: providerEligibility)
        let effectiveMode: ContextPruningMode
        if mode == .cacheTTL, let ttl, ttl > 0 {
            effectiveMode = .cacheTTL
        } else if mode == .cacheTTL {
            effectiveMode = .off
        } else {
            effectiveMode = mode
        }
        let targetTools: Set<String>? = {
            guard let names = config.contextPruningTargetTools, !names.isEmpty else { return nil }
            return Set(names)
        }()
        return ContextPruningPolicy(
            mode: effectiveMode,
            ttlSeconds: effectiveMode == .cacheTTL ? ttl : nil,
            keepRecentToolResults: max(0, config.contextPruningKeepRecentToolResults),
            targetTools: targetTools
        )
    }

    private static func resolvedMode(config: ContextCompactionConfiguration) -> ContextPruningMode {
        if let raw = config.contextPruningMode?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let mode = ContextPruningMode(rawValue: raw) {
            return mode
        }
        return config.cacheAwarePruningEnabled ? .cacheTTL : .off
    }

    private static func resolvedTTLSeconds(
        config: ContextCompactionConfiguration,
        providerEligibility: ProviderCacheTTLEligibility
    ) -> Double? {
        if let ttl = config.cachePruningTTLSeconds, ttl > 0 {
            return ttl
        }
        switch providerEligibility {
        case .short:
            return 300
        case .long:
            return 3600
        case .none:
            return nil
        }
    }
}
