import Foundation
import SwiftAgentHarness

public struct DefaultProviderOptions: Sendable {
    public var installBootstrapHook: Bool
    /// Host-defined API-server inference providers (any count). Empty = none registered via this path.
    public var inferenceRuntimes: [InferenceRuntimeConfig]

    public init(
        installBootstrapHook: Bool = true,
        inferenceRuntimes: [InferenceRuntimeConfig] = []
    ) {
        self.installBootstrapHook = installBootstrapHook
        self.inferenceRuntimes = inferenceRuntimes
    }
}

/// Resource bundle for manifest and catalog JSON shipped with this target.
public enum SwiftAgentHarnessProvidersResources {
    public static var bundle: Bundle { .module }
}

/// Registers the foundational provider plugins and optionally installs the bootstrap hook.
public func registerDefaults(
    options: DefaultProviderOptions = .init()
) {
    ProviderRegistry.withExclusiveRegistryAccess {
        ProviderResourceBundle.setResourceBundle(.module)
        DefaultProviderAdapterFactories.installAll()
        if options.installBootstrapHook {
            let runtimes = options.inferenceRuntimes
            ProviderRegistry.installBootstrap {
                registerDefaults(options: .init(installBootstrapHook: false, inferenceRuntimes: runtimes))
            }
        }
        try? registerOpenAI()
        try? registerAnthropic()
        try? registerOpenRouter()
        for runtime in options.inferenceRuntimes {
            try? registerInferenceRuntime(runtime)
        }
    }
}

/// Convenience for app startup: sets resource bundle, installs bootstrap hook, and registers defaults.
public func bootstrap(options: DefaultProviderOptions = .init()) {
    registerDefaults(options: options)
}

private func registerOpenAI() throws {
    let manifest = try BundledProviderManifestLoader.loadManifest(for: "openai")
    try ProviderRegistry.register(ProviderRegistration(
        manifest: manifest,
        textInference: OpenAITextInferenceProvider(manifest: manifest),
        cliInferenceBackends: [
            StubCLIInferenceBackendProvider(manifest: manifest, cliBackendID: "openai-codex"),
        ],
        speech: StubSpeechProvider(manifest: manifest),
        realtimeVoice: StubRealtimeVoiceProvider(manifest: manifest),
        imageGeneration: StubImageGenerationProvider(manifest: manifest)
    ))
}

private func registerAnthropic() throws {
    let manifest = try BundledProviderManifestLoader.loadManifest(for: "anthropic")
    try ProviderRegistry.register(ProviderRegistration(
        manifest: manifest,
        textInference: AnthropicTextInferenceProvider(manifest: manifest),
        mediaUnderstanding: StubMediaUnderstandingProvider(manifest: manifest)
    ))
}

private func registerOpenRouter() throws {
    let manifest = try BundledProviderManifestLoader.loadManifest(for: "openrouter")
    try ProviderRegistry.register(ProviderRegistration(
        manifest: manifest,
        textInference: OpenRouterTextInferenceProvider(manifest: manifest)
    ))
}

private func registerInferenceRuntime(_ runtime: InferenceRuntimeConfig) throws {
    guard let factory = ProviderAdapterFactoryRegistry.factory(for: runtime.adapterKind) else {
        throw ProviderInstanceConfigError.unknownAdapterKind(runtime.adapterKind.rawValue)
    }
    let templateID = templateManifestID(for: runtime.adapterKind)
    let base = try BundledProviderManifestLoader.loadManifest(for: templateID)
    let instanceConfig = ProviderInstanceConfig(
        adapterKind: runtime.adapterKind.rawValue,
        id: runtime.providerID,
        label: runtime.label,
        providerEndpoints: [ProviderEndpoint(id: "default", baseURL: runtime.serverURL)],
        providerAuthAliases: base.providerAuthAliases,
        providerAuthChoices: base.providerAuthChoices,
        modelSupport: base.modelSupport,
        cliBackends: base.cliBackends,
        uiHints: base.uiHints,
        capabilitySlots: base.capabilitySlots,
        default: base.`default`
    )
    let merged = try instanceConfig.mergedManifest(base: base)
    // Prefer full-fidelity typed runtime (modelIDMap) over the weaker plugin catalog rows.
    switch runtime.adapterKind {
    case .ollama:
        try ProviderRegistry.register(ProviderRegistration(
            manifest: merged,
            textInference: OllamaTextInferenceProvider(manifest: merged, runtime: runtime)
        ))
    case .lmStudio:
        try ProviderRegistry.register(ProviderRegistration(
            manifest: merged,
            textInference: LMStudioTextInferenceProvider(manifest: merged, runtime: runtime)
        ))
    default:
        let registration = try factory.makeRegistration(manifest: base, config: instanceConfig)
        try ProviderRegistry.register(registration)
    }
}

/// Bundled manifest templates keyed by adapter kind (wire protocol), not by host provider id.
private func templateManifestID(for adapterKind: ProviderAdapterKind) -> ProviderID {
    switch adapterKind {
    case .ollama: return "ollama"
    case .lmStudio: return "lmstudio"
    case .openAICompat: return "openai"
    case .anthropic: return "anthropic"
    case .openRouter: return "openrouter"
    default: return adapterKind.rawValue
    }
}

