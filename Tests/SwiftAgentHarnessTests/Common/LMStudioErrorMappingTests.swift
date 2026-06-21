import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("LMStudioErrorMapping (typed LLMError replaces NSError(domain: LMStudioLLM))")
struct LMStudioErrorMappingTests {

    @Test("requestEncodingFailure maps to LLMError.invalidRequest with underlying message")
    func requestEncodingFailureMapsToInvalidRequest() {
        struct Underlying: LocalizedError {
            var errorDescription: String? { "encode failed" }
        }
        let mapped = LMStudioErrorMapping.requestEncodingFailure(Underlying())
        switch mapped {
        case .invalidRequest(let message):
            #expect(message.contains("LM Studio request encoding failure"))
            #expect(message.contains("encode failed"))
        default:
            Issue.record("expected .invalidRequest, got \(mapped)")
        }
    }

    @Test("sseErrorEvent maps to LLMError.invalidResponse with surfaced message")
    func sseErrorEventMapsToInvalidResponse() {
        let mapped = LMStudioErrorMapping.sseErrorEvent(message: "model overloaded")
        switch mapped {
        case .invalidResponse(let message):
            #expect(message.contains("LM Studio SSE error"))
            #expect(message.contains("model overloaded"))
        default:
            Issue.record("expected .invalidResponse, got \(mapped)")
        }
    }

    @Test("noValidChoices(0) maps to LLMError.invalidResponse for empty stream")
    func noValidChoicesZeroChunks() {
        let mapped = LMStudioErrorMapping.noValidChoices(chunkCount: 0)
        switch mapped {
        case .invalidResponse(let message):
            #expect(message.contains("LM Studio stream ended without receiving any data chunks"))
        default:
            Issue.record("expected .invalidResponse, got \(mapped)")
        }
    }

    @Test("noValidChoices(>0) maps to LLMError.invalidResponse with chunk count in message")
    func noValidChoicesNonZero() {
        let mapped = LMStudioErrorMapping.noValidChoices(chunkCount: 7)
        switch mapped {
        case .invalidResponse(let message):
            #expect(message.contains("LM Studio stream ended after 7 chunks"))
            #expect(message.contains("none contained valid choices"))
        default:
            Issue.record("expected .invalidResponse, got \(mapped)")
        }
    }

    @Test("map(_:) passes LLMError instances through unchanged")
    func mapPassesThroughLLMError() {
        let original = LLMError.timeout
        let mapped = LMStudioErrorMapping.map(original)
        switch mapped {
        case .timeout: break
        default: Issue.record("expected .timeout, got \(mapped)")
        }
    }

    @Test("map(_:) wraps unknown errors as LLMError.networkError(_:)")
    func mapWrapsUnknownAsNetworkError() {
        struct CustomError: Error {}
        let mapped = LMStudioErrorMapping.map(CustomError())
        switch mapped {
        case .networkError: break
        default: Issue.record("expected .networkError, got \(mapped)")
        }
    }
}
