import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// Loopback/OpenAI-client transport probes for ``OpenAILLM``. Local-only sockets — no LLM server.
enum OpenAILLMStreamContractNetworkTests {

    private static func makeAdapter(
        baseURL: String = "http://127.0.0.1:1/v1"
    ) -> OpenAILLM {
        OpenAILLM(
            baseURL: baseURL,
            apiKey: "dummy",
            model: "gpt-test",
            capabilities: [.completion]
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

    @Test("stream against unreachable host surfaces as typed LLMError (networkError or contract case)")
    static func unreachableHostSurfacesAsLLMError() async throws {
        let adapter = Self.makeAdapter()
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
    static func cancellationSurfacesCancellationError() async {
        let adapter = Self.makeAdapter()
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