/// Test helper: reset registry and register defaults.
public enum ProviderTestSupport {
    public static func registerDefaultsForTesting(
        inferenceRuntimes: [InferenceRuntimeConfig]? = nil
    ) {
        ProviderRegistry.withExclusiveRegistryAccess {
            ProviderResourceBundle.setResourceBundle(SwiftAgentHarnessProvidersResources.bundle)
            if hasBundledDefaultsRegistered(includingInferenceRuntimes: inferenceRuntimes) {
                return
            }
            resetAndRegisterDefaultsUnlocked(inferenceRuntimes: inferenceRuntimes)
        }
    }

    /// Runs a test body against a custom registry state and restores bundled defaults afterward.
    public static func withRegistryIsolation<R>(
        inferenceRuntimes: [InferenceRuntimeConfig]? = nil,
        _ body: () throws -> R
    ) rethrows -> R {
        let restoreRuntimes = inferenceRuntimes ?? defaultTestInferenceRuntimes
        return try ProviderRegistry.withExclusiveRegistryAccess {
            defer { resetAndRegisterDefaultsUnlocked(inferenceRuntimes: restoreRuntimes) }
            return try body()
        }
    }

    private static func hasBundledDefaultsRegistered(
        includingInferenceRuntimes inferenceRuntimes: [InferenceRuntimeConfig]?
    ) -> Bool {
        let ids = Set(ProviderRegistry.allManifests().map(\.id))
        let frontier: Set<ProviderID> = ["openai", "anthropic", "openrouter"]
        guard frontier.isSubset(of: ids) else { return false }
        let expectedRuntimes = inferenceRuntimes ?? defaultTestInferenceRuntimes
        return expectedRuntimes.allSatisfy { ids.contains($0.providerID) }
    }

    private static func resetAndRegisterDefaultsUnlocked(
        inferenceRuntimes: [InferenceRuntimeConfig]?
    ) {
        ProviderResourceBundle.setResourceBundle(SwiftAgentHarnessProvidersResources.bundle)
        ProviderRegistry.resetForTesting()
        ProviderLifecycle.resetForTesting()
        ProviderAdapterFactoryRegistry.resetForTesting()
        let runtimes = inferenceRuntimes ?? defaultTestInferenceRuntimes
        registerDefaults(options: .init(installBootstrapHook: true, inferenceRuntimes: runtimes))
        ProviderRegistry.markBootstrapCompleteForTesting()
    }

    /// Shared test fixture runtimes (ollama + lmstudio adapter kinds with catalog overlays).
    /// Hosts should supply their own; tests use this stand-in for the former Constants maps.
    public static var defaultTestInferenceRuntimes: [InferenceRuntimeConfig] {
        // Defined in the test target when available; Providers target needs a fallback for
        // registerDefaultsForTesting called from production test helpers in this module.
        [
            InferenceRuntimeConfig(
                providerID: "ollama",
                label: "Ollama",
                adapterKind: .ollama,
                serverURL: URL(string: "http://localhost:11434")!,
                modelIDMap: [:]
            ),
            InferenceRuntimeConfig(
                providerID: "lmstudio",
                label: "LM Studio",
                adapterKind: .lmStudio,
                serverURL: URL(string: "http://localhost:1234")!,
                modelIDMap: [:]
            ),
        ]
    }

    /// Credential profiles for bundled providers whose discovery uses static catalogs only (no live probes).
    public static func authStoreWithAllProvidersRegistered() -> AuthProfileStore {
        AuthProfileStore(
            environment: [:],
            seedProfiles: [
                AuthProfile(id: "openai-test", providerID: "openai", authType: .apiKey, apiKey: "test-key"),
                AuthProfile(id: "anthropic-test", providerID: "anthropic", authType: .apiKey, apiKey: "test-key"),
            ]
        )
    }

    /// Includes OpenRouter (may probe the network during discovery — avoid in unit tests).
    public static func authStoreWithNetworkDiscoveryProvidersRegistered() -> AuthProfileStore {
        var profiles = authStoreWithAllProvidersRegistered().seedProfiles
        profiles.append(
            AuthProfile(id: "openrouter-test", providerID: "openrouter", authType: .apiKey, apiKey: "test-key")
        )
        return AuthProfileStore(environment: [:], seedProfiles: profiles)
    }

    /// Registers API-server providers without triggering live network discovery in tests.
    public static func authStoreWithLocalProvidersRegistered(
        inferenceRuntimes: [InferenceRuntimeConfig]? = nil
    ) -> AuthProfileStore {
        var profiles = authStoreWithAllProvidersRegistered().seedProfiles
        let runtimes = inferenceRuntimes ?? defaultTestInferenceRuntimes
        for runtime in runtimes {
            profiles.append(
                AuthProfile(
                    id: "\(runtime.providerID)-local",
                    providerID: runtime.providerID,
                    authType: .local,
                    baseURL: runtime.serverURL
                )
            )
        }
        return AuthProfileStore(environment: [:], seedProfiles: profiles)
    }
}
