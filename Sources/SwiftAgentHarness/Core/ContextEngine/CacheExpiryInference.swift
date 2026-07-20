import Foundation

enum CacheExpiryInference: Sendable {
    /// Default idle threshold before inferring the provider prompt cache is dead (2.5 hours).
    static let defaultThresholdSeconds: Double = 9000

    static func isCacheExpired(
        lastModelRequestAt: Date?,
        referenceInstant: Date,
        providerEligibility: ProviderCacheTTLEligibility,
        thresholdSeconds: Double
    ) -> Bool {
        guard providerEligibility != .none else { return false }
        guard let lastModelRequestAt else { return false }
        guard thresholdSeconds > 0 else { return false }
        return referenceInstant.timeIntervalSince(lastModelRequestAt) >= thresholdSeconds
    }

    static func resolvedThresholdSeconds(
        config: ContextCompactionConfiguration,
        providerEligibility: ProviderCacheTTLEligibility
    ) -> Double? {
        guard providerEligibility != .none else { return nil }
        if let configured = config.cacheExpiryInferenceThresholdSeconds, configured > 0 {
            return configured
        }
        return defaultThresholdSeconds
    }
}
