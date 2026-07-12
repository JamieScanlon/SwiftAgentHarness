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
    public var authProfileStore: AuthProfileStore
    public var authProfileCooldownRegistry: AuthProfileCooldownRegistry
    public var tenancyPolicy: TenancyPolicySettings
    var budgetConfiguration: ModelPoolBudgetConfiguration?
    /// Test seam: bypasses the provider switch to exercise factory failover wiring without network I/O.
    var testBindingAdapterOverride: (@Sendable (ProviderBinding) -> any LLMProtocol)?

    public init(
        advanced: ModelPoolAdvancedConfiguration = ModelPoolAdvancedConfiguration(),
        accounting: any BudgetAccounting = AlwaysAllowBudgetAccounting(),
        promptCachePlanner: any PromptCachePlanning = CapabilityDrivenPromptCachePlanner(),
        responseCacheStore: ResponseCacheStore = ResponseCacheStore(),
        authProfileStore: AuthProfileStore = .production(),
        authProfileCooldownRegistry: AuthProfileCooldownRegistry = AuthProfileCooldownRegistry(),
        tenancyPolicy: TenancyPolicySettings = .disabled,
        budgetConfiguration: ModelPoolBudgetConfiguration? = nil,
        testBindingAdapterOverride: (@Sendable (ProviderBinding) -> any LLMProtocol)? = nil
    ) {
        self.advanced = advanced
        self.accounting = accounting
        self.promptCachePlanner = promptCachePlanner
        self.responseCacheStore = responseCacheStore
        self.authProfileStore = authProfileStore
        self.authProfileCooldownRegistry = authProfileCooldownRegistry
        self.tenancyPolicy = tenancyPolicy
        self.budgetConfiguration = budgetConfiguration
        self.testBindingAdapterOverride = testBindingAdapterOverride
    }

    /// Production factory: real ``BudgetAccounting`` plus enabled budget/failover policies from config.
    public static func productionConfigured(
        accounting: any BudgetAccounting,
        logger: Logger? = nil,
        serverConfig: ServerConfig = ServerConfig(),
        substitutionMaxFallbackCandidates: Int = 2,
        authProfileStore: AuthProfileStore = .production(),
        authProfileCooldownRegistry: AuthProfileCooldownRegistry = AuthProfileCooldownRegistry()
    ) -> StandardModelLLMFactory {
        var factory = StandardModelLLMFactory(
            accounting: accounting,
            authProfileStore: authProfileStore,
            authProfileCooldownRegistry: authProfileCooldownRegistry
        )
        let budgetConfiguration = ModelPoolBudgetConfiguration
            .loadFromPromptConfigBundle(logger: logger)
            .applyingOverrides(serverConfig: serverConfig)
            .applyingEnvironmentOverrides()
        let failoverConfiguration = ModelPoolFailoverConfiguration
            .loadFromPromptConfigBundle(logger: logger)
            .applyingOverrides(serverConfig: serverConfig)
        factory.advanced.budget = budgetConfiguration.resolvedPolicy()
        factory.budgetConfiguration = budgetConfiguration
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

    func resolvedBudgetPolicy() -> BudgetPolicy {
        if let budgetConfiguration {
            return budgetConfiguration.resolvedPolicy(tenancyPolicy: tenancyPolicy)
        }
        return advanced.budget
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
        let makeBindingLLM: @Sendable (ProviderBinding) -> any LLMProtocol = { binding in
            Self.makeCredentialAwareBindingLLM(
                binding: binding,
                model: model,
                systemPrompt: systemPrompt,
                advanced: advanced,
                authProfileStore: authProfileStore,
                authProfileCooldownRegistry: authProfileCooldownRegistry,
                promptCachePlanner: promptCachePlanner,
                responseCacheStore: responseCacheStore,
                logger: logger,
                modelID: model.id,
                ownerAccountID: ownerAccountID,
                tenancyPolicy: tenancyPolicy,
                attemptObserver: attemptObserver,
                testBindingAdapterOverride: testBindingAdapterOverride
            )
        }
        let withRetries: any LLMProtocol
        if resolvedBindings.count > 1 {
            withRetries = MultiBindingFailoverLLM(
                bindings: resolvedBindings,
                makeBindingLLM: makeBindingLLM,
                logger: logger,
                modelID: model.id,
                attemptObserver: attemptObserver
            )
        } else {
            withRetries = makeBindingLLM(resolvedBindings[0])
        }
        return BudgetEnforcingLLM(
            base: withRetries,
            accounting: accounting,
            policy: resolvedBudgetPolicy(),
            modelID: model.id,
            conversationID: conversationID,
            ownerAccountID: ownerAccountID,
            modelCost: model.cost,
            logger: logger
        )
    }

    static func makeCredentialAwareBindingLLM(
        binding: ProviderBinding,
        model: Model,
        systemPrompt: SystemPrompt,
        advanced: ModelPoolAdvancedConfiguration,
        authProfileStore: AuthProfileStore,
        authProfileCooldownRegistry: AuthProfileCooldownRegistry,
        promptCachePlanner: any PromptCachePlanning,
        responseCacheStore: ResponseCacheStore,
        logger: Logger?,
        modelID: UUID,
        ownerAccountID: UUID?,
        tenancyPolicy: TenancyPolicySettings,
        attemptObserver: (@Sendable (ModelCallAttemptObservation) async -> Void)?,
        testBindingAdapterOverride: (@Sendable (ProviderBinding) -> any LLMProtocol)?
    ) -> any LLMProtocol {
        let cacheOwnerScopeKey = ModelPoolOwnerScope.resolve(
            ownerAccountID: ownerAccountID,
            tenancyPolicy: tenancyPolicy
        )
        let credentialPool = (try? authProfileStore.resolveCredentialPool(
            providerID: binding.canonicalProviderID(),
            authProfileLabel: binding.authProfile
        )) ?? []
        let makeCredentialStack: @Sendable (AuthProfile?) -> any LLMProtocol = { credential in
            let adapter = makeBindingAdapter(
                binding: binding,
                model: model,
                systemPrompt: systemPrompt,
                logger: logger,
                override: testBindingAdapterOverride,
                authProfileStore: authProfileStore,
                resolvedCredential: credential
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
            let cached: any LLMProtocol
            if case .enabled = advanced.responseCache {
                let providerScopeKey = providerScopeKey(
                    for: binding,
                    credentialID: credential?.id
                )
                cached = ResponseCachingLLM(
                    base: promptPlanned,
                    store: responseCacheStore,
                    modelID: model.id,
                    providerScopeKey: providerScopeKey,
                    policy: advanced.responseCache,
                    cacheOwnerScopeKey: cacheOwnerScopeKey
                )
            } else {
                cached = promptPlanned
            }
            if advanced.failover.maxRetries > 0 {
                return RetryingLLMFactory.wrap(
                    baseLLM: cached,
                    policy: advanced.failover,
                    logger: logger,
                    modelID: model.id,
                    attemptObserver: attemptObserver
                )
            }
            return cached
        }
        if credentialPool.isEmpty {
            return makeCredentialStack(nil)
        }
        return CredentialRotatingLLM(
            binding: binding,
            credentialPool: credentialPool,
            rotationStrategy: advanced.failover.rotationStrategy,
            billingCooldown: advanced.failover.billingCooldown,
            rateLimitCooldown: advanced.failover.rateLimitCooldown,
            cooldownRegistry: authProfileCooldownRegistry,
            makeCredentialLLM: { credential in
                makeCredentialStack(credential)
            },
            logger: logger,
            modelID: model.id,
            attemptObserver: attemptObserver
        )
    }

    static func makeBindingAdapter(
        binding: ProviderBinding,
        model: Model,
        systemPrompt: SystemPrompt,
        logger: Logger?,
        override: (@Sendable (ProviderBinding) -> any LLMProtocol)? = nil,
        authProfileStore: AuthProfileStore = .production(),
        resolvedCredential: AuthProfile? = nil
    ) -> any LLMProtocol {
        if let override {
            return override(binding)
        }
        guard let provider = ProviderRegistry.textInferenceProvider(forBinding: binding) else {
            return MissingTextInferenceProviderLLM(
                providerID: binding.canonicalProviderID(),
                modelProtocol: binding.modelProtocol,
                endpointModelId: binding.endpointModelId
            )
        }
        let resolved: AuthProfile?
        if let resolvedCredential {
            resolved = resolvedCredential
        } else if let credential = try? authProfileStore.resolveCredential(
            providerID: binding.canonicalProviderID(),
            authProfileLabel: binding.authProfile
        ) {
            resolved = credential.profile
        } else {
            resolved = nil
        }
        let requiresWireCredential = provider.manifest.providerAuthChoices.contains {
            $0.resolvedAuthType.requiresWireCredential
        }
        if requiresWireCredential, resolved?.isDispatchReady != true {
            return MissingAuthCredentialLLM(
                providerID: binding.canonicalProviderID(),
                endpointModelId: binding.endpointModelId
            )
        }
        let bindingModel = ModelManager.model(model, applyingBinding: binding)
        let compat = ProviderRuntimeHooks.compatForBinding(binding)
        return provider.makeAdapter(
            context: ProviderAdapterContext(
                binding: binding,
                model: bindingModel,
                systemPrompt: systemPrompt,
                authProfileStore: authProfileStore,
                resolvedCredential: resolved,
                compat: compat,
                logger: logger
            )
        )
    }

    private static func providerScopeKey(for binding: ProviderBinding, credentialID: String? = nil) -> String {
        let authProfile = binding.authProfile?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProfile = (authProfile?.isEmpty == false) ? authProfile! : "default"
        let credentialSuffix = credentialID ?? "default"
        return "\(binding.providerId)#\(binding.endpointModelId)#\(binding.serverURL.absoluteString)#\(normalizedProfile)#\(credentialSuffix)"
    }

    private func defaultAuthProfileFromEnvironment() -> String? {
        let raw = ProcessInfo.processInfo.environment["SAH_SESSION_AUTH_PROFILE"] ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
