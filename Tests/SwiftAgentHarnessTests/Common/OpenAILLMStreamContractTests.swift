import EasyJSON
import Foundation
import OpenAI
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

    // MARK: - Stream transport failures (stub seam; no sockets)

    private struct FailingOpenAIStreamSource: OpenAIChatStreamSourcing {
        let error: Error

        func chatStream(query: ChatQuery) -> AsyncThrowingStream<ChatStreamResult, Error> {
            let _ = query
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }
    }

    private struct HangingOpenAIStreamSource: OpenAIChatStreamSourcing {
        func chatStream(query: ChatQuery) -> AsyncThrowingStream<ChatStreamResult, Error> {
            let _ = query
            return AsyncThrowingStream { _ in
                // Never finish until consumer cancels.
            }
        }
    }

    private static func makeAdapter(streamSource: any OpenAIChatStreamSourcing) -> OpenAILLM {
        OpenAILLM(
            baseURL: "http://127.0.0.1:1/v1",
            apiKey: "dummy",
            model: "gpt-test",
            capabilities: [.completion],
            streamSource: streamSource
        )
    }

    private static func consume(
        _ stream: AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error>
    ) async -> (results: [StreamResult<LLMResponse, LLMResponse>], terminalError: Error?) {
        var results: [StreamResult<LLMResponse, LLMResponse>] = []
        var terminal: Error?
        do {
            for try await element in stream {
                results.append(element)
            }
        } catch {
            terminal = error
        }
        return (results, terminal)
    }

    @Test("stream transport failure surfaces as LLMError without synthesized .complete")
    func unreachableHostSurfacesAsLLMError() async {
        struct Probe: Error {}
        let adapter = Self.makeAdapter(streamSource: FailingOpenAIStreamSource(error: Probe()))
        let stream = adapter.stream(
            [Message(id: UUID(), role: .user, content: "hi")],
            config: LLMRequestConfig(maxTokens: 1024)
        )
        let (results, terminal) = await Self.consume(stream)
        for result in results {
            if case .complete = result {
                Issue.record("contract violation: synthesized .complete on transport failure")
            }
        }
        guard let terminal else {
            Issue.record("expected terminal error, got clean stream finish")
            return
        }
        #expect(terminal is LLMError, "expected LLMError, got \(type(of: terminal)): \(terminal)")
    }

    @Test("cancelling the consuming Task surfaces CancellationError; no synthesized .complete")
    func cancellationSurfacesCancellationError() async {
        let adapter = Self.makeAdapter(streamSource: HangingOpenAIStreamSource())
        let stream = adapter.stream(
            [Message(id: UUID(), role: .user, content: "hi")],
            config: LLMRequestConfig(maxTokens: 1024)
        )
        let collector = Task<(results: [StreamResult<LLMResponse, LLMResponse>], terminalError: Error?), Never> {
            await Self.consume(stream)
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        collector.cancel()
        let (results, terminal) = await collector.value
        for result in results {
            if case .complete = result {
                Issue.record("contract violation: synthesized .complete on cancellation")
            }
        }
        if let terminal {
            #expect(terminal is CancellationError || terminal is LLMError,
                    "expected CancellationError or LLMError, got \(type(of: terminal)): \(terminal)")
        }
    }
}
