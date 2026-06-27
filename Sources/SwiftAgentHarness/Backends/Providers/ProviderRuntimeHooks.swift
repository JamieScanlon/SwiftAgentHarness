import Foundation
import SwiftAgentKit

/// Runtime hooks invoked by the Model Pool at dispatch time.
public enum ProviderRuntimeHooks {
    public static func normalizeTools(
        _ tools: [ToolDefinition],
        binding: ProviderBinding?,
        strictMode: Bool = false
    ) -> [ToolDefinition] {
        guard let binding else { return tools }
        ProviderRegistry.bootstrapBuiltInsIfNeeded()
        guard let provider = ProviderRegistry.textInferenceProvider(forBinding: binding) else {
            return tools
        }
        return provider.normalizeToolSchemas(
            tools,
            context: ProviderToolNormalizationContext(
                providerID: provider.manifest.id,
                endpointModelId: binding.endpointModelId,
                strictMode: strictMode
            )
        )
    }

    public static func systemPromptContribution(
        binding: ProviderBinding?
    ) -> ProviderSystemPromptContribution? {
        guard let binding else { return nil }
        ProviderRegistry.bootstrapBuiltInsIfNeeded()
        guard let provider = ProviderRegistry.textInferenceProvider(forBinding: binding) else {
            return nil
        }
        return provider.resolveSystemPromptContribution(
            ProviderSystemPromptContext(
                providerID: provider.manifest.id,
                endpointModelId: binding.endpointModelId
            )
        )
    }

    public static func failoverClassification(
        error: Error,
        providerID: ProviderID?
    ) -> ProviderFailoverClassification {
        if let providerID,
           let provider = ProviderRegistry.textInferenceProvider(for: providerID) {
            return provider.failoverError(error)
        }
        return DefaultProviderFailoverClassifier.classify(error)
    }
}
