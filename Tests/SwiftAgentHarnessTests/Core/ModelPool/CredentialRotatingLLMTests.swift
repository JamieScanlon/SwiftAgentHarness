import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private actor CredentialAttemptCollector {
    var rows: [ModelCallAttemptObservation] = []
    func append(_ row: ModelCallAttemptObservation) { rows.append(row) }
}

private actor CredentialScriptedLLM: LLMProtocol {
    private var sendQueue: [Result<LLMResponse, Error>]
    private(set) var sendCalls: Int = 0
    let credentialID: String

    init(credentialID: String, sendQueue: [Result<LLMResponse, Error>]) {
        self.credentialID = credentialID
        self.sendQueue = sendQueue
    }

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
    nonisolated func getModelName() -> String { credentialID }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion] }
    nonisolated func getRequestFeatures() -> ModelRequestFeatures { .unknown }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let _ = (messages, config)
        sendCalls += 1
        guard !sendQueue.isEmpty else {
            return LLMResponse(content: "ok", toolCalls: [])
        }
        switch sendQueue.removeFirst() {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        let _ = config
        return ImageGenerationResponse(images: [])
    }

    nonisolated func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        let _ = (messages, config)
        return AsyncThrowingStream { $0.finish() }
    }
}

@Suite("CredentialRotatingLLM")
struct CredentialRotatingLLMTests {
    @Test("Rotates credentials on rate limit and succeeds")
    func rotatesOnRateLimit() async throws {
        let pool = [
            AuthProfile(id: "key-a", providerID: "openai", authType: .apiKey, apiKey: "a", priority: 0),
            AuthProfile(id: "key-b", providerID: "openai", authType: .apiKey, apiKey: "b", priority: 1),
        ]
        let binding = ProviderBinding(
            providerId: "openai",
            modelProtocol: .openAIAPI,
            endpointModelId: "gpt-test",
            serverURL: URL(string: "https://api.openai.com/v1")!,
            priority: 0
        )
        let registry = AuthProfileCooldownRegistry()
        let collector = CredentialAttemptCollector()
        let modelID = UUID()
        let llm = CredentialRotatingLLM(
            binding: binding,
            credentialPool: pool,
            cooldownRegistry: registry,
            makeCredentialLLM: { credential in
                if credential.id == "key-a" {
                    return CredentialScriptedLLM(
                        credentialID: credential.id,
                        sendQueue: [.failure(LLMError.rateLimitExceeded)]
                    )
                }
                return CredentialScriptedLLM(
                    credentialID: credential.id,
                    sendQueue: [.success(LLMResponse(content: "ok", toolCalls: []))]
                )
            },
            modelID: modelID,
            attemptObserver: { await collector.append($0) }
        )
        let response = try await llm.send([Message(id: UUID(), role: .user, content: "hi")], config: LLMRequestConfig())
        #expect(response.content == "ok")
        let cooled = await registry.isAvailable(key: "key-a", at: Date())
        #expect(cooled == false)
        let attempts = await collector.rows
        #expect(attempts.contains { $0.kind == .credentialRotation && $0.authProfileCredentialID == "key-a" })
    }

    @Test("Exhausted pool propagates last error")
    func exhaustedPoolPropagates() async {
        let pool = [
            AuthProfile(id: "key-a", providerID: "openai", authType: .apiKey, apiKey: "a", priority: 0),
            AuthProfile(id: "key-b", providerID: "openai", authType: .apiKey, apiKey: "b", priority: 1),
        ]
        let binding = ProviderBinding(
            providerId: "openai",
            modelProtocol: .openAIAPI,
            endpointModelId: "gpt-test",
            serverURL: URL(string: "https://api.openai.com/v1")!,
            priority: 0
        )
        let llm = CredentialRotatingLLM(
            binding: binding,
            credentialPool: pool,
            cooldownRegistry: AuthProfileCooldownRegistry(),
            makeCredentialLLM: { credential in
                CredentialScriptedLLM(
                    credentialID: credential.id,
                    sendQueue: [.failure(LLMError.quotaExceeded)]
                )
            }
        )
        await #expect(throws: LLMError.self) {
            _ = try await llm.send([Message(id: UUID(), role: .user, content: "hi")], config: LLMRequestConfig())
        }
    }
}
