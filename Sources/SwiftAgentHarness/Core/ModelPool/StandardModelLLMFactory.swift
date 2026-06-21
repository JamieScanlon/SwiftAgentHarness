import Foundation
import Logging
import SwiftAgentKit

/// Default provider adapters for local, OpenAI-shaped, and Anthropic wire endpoints.
public struct StandardModelLLMFactory: ModelLLMFactoring {
    public var advanced: ModelPoolAdvancedConfiguration
    /// Per-call budget gate. Use ``productionConfigured(accounting:logger:serverConfig:)`` at the composition root.
    public var accounting: any BudgetAccounting
    public var promptCachePlanner: any PromptCachePlanning
    public var responseCacheStore: ResponseCacheStore
    /// Test seam: bypasses the provider switch to exercise factory failover wiring without network I/O.
    var testBindingAdapterOverride: (@Sendable (ProviderBinding) -> any LLMProtocol)?

    public init(
        advanced: ModelPoolAdvancedConfiguration = ModelPoolAdvancedConfiguration(),
        accounting: any BudgetAccounting = AlwaysAllowBudgetAccounting(),
        promptCachePlanner: any PromptCachePlanning = CapabilityDrivenPromptCachePlanner(),
        responseCacheStore: ResponseCacheStore = ResponseCacheStore(),
        testBindingAdapterOverride: (@Sendable (ProviderBinding) -> any LLMProtocol)? = nil
    ) {
        self.advanced = advanced
        self.accounting = accounting
        self.promptCachePlanner = promptCachePlanner
        self.responseCacheStore = responseCacheStore
        self.testBindingAdapterOverride = testBindingAdapterOverride
    }

    /// Production factory: real ``BudgetAccounting`` plus enabled budget/failover policies from config.
    public static func productionConfigured(
        accounting: any BudgetAccounting,
        logger: Logger? = nil,
        serverConfig: ServerConfig = ServerConfig(),
        substitutionMaxFallbackCandidates: Int = 2
    ) -> StandardModelLLMFactory {
        var factory = StandardModelLLMFactory(accounting: accounting)
        let budgetConfiguration = ModelPoolBudgetConfiguration
            .loadFromPromptConfigBundle(logger: logger)
            .applyingOverrides(serverConfig: serverConfig)
            .applyingEnvironmentOverrides()
        let failoverConfiguration = ModelPoolFailoverConfiguration
            .loadFromPromptConfigBundle(logger: logger)
            .applyingOverrides(serverConfig: serverConfig)
        factory.advanced.budget = budgetConfiguration.resolvedPolicy()
        factory.advanced.failover = failoverConfiguration.resolvedPolicy()
        factory.advanced.substitution = .enabled(maxFallbackCandidates: substitutionMaxFallbackCandidates)
        factory.advanced.promptCache = serverConfig.modelPoolPromptCachePlanningEnabled
            ? .enabled(strategy: .automatic)
            : .disabled
        factory.advanced.responseCache = serverConfig.modelPoolResponseCacheEnabled
            ? .enabled(
                maxEntries: serverConfig.modelPoolResponseCacheMaxEntries,
                ttlSeconds: serverConfig.modelPoolResponseCacheTTLSeconds,
                stablePrefixMessageCount: serverConfig.modelPoolResponseCacheStablePrefixMessageCount
            )
            : .disabled
        return factory
    }

    /// When a real tracker is supplied but the factory still uses pass-through accounting, align them.
    static func aligningAccounting(
        factory: any ModelLLMFactoring,
        delegateCostTracker: (any DelegateCostTracking)?
    ) -> any ModelLLMFactoring {
        guard var std = factory as? StandardModelLLMFactory,
              let tracker = delegateCostTracker,
              std.accounting is AlwaysAllowBudgetAccounting
        else {
            return factory
        }
        std.accounting = tracker
        return std
    }

    public func substitutionPolicy() -> ModelSubstitutionPolicy {
        advanced.substitution
    }

