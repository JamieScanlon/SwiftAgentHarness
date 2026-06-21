import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private struct RejectingBudgetAccounting: BudgetAccounting {
    func authorize(
        policy: BudgetPolicy,
        modelID: UUID,
        conversationID: UUID?,
        accountID: UUID?,
        projectedCostUSD: Double?
    ) async throws {
        let _ = (policy, modelID, conversationID, accountID, projectedCostUSD)
        throw LLMError.quotaExceeded
    }
    func recordCompletion(
        policy: BudgetPolicy,
        modelID: UUID,
        conversationID: UUID?,
        accountID: UUID?,
        actualCostUSD: Double?
    ) async {
        let _ = (policy, modelID, conversationID, accountID, actualCostUSD)
        Issue.record("recordCompletion must not be called when authorize rejects")
    }
}

@Suite("StandardModelLLMFactory budget wiring")
struct StandardModelLLMFactoryBudgetTests {

    private static func model() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "test-model",
            serverURL: URL(string: "http://localhost:1/")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    @Test("Rejecting accounting → factory-built stack throws LLMError.quotaExceeded on send (base adapter never reached)")
    func rejectingAccountingThrowsOnSend() async throws {
        let factory = StandardModelLLMFactory(
            advanced: ModelPoolAdvancedConfiguration(
                budget: .enabled(maxUSDPerCall: 0.01, maxUSDPerConversation: 0.10)
            ),
            accounting: RejectingBudgetAccounting()
        )
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
        let llm = factory.makeBaseLLM(
            model: Self.model(),
            providerBindings: nil,
            conversationID: UUID(),
            ownerAccountID: nil,
            systemPrompt: prompt,
            logger: nil
        )

        await #expect(throws: LLMError.self) {
            // The wrapper rejects before the inner OpenAILLM gets a chance to network.
            _ = try await llm.send([], config: LLMRequestConfig())
        }
    }

    @Test("Default factory wraps the result in BudgetEnforcingLLM")
    func defaultFactoryWrapsInBudgetEnforcingLLM() async throws {
        let factory = StandardModelLLMFactory()
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
        let llm = factory.makeBaseLLM(
            model: Self.model(),
            providerBindings: nil,
            conversationID: UUID(),
            ownerAccountID: nil,
            systemPrompt: prompt,
            logger: nil
        )

        #expect(llm is BudgetEnforcingLLM, "Factory result must be a BudgetEnforcingLLM")
    }

    @Test("Rejecting accounting → factory-built stack throws LLMError.quotaExceeded on stream pre-iteration")
    func rejectingAccountingThrowsOnStream() async throws {
        let factory = StandardModelLLMFactory(
            advanced: ModelPoolAdvancedConfiguration(
                budget: .enabled(maxUSDPerCall: 0.01, maxUSDPerConversation: nil)
            ),
            accounting: RejectingBudgetAccounting()
        )
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
        let llm = factory.makeBaseLLM(
            model: Self.model(),
            providerBindings: nil,
            conversationID: UUID(),
            ownerAccountID: nil,
            systemPrompt: prompt,
            logger: nil
        )

        var partials: [String] = []
        var thrown: Error?
        do {
            for try await result in llm.stream([], config: LLMRequestConfig()) {
                if case .stream(let p) = result { partials.append(p.content) }
            }
        } catch {
            thrown = error
        }
        #expect(partials.isEmpty)
        #expect(thrown is LLMError)
    }

    @Test("DelegateCostLedger integrated through factory rejects over-cap send")
    func delegateLedgerFactoryIntegration() async throws {
        let ledger = DelegateCostLedger()
        let factory = StandardModelLLMFactory(
            advanced: ModelPoolAdvancedConfiguration(
                budget: .enabled(maxUSDPerCall: 0.001, maxUSDPerConversation: nil)
            ),
            accounting: ledger
        )
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
        let costlyModel = Model(
            protocol: .openAIAPI,
            modelName: "test-model",
            serverURL: URL(string: "http://localhost:1/")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI,
            cost: ModelCostBudget(inputPer1MUSD: 50.0, outputPer1MUSD: 50.0)
        )
        let llm = factory.makeBaseLLM(
            model: costlyModel,
            providerBindings: nil,
            conversationID: UUID(),
            ownerAccountID: nil,
            systemPrompt: prompt,
            logger: nil
        )
        await #expect(throws: LLMError.self) {
            _ = try await llm.send(
                [Message(id: UUID(), role: .user, content: String(repeating: "x", count: 4000))],
                config: LLMRequestConfig(maxTokens: 4096)
            )
        }
    }

    @Test("Factory retains configured cache policies")
    func factoryRetainsCachePolicies() {
        let factory = StandardModelLLMFactory(
            advanced: ModelPoolAdvancedConfiguration(
                promptCache: .enabled(strategy: .automatic),
                responseCache: .enabled(maxEntries: 64, ttlSeconds: 30, stablePrefixMessageCount: 4)
            )
        )
        if case .enabled(let strategy) = factory.advanced.promptCache {
            #expect(strategy == .automatic)
        } else {
            Issue.record("Expected promptCache enabled")
        }
        if case .enabled(let maxEntries, let ttlSeconds, let stablePrefixMessageCount) = factory.advanced.responseCache {
            #expect(maxEntries == 64)
            #expect(ttlSeconds == 30)
            #expect(stablePrefixMessageCount == 4)
        } else {
            Issue.record("Expected responseCache enabled")
        }
    }

    @Test("profile-specific OpenAI key is preferred")
    func profileSpecificOpenAIKeyPreferred() {
        let binding = ProviderBinding(
            providerId: "openai",
            modelProtocol: .openAIAPI,
            endpointModelId: "gpt-test",
            serverURL: URL(string: "https://api.openai.com/v1")!,
            priority: 0,
            authProfile: "prod-west"
        )
        let key = StandardModelLLMFactory.resolveOpenAIAPIKey(
            binding: binding,
            defaultAuthProfile: nil,
            environment: [
                "SAH_OPENAI_API_KEY_PROD_WEST": "profile-key",
                "OPENAI_API_KEY": "global-key",
            ]
        )
        #expect(key == "profile-key")
    }

    @Test("default auth profile fallback can source OpenAI key")
    func defaultProfileFallbackOpenAIKey() {
        let binding = ProviderBinding(
            providerId: "openai",
            modelProtocol: .openAIAPI,
            endpointModelId: "gpt-test",
            serverURL: URL(string: "https://api.openai.com/v1")!,
            priority: 0,
            authProfile: nil
        )
        let key = StandardModelLLMFactory.resolveOpenAIAPIKey(
            binding: binding,
            defaultAuthProfile: "team-a",
            environment: [
                "OPENAI_API_KEY_TEAM_A": "team-key",
                "OPENAI_API_KEY": "global-key",
            ]
        )
        #expect(key == "team-key")
    }
}
