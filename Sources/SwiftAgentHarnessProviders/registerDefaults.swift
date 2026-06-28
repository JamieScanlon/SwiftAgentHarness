import Foundation
import SwiftAgentHarness

public struct DefaultProviderOptions: Sendable {
    public var installBootstrapHook: Bool

    public init(installBootstrapHook: Bool = true) {
        self.installBootstrapHook = installBootstrapHook
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
    ProviderResourceBundle.setResourceBundle(.module)
    DefaultProviderAdapterFactories.installAll()
    if options.installBootstrapHook {
        ProviderRegistry.installBootstrap { registerDefaults(options: .init(installBootstrapHook: false)) }
    }
    try? registerOpenAI()
    try? registerAnthropic()
    try? registerOllama()
    try? registerLMStudio()
    try? registerOpenRouter()
}

/// Convenience for app startup: sets resource bundle, installs bootstrap hook, and registers defaults.
public func bootstrap() {
    registerDefaults()
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

private func registerOllama() throws {
    let manifest = try BundledProviderManifestLoader.loadManifest(for: "ollama")
    try ProviderRegistry.register(ProviderRegistration(
        manifest: manifest,
        textInference: OllamaTextInferenceProvider(manifest: manifest)
    ))
}

private func registerLMStudio() throws {
    let manifest = try BundledProviderManifestLoader.loadManifest(for: "lmstudio")
    try ProviderRegistry.register(ProviderRegistration(
        manifest: manifest,
        textInference: LMStudioTextInferenceProvider(manifest: manifest)
    ))
}

private func registerOpenRouter() throws {
    let manifest = try BundledProviderManifestLoader.loadManifest(for: "openrouter")
    try ProviderRegistry.register(ProviderRegistration(
        manifest: manifest,
        textInference: OpenRouterTextInferenceProvider(manifest: manifest)
    ))
}

/// Test helper: reset registry and register defaults.
public enum ProviderTestSupport {
    public static func registerDefaultsForTesting() {
        ProviderRegistry.resetForTesting()
        ProviderLifecycle.resetForTesting()
        ProviderAdapterFactoryRegistry.resetForTesting()
        registerDefaults(options: .init(installBootstrapHook: true))
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

    /// Registers local providers without triggering live network discovery in tests.
    public static func authStoreWithLocalProvidersRegistered() -> AuthProfileStore {
        var profiles = authStoreWithAllProvidersRegistered().seedProfiles
        profiles.append(contentsOf: [
            AuthProfile(
                id: "ollama-local",
                providerID: "ollama",
                authType: .local,
                baseURL: Constants.ollamaServerURL
            ),
            AuthProfile(
                id: "lmstudio-local",
                providerID: "lmstudio",
                authType: .local,
                baseURL: Constants.lmStudioServerURL
            ),
        ])
        return AuthProfileStore(environment: [:], seedProfiles: profiles)
    }
}