    public func makeBaseLLM(
        model: Model,
        providerBindings: [ProviderBinding]?,
        conversationID: UUID?,
        ownerAccountID: UUID?,
        systemPrompt: SystemPrompt,
        logger: Logger?,
        attemptObserver: (@Sendable (ModelCallAttemptObservation) async -> Void)?
    ) -> any LLMProtocol {
        let resolvedBindings: [ProviderBinding] = {
            let fromRegistry = providerBindings?.sorted { $0.priority < $1.priority } ?? []
            if !fromRegistry.isEmpty {
                return fromRegistry
            }
            return [
                ProviderBinding(
                    providerId: model.modelProtocol.rawValue,
                    modelProtocol: model.modelProtocol,
                    endpointModelId: model.modelName,
                    serverURL: model.serverURL,
                    priority: 0,
                    authProfile: defaultAuthProfileFromEnvironment()
                ),
            ]
        }()
        let baseAdapter: @Sendable (ProviderBinding) -> any LLMProtocol = { binding in
            let adapter = Self.makeBindingAdapter(
                binding: binding,
                model: model,
                systemPrompt: systemPrompt,
                logger: logger,
                override: testBindingAdapterOverride,
                resolveOpenAIAPIKey: { resolveOpenAIAPIKey(for: $0) },
                resolveAnthropicAPIKey: { resolveAnthropicAPIKey(for: $0) }
            )
            let promptPlanned: any LLMProtocol
            if case .enabled = advanced.promptCache {
                promptPlanned = PromptCachePlanningLLM(
                    base: adapter,
                    modelID: model.id,
                    binding: binding,
                    modelCapabilities: model.capabilities,
                    modelCost: model.cost,
                    policy: advanced.promptCache,
                    planner: promptCachePlanner,
                    attemptObserver: attemptObserver
                )
            } else {
                promptPlanned = adapter
            }
            if case .enabled = advanced.responseCache {
                let providerScopeKey = providerScopeKey(for: binding)
                return ResponseCachingLLM(
                    base: promptPlanned,
                    store: responseCacheStore,
                    modelID: model.id,
                    providerScopeKey: providerScopeKey,
                    policy: advanced.responseCache
                )
            }
            return promptPlanned
        }
        let withRetries: any LLMProtocol
        if resolvedBindings.count > 1 {
            withRetries = MultiBindingFailoverLLM(
                bindings: resolvedBindings,
                makeBindingLLM: { binding in
                    let base = baseAdapter(binding)
                    return advanced.failover.maxRetries > 0
                        ? RetryingLLMFactory.wrap(
                            baseLLM: base,
                            policy: advanced.failover,
                            logger: logger,
                            modelID: model.id,
                            attemptObserver: attemptObserver
                        )
                        : base
                },
                logger: logger,
                modelID: model.id,
                attemptObserver: attemptObserver
            )
        } else {
            let base = baseAdapter(resolvedBindings[0])
            withRetries = advanced.failover.maxRetries > 0
                ? RetryingLLMFactory.wrap(
                    baseLLM: base,
                    policy: advanced.failover,
                    logger: logger,
                    modelID: model.id,
                    attemptObserver: attemptObserver
                )
                : base
        }
        // ``BudgetEnforcingLLM`` sits OUTSIDE ``RetryingLLM`` so a single authorize/settle pair
        // covers all retries of one logical call. It is unconditional because the default
        // accounting (``AlwaysAllowBudgetAccounting``) is a pass-through; a real accounting
        // implementation can replace it via the factory init seam.
        return BudgetEnforcingLLM(
            base: withRetries,
            accounting: accounting,
            policy: advanced.budget,
            modelID: model.id,
            conversationID: conversationID,
            ownerAccountID: ownerAccountID,
            modelCost: model.cost,
            logger: logger
        )
    }

