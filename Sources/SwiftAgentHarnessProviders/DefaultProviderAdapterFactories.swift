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
    let adapterKind = ProviderAdapterKind.openAICompat.rawValue

    func makeRegistration(manifest: ProviderManifest, config: ProviderInstanceConfig) throws -> ProviderRegistration {
        let merged = try config.mergedManifest(base: manifest)
        return ProviderRegistration(
            manifest: merged,
            textInference: GenericOpenAICompatProvider(manifest: merged, config: config)
        )
    }
}

private struct AnthropicAdapterFactory: ProviderAdapterFactory {
    let adapterKind = ProviderAdapterKind.anthropic.rawValue

    func makeRegistration(manifest: ProviderManifest, config: ProviderInstanceConfig) throws -> ProviderRegistration {
        let merged = try config.mergedManifest(base: manifest)
        return ProviderRegistration(
            manifest: merged,
            textInference: AnthropicTextInferenceProvider(manifest: merged)
        )
    }
}

private struct OllamaAdapterFactory: ProviderAdapterFactory {
    let adapterKind = ProviderAdapterKind.ollama.rawValue

    func makeRegistration(manifest: ProviderManifest, config: ProviderInstanceConfig) throws -> ProviderRegistration {
        let merged = try config.mergedManifest(base: manifest)
        let runtime = InferenceRuntimeConfig.from(instanceConfig: config, mergedManifest: merged)
        return ProviderRegistration(
            manifest: merged,
            textInference: OllamaTextInferenceProvider(manifest: merged, runtime: runtime)
        )
    }
}

private struct LMStudioAdapterFactory: ProviderAdapterFactory {
    let adapterKind = ProviderAdapterKind.lmStudio.rawValue

    func makeRegistration(manifest: ProviderManifest, config: ProviderInstanceConfig) throws -> ProviderRegistration {
        let merged = try config.mergedManifest(base: manifest)
        let runtime = InferenceRuntimeConfig.from(instanceConfig: config, mergedManifest: merged)
        return ProviderRegistration(
            manifest: merged,
            textInference: LMStudioTextInferenceProvider(manifest: merged, runtime: runtime)
        )
    }
}

private struct OpenRouterAdapterFactory: ProviderAdapterFactory {
    let adapterKind = ProviderAdapterKind.openRouter.rawValue

    func makeRegistration(manifest: ProviderManifest, config: ProviderInstanceConfig) throws -> ProviderRegistration {
        let merged = try config.mergedManifest(base: manifest)
        return ProviderRegistration(
            manifest: merged,
            textInference: OpenRouterTextInferenceProvider(manifest: merged)
        )
    }
}

extension InferenceRuntimeConfig {
    /// Builds a runtime config from a configuration-plugin instance + merged manifest.
    static func from(instanceConfig: ProviderInstanceConfig, mergedManifest: ProviderManifest) -> InferenceRuntimeConfig {
        let serverURL = mergedManifest.providerEndpoints.first?.baseURL
            ?? URL(string: "http://127.0.0.1")!
        var modelIDMap: [String: ModelConfig] = [:]
        if let entries = instanceConfig.resolvedCatalogEntries() {
            for entry in entries {
                modelIDMap[entry.endpointModelId] = entry.modelConfig
            }
        }
        return InferenceRuntimeConfig(
            providerID: mergedManifest.id,
            label: mergedManifest.label,
            adapterKind: ProviderAdapterKind(rawValue: instanceConfig.adapterKind),
            serverURL: serverURL,
            modelIDMap: modelIDMap
        )
    }
}
