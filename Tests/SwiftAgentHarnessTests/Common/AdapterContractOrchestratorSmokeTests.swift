import EasyJSON
import Foundation
import Logging
import OllamaKit
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// End-to-end smoke tests confirming each refactored adapter still drives the
/// orchestrator's lifecycle phases (`connecting` → `streaming` → `done`) on the
/// success path, with no extra `.errored` introduced by the contract refactor.
///
/// Adapters are wrapped in ``LifecycleReportingLLM`` (the same lifecycle layer
/// `StandardModelLLMFactory` would produce, minus the budget / retry wrappers
/// that are orthogonal to this contract) and driven via the per-adapter test
/// seams (``OllamaChatStreamSourcing`` for Ollama, ``LMStudioStreamSourcing``
/// for LM Studio). OpenAI relies on the live `OpenAI` client, so its smoke
/// row is covered by the unreachable-host failure path in
/// ``OpenAILLMStreamContractTests`` (verifying the typed-error contract).
@Suite("Adapter contract orchestrator smoke (lifecycle phases preserved)")
struct AdapterContractOrchestratorSmokeTests {

    private actor PhaseRecorder {
        private(set) var phases: [ModelInvocationPhase] = []
        func append(_ phase: ModelInvocationPhase) { phases.append(phase) }
    }

    // MARK: - Stub adapters (per the existing per-adapter test seams)

    private struct ScriptedOllamaSource: OllamaChatStreamSourcing {
        let chunks: [OllamaChatStreamChunk]
        func chatStream(
            baseURL: URL,
            requestData: OKChatRequestData,
            timeout: TimeInterval?,
            logger: Logger?
        ) -> AsyncThrowingStream<OllamaChatStreamChunk, Error> {
            let chunks = self.chunks
            return AsyncThrowingStream { continuation in
                Task {
                    for chunk in chunks {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                }
            }
        }
    }

