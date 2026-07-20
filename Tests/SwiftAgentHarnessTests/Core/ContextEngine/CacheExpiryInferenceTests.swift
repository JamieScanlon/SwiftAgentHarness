import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Cache expiry inference")
struct CacheExpiryInferenceTests {
    private let referenceInstant = Date(timeIntervalSince1970: 1_700_000_000)
    private let threshold: Double = 9000

    @Test("Expired when gap meets threshold")
    func expiredAtThreshold() {
        let lastRequest = referenceInstant.addingTimeInterval(-threshold)
        #expect(
            CacheExpiryInference.isCacheExpired(
                lastModelRequestAt: lastRequest,
                referenceInstant: referenceInstant,
                providerEligibility: .short,
                thresholdSeconds: threshold
            )
        )
    }

    @Test("Not expired below threshold")
    func notExpiredBelowThreshold() {
        let lastRequest = referenceInstant.addingTimeInterval(-(threshold - 1))
        #expect(
            !CacheExpiryInference.isCacheExpired(
                lastModelRequestAt: lastRequest,
                referenceInstant: referenceInstant,
                providerEligibility: .short,
                thresholdSeconds: threshold
            )
        )
    }

    @Test("Quiesces when provider reports no cache TTL")
    func quiescesOnNoneEligibility() {
        let lastRequest = referenceInstant.addingTimeInterval(-threshold * 10)
        #expect(
            !CacheExpiryInference.isCacheExpired(
                lastModelRequestAt: lastRequest,
                referenceInstant: referenceInstant,
                providerEligibility: .none,
                thresholdSeconds: threshold
            )
        )
    }

    @Test("Nil lastModelRequestAt is not expired")
    func nilLastRequest() {
        #expect(
            !CacheExpiryInference.isCacheExpired(
                lastModelRequestAt: nil,
                referenceInstant: referenceInstant,
                providerEligibility: .short,
                thresholdSeconds: threshold
            )
        )
    }

    @Test("Resolved threshold uses default when config unset")
    func resolvedDefaultThreshold() {
        var config = ContextCompactionConfiguration.default
        config.cacheExpiryInferenceThresholdSeconds = nil
        #expect(
            CacheExpiryInference.resolvedThresholdSeconds(
                config: config,
                providerEligibility: .short
            ) == CacheExpiryInference.defaultThresholdSeconds
        )
    }

    @Test("Resolved threshold honors config override")
    func resolvedConfigOverride() {
        var config = ContextCompactionConfiguration.default
        config.cacheExpiryInferenceThresholdSeconds = 12_000
        #expect(
            CacheExpiryInference.resolvedThresholdSeconds(
                config: config,
                providerEligibility: .long
            ) == 12_000
        )
    }

    @Test("Resolved threshold nil when provider has no cache")
    func resolvedNilForNoneEligibility() {
        #expect(
            CacheExpiryInference.resolvedThresholdSeconds(
                config: .default,
                providerEligibility: .none
            ) == nil
        )
    }
}
