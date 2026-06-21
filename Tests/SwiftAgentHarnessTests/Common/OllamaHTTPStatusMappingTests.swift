import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("OllamaHTTPStatusMapping.validate → typed LLMError")
struct OllamaHTTPStatusMappingTests {
    private static let url = URL(string: "http://localhost:11434/api/chat")!

    private static func httpResponse(_ status: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    private static func capturedError(for status: Int) -> Error? {
        do {
            try OllamaHTTPStatusMapping.validate(httpResponse(status))
            return nil
        } catch {
            return error
        }
    }

    @Test("200 returns without throwing")
    func twoHundredOK() throws {
        try OllamaHTTPStatusMapping.validate(Self.httpResponse(200))
    }

    @Test("204 returns without throwing (any 2xx is success)")
    func twoOhFourOK() throws {
        try OllamaHTTPStatusMapping.validate(Self.httpResponse(204))
    }

    @Test("408 → LLMError.timeout")
    func fourOhEightTimeout() {
        let err = Self.capturedError(for: 408)
        guard let llm = err as? LLMError, case .timeout = llm else {
            Issue.record("Expected LLMError.timeout, got \(String(describing: err))")
            return
        }
    }

    @Test("504 → LLMError.timeout (gateway timeout)")
    func fiveOhFourTimeout() {
        let err = Self.capturedError(for: 504)
        guard let llm = err as? LLMError, case .timeout = llm else {
            Issue.record("Expected LLMError.timeout, got \(String(describing: err))")
            return
        }
    }

    @Test("429 → RetryAfterRateLimitError with nil hint by default")
    func fourTwentyNineRateLimit() {
        let err = Self.capturedError(for: 429)
        guard let rateLimited = err as? RetryAfterRateLimitError else {
            Issue.record("Expected RetryAfterRateLimitError, got \(String(describing: err))")
            return
        }
        #expect(rateLimited.retryAfterSeconds == nil)
        #expect(TransientErrorClassifier.classify(rateLimited) == .transient)
    }

    @Test("429 + Retry-After seconds surfaces retry-after hint")
    func fourTwentyNineRetryAfterSeconds() {
        do {
            try OllamaHTTPStatusMapping.validate(Self.httpResponse(429, headers: ["Retry-After": "2.5"]))
            Issue.record("Expected throw")
        } catch let error as RetryAfterRateLimitError {
            #expect(error.retryAfterSeconds == 2.5)
        } catch {
            Issue.record("Expected RetryAfterRateLimitError, got \(error)")
        }
    }

    @Test("401 → LLMError.authenticationFailed")
    func fourOhOneAuth() {
        let err = Self.capturedError(for: 401)
        guard let llm = err as? LLMError, case .authenticationFailed = llm else {
            Issue.record("Expected LLMError.authenticationFailed, got \(String(describing: err))")
            return
        }
    }

    @Test("403 → LLMError.authenticationFailed")
    func fourOhThreeAuth() {
        let err = Self.capturedError(for: 403)
        guard let llm = err as? LLMError, case .authenticationFailed = llm else {
            Issue.record("Expected LLMError.authenticationFailed, got \(String(describing: err))")
            return
        }
    }

    @Test("404 → LLMError.modelNotFound")
    func fourOhFourModelNotFound() {
        let err = Self.capturedError(for: 404)
        guard let llm = err as? LLMError, case .modelNotFound = llm else {
            Issue.record("Expected LLMError.modelNotFound, got \(String(describing: err))")
            return
        }
    }

    @Test("503 → LLMError.networkError (classifier recurses to transient)")
    func fiveOhThreeNetworkError() {
        let err = Self.capturedError(for: 503)
        guard let llm = err as? LLMError, case .networkError = llm else {
            Issue.record("Expected LLMError.networkError, got \(String(describing: err))")
            return
        }
        #expect(TransientErrorClassifier.classify(llm) == .terminal,
                "URLError(.badServerResponse) is conservatively terminal; tightening adapters reduces this case in practice")
    }

    @Test("500 → LLMError.networkError")
    func fiveHundredNetworkError() {
        let err = Self.capturedError(for: 500)
        guard let llm = err as? LLMError, case .networkError = llm else {
            Issue.record("Expected LLMError.networkError, got \(String(describing: err))")
            return
        }
    }

    @Test("400 → LLMError.invalidRequest")
    func fourHundredInvalidRequest() {
        let err = Self.capturedError(for: 400)
        guard let llm = err as? LLMError, case .invalidRequest = llm else {
            Issue.record("Expected LLMError.invalidRequest, got \(String(describing: err))")
            return
        }
    }

    @Test("Non-HTTP response → LLMError.invalidResponse")
    func nonHTTPResponse() {
        let response = URLResponse(url: Self.url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        do {
            try OllamaHTTPStatusMapping.validate(response)
            Issue.record("Expected throw")
        } catch let error as LLMError {
            guard case .invalidResponse = error else {
                Issue.record("Expected LLMError.invalidResponse, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected LLMError.invalidResponse, got \(error)")
        }
    }
}
