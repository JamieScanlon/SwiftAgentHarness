import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("TransientErrorClassifier")
struct TransientErrorClassifierTests {

    // MARK: - LLMError direct cases

    @Test("rateLimitExceeded is transient")
    func rateLimit() {
        #expect(TransientErrorClassifier.classify(LLMError.rateLimitExceeded) == .transient)
    }

    @Test("timeout is transient")
    func timeout() {
        #expect(TransientErrorClassifier.classify(LLMError.timeout) == .transient)
    }

    @Test("invalidRequest is terminal")
    func invalidRequest() {
        #expect(TransientErrorClassifier.classify(LLMError.invalidRequest("bad")) == .terminal)
    }

    @Test("quotaExceeded is terminal (caller has no budget)")
    func quotaExceeded() {
        #expect(TransientErrorClassifier.classify(LLMError.quotaExceeded) == .terminal)
    }

    @Test("modelNotFound is terminal")
    func modelNotFound() {
        #expect(TransientErrorClassifier.classify(LLMError.modelNotFound("x")) == .terminal)
    }

    @Test("authenticationFailed is terminal")
    func authenticationFailed() {
        #expect(TransientErrorClassifier.classify(LLMError.authenticationFailed) == .terminal)
    }

    @Test("invalidResponse is terminal")
    func invalidResponse() {
        #expect(TransientErrorClassifier.classify(LLMError.invalidResponse("nope")) == .terminal)
    }

    @Test("unsupportedCapability is terminal")
    func unsupportedCapability() {
        #expect(TransientErrorClassifier.classify(LLMError.unsupportedCapability(.completion)) == .terminal)
    }

    @Test("unknown is terminal")
    func unknownLLMError() {
        let inner = NSError(domain: "x", code: 1)
        #expect(TransientErrorClassifier.classify(LLMError.unknown(inner)) == .terminal)
    }

    @Test("queueFull / queueTimeout are terminal")
    func queueErrors() {
        #expect(TransientErrorClassifier.classify(LLMError.queueFull) == .terminal)
        #expect(TransientErrorClassifier.classify(LLMError.queueTimeout) == .terminal)
    }

    @Test("imageGenerationError is terminal")
    func imageGenerationError() {
        let err = LLMError.imageGenerationError(.invalidPrompt("empty"))
        #expect(TransientErrorClassifier.classify(err) == .terminal)
    }

    // MARK: - LLMError.networkError recursion

    @Test("networkError(URLError.timedOut) recurses to transient")
    func networkErrorRecursesTransient() {
        let wrapped = LLMError.networkError(URLError(.timedOut))
        #expect(TransientErrorClassifier.classify(wrapped) == .transient)
    }

    @Test("networkError(URLError.cancelled) recurses to terminal (don't retry user cancels)")
    func networkErrorRecursesCancelled() {
        let wrapped = LLMError.networkError(URLError(.cancelled))
        #expect(TransientErrorClassifier.classify(wrapped) == .terminal)
    }

    @Test("networkError(LLMError.authenticationFailed) recurses to terminal")
    func networkErrorRecursesNestedLLM() {
        let wrapped = LLMError.networkError(LLMError.authenticationFailed)
        #expect(TransientErrorClassifier.classify(wrapped) == .terminal)
    }

    @Test("networkError(NSError) is terminal (unknown shape)")
    func networkErrorRecursesUnknown() {
        let wrapped = LLMError.networkError(NSError(domain: "x", code: 1))
        #expect(TransientErrorClassifier.classify(wrapped) == .terminal)
    }

    @Test("RetryAfterRateLimitError is transient and exposes retry-after")
    func retryAfterHint() {
        let err = RetryAfterRateLimitError(retryAfterSeconds: 2.5)
        #expect(TransientErrorClassifier.classify(err) == .transient)
        #expect(TransientErrorClassifier.retryAfterSeconds(err) == 2.5)
        #expect(TransientErrorClassifier.isRateLimited(err))
    }

    @Test("retry-after hint recurses through networkError wrappers")
    func retryAfterRecursionThroughNetworkError() {
        let err = LLMError.networkError(RetryAfterRateLimitError(retryAfterSeconds: 1.25))
        #expect(TransientErrorClassifier.retryAfterSeconds(err) == 1.25)
        #expect(TransientErrorClassifier.isRateLimited(err))
    }

    // MARK: - URLError direct cases

    @Test("URLError.timedOut is transient")
    func urlTimedOut() {
        #expect(TransientErrorClassifier.classify(URLError(.timedOut)) == .transient)
    }

    @Test("URLError network families are transient")
    func urlNetworkFamilies() {
        let codes: [URLError.Code] = [
            .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
            .notConnectedToInternet, .dnsLookupFailed, .resourceUnavailable,
            .internationalRoamingOff
        ]
        for code in codes {
            #expect(TransientErrorClassifier.classify(URLError(code)) == .transient,
                    "URLError(.\(code)) should be transient")
        }
    }

    @Test("URLError.cancelled is terminal")
    func urlCancelled() {
        #expect(TransientErrorClassifier.classify(URLError(.cancelled)) == .terminal)
    }

    @Test("URLError.badServerResponse is terminal (conservative; tightened OllamaLLM rarely emits it)")
    func urlBadServerResponse() {
        #expect(TransientErrorClassifier.classify(URLError(.badServerResponse)) == .terminal)
    }

    // MARK: - Cancellation and unknown

    @Test("CancellationError is terminal — never retry a cancelled call")
    func cancellation() {
        #expect(TransientErrorClassifier.classify(CancellationError()) == .terminal)
    }

    @Test("Bare NSError is terminal")
    func unknownNSError() {
        let err = NSError(domain: "Anything", code: 42)
        #expect(TransientErrorClassifier.classify(err) == .terminal)
    }
}