    private struct ScriptedLMStudioSource: LMStudioStreamSourcing {
        let payloads: [[String: any Sendable]]
        func sseStream(
            baseURL: URL,
            endpoint: String,
            parameters: [String: any Sendable],
            sseTimeoutInterval: TimeInterval,
            logger: Logger?
        ) async -> AsyncStream<[String: any Sendable]> {
            let payloads = self.payloads
            return AsyncStream { continuation in
                Task {
                    for payload in payloads {
                        continuation.yield(payload)
                    }
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Helpers

    private func consume(
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

    private func ollamaChunk(fromJSON json: String) throws -> OllamaChatStreamChunk {
        let data = Data(json.utf8)
        return try OllamaChatStreamSupport.jsonDecoderForChunks().decode(OllamaChatStreamChunk.self, from: data)
    }

    private func makeOllama(streamSource: any OllamaChatStreamSourcing) async throws -> OllamaLLM {
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
        return OllamaLLM(
            model: "test-model",
            serverURL: URL(string: "http://localhost:11434")!,
            capabilities: [.completion],
            systemPrompt: prompt,
            requestTimeoutInterval: nil,
            logger: nil,
            streamSource: streamSource
        )
    }

    private func makeLMStudio(streamSource: any LMStudioStreamSourcing) async throws -> LMStudioLLM {
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
        return LMStudioLLM(
            model: "test-model",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            systemPrompt: prompt,
            logger: nil,
            streamSource: streamSource
        )
    }

    // MARK: - Ollama success path

    @Test("OllamaLLM stream success records connecting → streaming → done with no .errored")
    func ollamaStreamSuccessPhases() async throws {
        let chunkA = try ollamaChunk(fromJSON: """
        {"model":"test-model","createdAt":"2025-01-01T00:00:00Z","message":{"role":"assistant","content":"hello "},"done":false}
        """)
        let chunkB = try ollamaChunk(fromJSON: """
        {"model":"test-model","createdAt":"2025-01-01T00:00:01Z","message":{"role":"assistant","content":"world"},"done":false}
        """)
        let done = try ollamaChunk(fromJSON: """
        {"model":"test-model","createdAt":"2025-01-01T00:00:02Z","message":{"role":"assistant","content":""},"done":true,"doneReason":"stop"}
        """)

        let adapter = try await makeOllama(
            streamSource: ScriptedOllamaSource(chunks: [chunkA, chunkB, done])
        )
        let recorder = PhaseRecorder()
        let coordinator = ModelInvocationCoordinator { _, payload in
            await recorder.append(payload.phase)
        }
        let lifecycle = LifecycleReportingLLM(
            baseLLM: adapter,
            modelID: UUID(),
            coordinator: coordinator
        )

        let stream = lifecycle.stream(
            [Message(id: UUID(), role: .user, content: "hi")],
            config: LLMRequestConfig(maxTokens: 1024)
        )
        let (results, terminal) = await consume(stream)

        #expect(terminal == nil)
        let completes = results.filter { if case .complete = $0 { return true } else { return false } }
        #expect(completes.count == 1)

        let phases = await recorder.phases
        #expect(phases.contains(.connecting))
        #expect(phases.contains(.streaming))
        #expect(phases.contains(.done))
        #expect(!phases.contains(.errored))
    }

    // MARK: - LM Studio success path

    @Test("LMStudioLLM stream success records connecting → streaming → done with no .errored")
    func lmStudioStreamSuccessPhases() async throws {
        let chunkA: [String: any Sendable] = [
            "choices": [
                ["index": 0, "delta": ["content": "hello "] as [String: any Sendable]] as [String: any Sendable]
            ] as [any Sendable]
        ]
        let chunkB: [String: any Sendable] = [
            "choices": [
                ["index": 0, "delta": ["content": "world"] as [String: any Sendable]] as [String: any Sendable]
            ] as [any Sendable]
        ]
        let final: [String: any Sendable] = [
            "choices": [
                [
                    "index": 0,
                    "delta": ["content": ""] as [String: any Sendable],
                    "finish_reason": "stop"
                ] as [String: any Sendable]
            ] as [any Sendable]
        ]

        let adapter = try await makeLMStudio(
            streamSource: ScriptedLMStudioSource(payloads: [chunkA, chunkB, final])
        )
        let recorder = PhaseRecorder()
        let coordinator = ModelInvocationCoordinator { _, payload in
            await recorder.append(payload.phase)
        }
        let lifecycle = LifecycleReportingLLM(
            baseLLM: adapter,
            modelID: UUID(),
            coordinator: coordinator
        )

        let stream = lifecycle.stream(
            [Message(id: UUID(), role: .user, content: "hi")],
            config: LLMRequestConfig(maxTokens: 1024)
        )
        let (results, terminal) = await consume(stream)

        #expect(terminal == nil)
        let completes = results.filter { if case .complete = $0 { return true } else { return false } }
        #expect(completes.count == 1)

        let phases = await recorder.phases
        #expect(phases.contains(.connecting))
        #expect(phases.contains(.streaming))
        #expect(phases.contains(.done))
        #expect(!phases.contains(.errored))
    }

    // MARK: - Ollama LLMError surface (failure path stays typed)

    @Test("OllamaLLM stream LLMError stays typed and records .errored exactly once")
    func ollamaStreamErrorRecordsErroredOnce() async throws {
        struct FailingSource: OllamaChatStreamSourcing {
            func chatStream(
                baseURL: URL,
                requestData: OKChatRequestData,
                timeout: TimeInterval?,
                logger: Logger?
            ) -> AsyncThrowingStream<OllamaChatStreamChunk, Error> {
                AsyncThrowingStream { $0.finish(throwing: LLMError.timeout) }
            }
        }

        let adapter = try await makeOllama(streamSource: FailingSource())
        let recorder = PhaseRecorder()
        let coordinator = ModelInvocationCoordinator { _, payload in
            await recorder.append(payload.phase)
        }
        let lifecycle = LifecycleReportingLLM(
            baseLLM: adapter,
            modelID: UUID(),
            coordinator: coordinator
        )

        let stream = lifecycle.stream(
            [Message(id: UUID(), role: .user, content: "hi")],
            config: LLMRequestConfig(maxTokens: 1024)
        )
        let (_, terminal) = await consume(stream)

        guard let err = terminal as? LLMError, case .timeout = err else {
            Issue.record("expected LLMError.timeout, got \(String(describing: terminal))")
            return
        }

        let phases = await recorder.phases
        let erroredCount = phases.filter { $0 == .errored }.count
        #expect(erroredCount == 1)
        #expect(!phases.contains(.done))
    }
}
