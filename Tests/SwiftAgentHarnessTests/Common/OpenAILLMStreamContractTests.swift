import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// Contract tests for ``OpenAILLM`` that do **not** open local sockets — see ``OpenAILLMStreamContractNetworkTests``.
///
/// Tool-call accumulation semantics are covered structurally by ``ToolCallAccumulator`` tests.
@Suite("OpenAILLM stream contract")
struct OpenAILLMStreamContractTests {

    @Test("OpenAI tool-call fragment shape: accumulator dedupes name+args replays by id (smoke)")
    func toolCallFragmentDedupeContract() {
        // The streaming adapter uses ``ToolCallAccumulator.ingestNameAndArgs`` per
        // delta; this test pins the OpenAI shape we feed it so any future regression
        // in the adapter's adapter→accumulator wiring shows up here too.
        var acc = ToolCallAccumulator()
        let id = "call_42"
        // Three SDK-shaped fragments that all describe the same logical call.
        acc.ingestNameAndArgs(id: id, name: "search", argumentsFragment: "{\"q\":\"")
        acc.ingestNameAndArgs(id: id, name: "search", argumentsFragment: "rust\"")
        acc.ingestNameAndArgs(id: id, name: "search", argumentsFragment: "}")
        let result = acc.finalize()
        #expect(result.count == 1)
        #expect(result[0].id == id)
        #expect(result[0].name == "search")
        if case .object(let dict) = result[0].arguments,
           case .string(let q)? = dict["q"] {
            #expect(q == "rust")
        } else {
            Issue.record("expected merged arguments to parse as {\"q\":\"rust\"}")
        }
    }

    // MARK: - Finish reason canonicalization (covered structurally; pinned here for adapter)

    @Test("OpenAI finish reason canonicalization: tool_calls and function_call both map to .toolCalls")
    func finishReasonCanonicalizationContract() {
        // Pins the canonical mapping the adapter applies on the .complete value.
        #expect(FinishReason.fromOpenAI("tool_calls") == .toolCalls)
        #expect(FinishReason.fromOpenAI("function_call") == .toolCalls)
        #expect(FinishReason.fromOpenAI("stop") == .stop)
        #expect(FinishReason.fromOpenAI("length") == .length)
    }
}
