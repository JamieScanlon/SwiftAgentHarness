import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

enum AdapterContractValidator {
    static func assertSingleComplete(
        results: [StreamResult<LLMResponse, LLMResponse>]
    ) -> LLMResponse? {
        let completes = results.compactMap { result -> LLMResponse? in
            if case .complete(let value) = result { return value }
            return nil
        }
        guard completes.count == 1 else { return nil }
        return completes[0]
    }

    static func streamChunksUseKnownFragments(
        results: [StreamResult<LLMResponse, LLMResponse>]
    ) -> Bool {
        for result in results {
            guard case .stream(let chunk) = result else { continue }
            if chunk.content.isEmpty, chunk.streamingFragment == nil, chunk.toolCalls.isEmpty {
                continue
            }
            if let fragment = chunk.streamingFragment {
                switch fragment {
                case .text, .reasoning, .toolCall, .toolCallStarted, .toolCallCompleted:
                    continue
                }
            }
            if !chunk.content.isEmpty {
                continue
            }
            if !chunk.toolCalls.isEmpty {
                continue
            }
            return false
        }
        return true
    }
}

@Suite("Adapter contract validator helper")
struct AdapterContractValidatorTests {
    @Test("validator detects single complete invariant")
    func singleCompleteInvariant() {
        let results: [StreamResult<LLMResponse, LLMResponse>] = [
            .stream(LLMResponse(content: "a", toolCalls: [])),
            .complete(LLMResponse(content: "a", toolCalls: [])),
        ]
        let complete = AdapterContractValidator.assertSingleComplete(results: results)
        #expect(complete?.content == "a")
    }

    @Test("validator accepts reasoning fragments on stream chunks")
    func reasoningFragmentChunks() {
        let results: [StreamResult<LLMResponse, LLMResponse>] = [
            .stream(LLMResponse.streamChunk("", streamingFragment: .reasoning("think"))),
            .complete(LLMResponse(content: "done", toolCalls: [])),
        ]
        #expect(AdapterContractValidator.streamChunksUseKnownFragments(results: results))
    }
}
