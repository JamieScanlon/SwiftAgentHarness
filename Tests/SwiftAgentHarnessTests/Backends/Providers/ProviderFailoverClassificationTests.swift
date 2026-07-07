import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ProviderFailoverClassification")
struct ProviderFailoverClassificationTests {
    @Test("Credential exhausted maps to rotate hint")
    func credentialExhaustedHints() {
        let hints = ProviderFailoverRecoveryHints.hints(for: .credentialExhausted)
        #expect(hints.shouldRotateCredential)
    }

    @Test("LLMError quota exceeded classifies as credential-exhausted")
    func llmQuotaExceeded() {
        #expect(DefaultProviderFailoverClassifier.classify(LLMError.quotaExceeded) == .credentialExhausted)
    }

    @Test("Insufficient credits message classifies as credential-exhausted")
    func insufficientCreditsMessage() {
        struct BillingError: Error, CustomStringConvertible {
            var description: String { "HTTP 402 insufficient credits" }
        }
        #expect(DefaultProviderFailoverClassifier.classify(BillingError()) == .credentialExhausted)
    }

    @Test("Rate limit maps to rotate + fallback hints")
    func rateLimitHints() {
        let hints = ProviderFailoverRecoveryHints.hints(for: .rateLimited)
        #expect(hints.shouldRotateCredential)
        #expect(hints.shouldFallback)
    }

    @Test("Context overflow suggests compression")
    func contextOverflowHints() {
        let hints = ProviderFailoverRecoveryHints.hints(for: .contextOverflow)
        #expect(hints.shouldCompress)
    }

    @Test("LLMError rate limit classifies as rate-limited")
    func llmRateLimit() {
        #expect(DefaultProviderFailoverClassifier.classify(LLMError.rateLimitExceeded) == .rateLimited)
    }

    @Test("LLMError auth failure classifies as auth-error")
    func llmAuthError() {
        #expect(DefaultProviderFailoverClassifier.classify(LLMError.authenticationFailed) == .authError)
    }

    @Test("Binding bridge maps transient to tryNextBinding")
    func bindingBridgeTransient() {
        #expect(ProviderFailoverBridge.bindingDecision(for: .transient) == .tryNextBinding)
        #expect(ProviderFailoverBridge.bindingDecision(for: .permanent) == .terminal)
    }
}
