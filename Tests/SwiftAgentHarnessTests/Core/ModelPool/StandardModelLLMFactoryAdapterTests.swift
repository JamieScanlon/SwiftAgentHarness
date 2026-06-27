import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private actor FactoryFailoverStubLLM: LLMProtocol {
    private let response: Result<LLMResponse, Error>

    init(response: Result<LLMResponse, Error>) {
        self.response = response
    }

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
    nonisolated func getModelName() -> String { "factory-stub" }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion] }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let _ = (messages, config)
        switch response {
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

@Suite("StandardModelLLMFactory adapter dispatch")
struct StandardModelLLMFactoryAdapterTests {
    private static func model() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "logical-model",
            serverURL: URL(string: "http://localhost:1/")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    private static func systemPrompt() async throws -> SystemPrompt {
        try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
    }

    private static func binding(
        _ providerId: String,
        _ modelProtocol: ModelProtocol,
        endpoint: String,
        priority: Int
    ) -> ProviderBinding {
        ProviderBinding(
            providerId: providerId,
            modelProtocol: modelProtocol,
            endpointModelId: endpoint,
            serverURL: URL(string: "http://localhost:1/")!,
            priority: priority
        )
    }

    @Test("makeBindingAdapter selects native adapter per ModelProtocol")
    func adapterDispatchPerProtocol() async throws {
        let prompt = try await Self.systemPrompt()
        let model = Self.model()
        let store = AuthProfileStore(
            environment: [
                "OPENAI_API_KEY": "test-openai",
                "ANTHROPIC_API_KEY": "test-anthropic",
            ]
        )
        let cases: [(String, ModelProtocol, any LLMProtocol.Type)] = [
            ("ollama", .ollama, OllamaLLM.self),
            ("openai", .openAIAPI, OpenAILLM.self),
            ("lmstudio", .lmStudio, LMStudioLLM.self),
            ("anthropic", .anthropic, AnthropicLLM.self),
        ]
        for (providerId, modelProtocol, expectedAdapterType) in cases {
            let adapter = StandardModelLLMFactory.makeBindingAdapter(
                binding: Self.binding(providerId, modelProtocol, endpoint: "model", priority: 0),
                model: model,
                systemPrompt: prompt,
                logger: nil,
                authProfileStore: store
            )
            #expect(type(of: adapter) == expectedAdapterType, "Expected \(expectedAdapterType) for \(modelProtocol)")
        }
    }

    @Test("multiple provider bindings wrap factory stack in MultiBindingFailoverLLM")
    func multiBindingUsesFailoverWrapper() async throws {
        let factory = StandardModelLLMFactory(
            advanced: ModelPoolAdvancedConfiguration(failover: FailoverPolicy(maxRetries: 0))
        )
        let llm = factory.makeBaseLLM(
            model: Self.model(),
            providerBindings: [
                Self.binding("anthropic", .anthropic, endpoint: "claude", priority: 0),
                Self.binding("openai", .openAIAPI, endpoint: "gpt", priority: 1),
            ],
            conversationID: UUID(),
            ownerAccountID: nil,
            systemPrompt: try await Self.systemPrompt(),
            logger: nil
        )
        guard let budget = llm as? BudgetEnforcingLLM else {
            Issue.record("expected BudgetEnforcingLLM wrapper")
            return
        }
        #expect(budget.base is MultiBindingFailoverLLM)
    }

    @Test("factory heterogeneous binding failover uses cross-provider adapters")
    func factoryHeterogeneousBindingFailover() async throws {
        var factory = StandardModelLLMFactory(
            advanced: ModelPoolAdvancedConfiguration(failover: FailoverPolicy(maxRetries: 0))
        )
        factory.testBindingAdapterOverride = { binding in
            switch binding.modelProtocol {
            case .anthropic:
                return FactoryFailoverStubLLM(response: .failure(LLMError.modelNotFound("claude")))
            case .openAIAPI:
                return FactoryFailoverStubLLM(response: .success(LLMResponse(content: "openai-fallback", toolCalls: [])))
            default:
                return FactoryFailoverStubLLM(response: .failure(LLMError.modelNotFound("unexpected-protocol")))
            }
        }
        let llm = factory.makeBaseLLM(
            model: Self.model(),
            providerBindings: [
                Self.binding("anthropic", .anthropic, endpoint: "claude", priority: 0),
                Self.binding("openai", .openAIAPI, endpoint: "gpt", priority: 1),
            ],
            conversationID: UUID(),
            ownerAccountID: nil,
            systemPrompt: try await Self.systemPrompt(),
            logger: nil
        )
        let response = try await llm.send([], config: LLMRequestConfig())
        #expect(response.content == "openai-fallback")
    }

    @Test("profile-specific Anthropic key is preferred")
    func profileSpecificAnthropicKeyPreferred() throws {
        let store = AuthProfileStore(
            environment: [
                "SAH_ANTHROPIC_API_KEY_PROD_WEST": "profile-key",
                "ANTHROPIC_API_KEY": "global-key",
            ],
            defaultAuthProfileLabel: "prod-west"
        )
        let resolved = try store.resolveAPIKey(providerID: "anthropic", authProfileLabel: "prod-west")
        #expect(resolved.apiKey == "profile-key")
    }
}