    static func makeBindingAdapter(
        binding: ProviderBinding,
        model: Model,
        systemPrompt: SystemPrompt,
        logger: Logger?,
        override: (@Sendable (ProviderBinding) -> any LLMProtocol)? = nil,
        resolveOpenAIAPIKey: (ProviderBinding) -> String = { _ in "dummy_key" },
        resolveAnthropicAPIKey: (ProviderBinding) -> String = { _ in "dummy_key" }
    ) -> any LLMProtocol {
        if let override {
            return override(binding)
        }
        switch binding.modelProtocol {
        case .ollama:
            return OllamaLLM(
                model: binding.endpointModelId,
                serverURL: binding.serverURL,
                capabilities: model.capabilities,
                requestFeatures: model.requestFeatures,
                systemPrompt: systemPrompt,
                logger: logger
            )
        case .openAIAPI:
            return OpenAILLM(
                baseURL: binding.serverURL.absoluteString,
                apiKey: resolveOpenAIAPIKey(binding),
                model: binding.endpointModelId,
                capabilities: model.capabilities,
                requestFeatures: model.requestFeatures,
                systemPrompt: systemPrompt,
                logger: logger
            )
        case .lmStudio:
            return LMStudioLLM(
                model: binding.endpointModelId,
                serverURL: binding.serverURL,
                capabilities: model.capabilities,
                requestFeatures: model.requestFeatures,
                systemPrompt: systemPrompt,
                logger: logger
            )
        case .anthropic:
            return AnthropicLLM(
                apiURL: binding.serverURL,
                apiKey: resolveAnthropicAPIKey(binding),
                model: binding.endpointModelId,
                capabilities: model.capabilities,
                requestFeatures: model.requestFeatures,
                systemPrompt: systemPrompt,
                logger: logger
            )
        }
    }

    private func providerScopeKey(for binding: ProviderBinding) -> String {
        let authProfile = binding.authProfile?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProfile = (authProfile?.isEmpty == false) ? authProfile! : "default"
        return "\(binding.providerId)#\(binding.endpointModelId)#\(binding.serverURL.absoluteString)#\(normalizedProfile)"
    }

    private func resolveAnthropicAPIKey(for binding: ProviderBinding) -> String {
        Self.resolveAnthropicAPIKey(
            binding: binding,
            defaultAuthProfile: defaultAuthProfileFromEnvironment(),
            environment: ProcessInfo.processInfo.environment
        )
    }

    static func resolveAnthropicAPIKey(
        binding: ProviderBinding,
        defaultAuthProfile: String?,
        environment: [String: String]
    ) -> String {
        let profile = normalizedAuthProfile(binding.authProfile) ?? normalizedAuthProfile(defaultAuthProfile)
        if let profile {
            let suffix = envKeySuffix(forAuthProfile: profile)
            let profileKeys = [
                "SAH_ANTHROPIC_API_KEY_\(suffix)",
                "ANTHROPIC_API_KEY_\(suffix)",
            ]
            for key in profileKeys {
                if let value = normalizedEnvValue(environment[key]) {
                    return value
                }
            }
        }
        for key in ["SAH_ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY"] {
            if let value = normalizedEnvValue(environment[key]) {
                return value
            }
        }
        return "dummy_key"
    }

    private func resolveOpenAIAPIKey(for binding: ProviderBinding) -> String {
        Self.resolveOpenAIAPIKey(
            binding: binding,
            defaultAuthProfile: defaultAuthProfileFromEnvironment(),
            environment: ProcessInfo.processInfo.environment
        )
    }

    private func defaultAuthProfileFromEnvironment() -> String? {
        let raw = ProcessInfo.processInfo.environment["SAH_SESSION_AUTH_PROFILE"] ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func resolveOpenAIAPIKey(
        binding: ProviderBinding,
        defaultAuthProfile: String?,
        environment: [String: String]
    ) -> String {
        let profile = normalizedAuthProfile(binding.authProfile) ?? normalizedAuthProfile(defaultAuthProfile)
        if let profile {
            let suffix = envKeySuffix(forAuthProfile: profile)
            let profileKeys = [
                "SAH_OPENAI_API_KEY_\(suffix)",
                "OPENAI_API_KEY_\(suffix)",
            ]
            for key in profileKeys {
                if let value = normalizedEnvValue(environment[key]) {
                    return value
                }
            }
        }
        for key in ["SAH_OPENAI_API_KEY", "OPENAI_API_KEY"] {
            if let value = normalizedEnvValue(environment[key]) {
                return value
            }
        }
        return "dummy_key"
    }

    private static func normalizedAuthProfile(_ profile: String?) -> String? {
        guard let profile else { return nil }
        let trimmed = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedEnvValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func envKeySuffix(forAuthProfile profile: String) -> String {
        let upper = profile.uppercased()
        let mappedScalars = upper.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "_"
        }
        return String(mappedScalars)
    }
}
