import Foundation
import SwiftAgentHarness

public enum DefaultProviderAdapterFactories {
    public static func installAll() {
        ProviderAdapterFactoryRegistry.register(OpenAICompatAdapterFactory())
        ProviderAdapterFactoryRegistry.register(AnthropicAdapterFactory())
        ProviderAdapterFactoryRegistry.register(OllamaAdapterFactory())
        ProviderAdapterFactoryRegistry.register(LMStudioAdapterFactory())
        ProviderAdapterFactoryRegistry.register(OpenRouterAdapterFactory())
    }
}

private struct OpenAICompatAdapterFactory: ProviderAdapterFactory {
    let adapterKind = "openai-compat"

    func makeRegistration(manifest: ProviderManifest, config: ProviderInstanceConfig) throws -> ProviderRegistration {
        let merged = try config.mergedManifest(base: manifest)
        return ProviderRegistration(
            manifest: merged,
            textInference: GenericOpenAICompatProvider(manifest: merged, config: config)
        )
    }
}

private struct AnthropicAdapterFactory: ProviderAdapterFactory {
    let adapterKind = "anthropic"

    func makeRegistration(manifest: ProviderManifest, config: ProviderInstanceConfig) throws -> ProviderRegistration {
        let merged = try config.mergedManifest(base: manifest)
        return ProviderRegistration(
            manifest: merged,
            textInference: AnthropicTextInferenceProvider(manifest: merged)
        )
    }
}

private struct OllamaAdapterFactory: ProviderAdapterFactory {
    let adapterKind = "ollama"

    func makeRegistration(manifest: ProviderManifest, config: ProviderInstanceConfig) throws -> ProviderRegistration {
        let merged = try config.mergedManifest(base: manifest)
        return ProviderRegistration(
            manifest: merged,
            textInference: OllamaTextInferenceProvider(manifest: merged)
        )
    }
}

private struct LMStudioAdapterFactory: ProviderAdapterFactory {
    let adapterKind = "lmstudio"

    func makeRegistration(manifest: ProviderManifest, config: ProviderInstanceConfig) throws -> ProviderRegistration {
        let merged = try config.mergedManifest(base: manifest)
        return ProviderRegistration(
            manifest: merged,
            textInference: LMStudioTextInferenceProvider(manifest: merged)
        )
    }
}

private struct OpenRouterAdapterFactory: ProviderAdapterFactory {
    let adapterKind = "openrouter"

    func makeRegistration(manifest: ProviderManifest, config: ProviderInstanceConfig) throws -> ProviderRegistration {
        let merged = try config.mergedManifest(base: manifest)
        return ProviderRegistration(
            manifest: merged,
            textInference: OpenRouterTextInferenceProvider(manifest: merged)
        )
    }
}
