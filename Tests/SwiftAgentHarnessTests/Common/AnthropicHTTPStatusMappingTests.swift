import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Anthropic HTTP status mapping")
struct AnthropicHTTPStatusMappingTests {
    private static func httpResponse(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/v1/messages")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: [:]
        )!
    }

    private static func capturedError(for status: Int) -> Error? {
        do {
            try AnthropicErrorMapping.validate(Self.httpResponse(status), body: Data("err".utf8))
            return nil
        } catch {
            return error
        }
    }

    @Test("200 returns without throwing")
    func twoHundredOK() throws {
        try AnthropicErrorMapping.validate(Self.httpResponse(200), body: nil)
    }

    @Test("408 → LLMError.timeout")
    func fourOhEightTimeout() {
        guard let error = Self.capturedError(for: 408) as? LLMError else {
            Issue.record("expected LLMError")
            return
        }
        if case .timeout = error { } else { Issue.record("expected timeout, got \(error)") }
    }

    @Test("504 → LLMError.timeout")
    func fiveOhFourTimeout() {
        guard let error = Self.capturedError(for: 504) as? LLMError else {
            Issue.record("expected LLMError")
            return
        }
        if case .timeout = error { } else { Issue.record("expected timeout, got \(error)") }
    }

    @Test("429 → LLMError.rateLimitExceeded")
    func fourTwentyNineRateLimit() {
        guard let error = Self.capturedError(for: 429) as? LLMError else {
            Issue.record("expected LLMError")
            return
        }
        if case .rateLimitExceeded = error { } else { Issue.record("expected rateLimitExceeded, got \(error)") }
    }

    @Test("401 → LLMError.authenticationFailed")
    func fourOhOneAuth() {
        guard let error = Self.capturedError(for: 401) as? LLMError else {
            Issue.record("expected LLMError")
            return
        }
        if case .authenticationFailed = error { } else { Issue.record("expected authenticationFailed, got \(error)") }
    }

    @Test("403 → LLMError.authenticationFailed")
    func fourOhThreeAuth() {
        guard let error = Self.capturedError(for: 403) as? LLMError else {
            Issue.record("expected LLMError")
            return
        }
        if case .authenticationFailed = error { } else { Issue.record("expected authenticationFailed, got \(error)") }
    }

    @Test("404 → LLMError.modelNotFound")
    func fourOhFourModelNotFound() {
        guard let error = Self.capturedError(for: 404) as? LLMError else {
            Issue.record("expected LLMError")
            return
        }
        if case .modelNotFound = error { } else { Issue.record("expected modelNotFound, got \(error)") }
    }

    @Test("500 → LLMError.networkError")
    func fiveHundredNetworkError() {
        guard let error = Self.capturedError(for: 500) as? LLMError else {
            Issue.record("expected LLMError")
            return
        }
        if case .networkError = error { } else { Issue.record("expected networkError, got \(error)") }
    }

    @Test("400 → LLMError.invalidRequest")
    func fourHundredInvalidRequest() {
        guard let error = Self.capturedError(for: 400) as? LLMError else {
            Issue.record("expected LLMError")
            return
        }
        if case .invalidRequest = error { } else { Issue.record("expected invalidRequest, got \(error)") }
    }

    @Test("Non-HTTP response → LLMError.invalidResponse")
    func nonHTTPResponse() {
        do {
            try AnthropicErrorMapping.validate(URLResponse(), body: nil)
            Issue.record("expected throw")
        } catch let error as LLMError {
            if case .invalidResponse = error { } else { Issue.record("expected invalidResponse, got \(error)") }
        } catch {
            Issue.record("expected LLMError, got \(error)")
        }
    }

    @Test("sseErrorEvent maps to invalidResponse")
    func sseErrorEventMaps() {
        let error = AnthropicErrorMapping.sseErrorEvent(message: "boom")
        if case .invalidResponse(let message) = error {
            #expect(message.contains("boom"))
        } else {
            Issue.record("expected invalidResponse, got \(error)")
        }
    }
}
