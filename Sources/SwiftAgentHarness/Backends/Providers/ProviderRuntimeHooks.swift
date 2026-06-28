import Foundation
import Logging
import SwiftAgentKit

/// Runtime hooks invoked by the Model Pool at dispatch time.
public enum ProviderRuntimeHooks {
    public static func normalizeTools(
        _ tools: [ToolDefinition],
        binding: ProviderBinding?,
        strictMode: Bool = false
    ) -> [ToolDefinition] {
        guard let binding else { return tools }
        ProviderRegistry.ensureBootstrapped()
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
        ProviderRegistry.ensureBootstrapped()
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
        ProviderRegistry.ensureBootstrapped()
        if let providerID,
           let provider = ProviderRegistry.textInferenceProvider(for: providerID) {
            return provider.failoverError(error)
        }
        return DefaultProviderFailoverClassifier.classify(error)
    }

    public static func compatForBinding(_ binding: ProviderBinding) -> ProviderModelCompat? {
        guard let entries = try? ProviderCatalogLoader.decodeBundledCatalog(for: binding.providerId) else {
            return nil
        }
        return entries.first(where: { $0.endpointModelId == binding.endpointModelId })?.compat
    }

    public static func effectiveSupportsEagerToolInputStreaming(
        binding: ProviderBinding,
        compat: ProviderModelCompat?
    ) -> Bool {
        if let supportsEagerToolInputStreaming = compat?.supportsEagerToolInputStreaming {
            return supportsEagerToolInputStreaming
        }
        switch binding.providerId {
        case "anthropic":
            return true
        default:
            return false
        }
    }

    public static func transformMessages(
        _ messages: [Message],
        binding: ProviderBinding,
        compat: ProviderModelCompat? = nil,
        targetCapabilities: Set<LLMCapability> = []
    ) -> [Message] {
        ProviderRegistry.ensureBootstrapped()
        guard let provider = ProviderRegistry.textInferenceProvider(forBinding: binding) else {
            return messages
        }
        let resolvedCompat = compat ?? compatForBinding(binding)
        return provider.transformMessages(
            messages,
            context: ProviderMessageTransformContext(
                binding: binding,
                compat: resolvedCompat,
                targetCapabilities: targetCapabilities
            )
        )
    }

    public static func validateReplayTurns(
        _ messages: [Message],
        binding: ProviderBinding,
        compat: ProviderModelCompat? = nil,
        targetCapabilities: Set<LLMCapability> = [],
        logger: Logger? = nil
    ) -> [ProviderReplayValidationIssue] {
        ProviderRegistry.ensureBootstrapped()
        guard let provider = ProviderRegistry.textInferenceProvider(forBinding: binding) else {
            return []
        }
        let resolvedCompat = compat ?? compatForBinding(binding)
        let issues = provider.validateReplayTurns(
            messages,
            context: ProviderReplayTurnContext(
                binding: binding,
                compat: resolvedCompat,
                targetCapabilities: targetCapabilities
            )
        )
        for issue in issues {
            switch issue.severity {
            case .warning:
                logger?.warning("[ProviderRuntimeHooks] replay validation \(issue.code): \(issue.message)")
            case .error:
                logger?.error("[ProviderRuntimeHooks] replay validation \(issue.code): \(issue.message)")
            }
        }
        return issues
    }

    public static func prepareDynamicModel(
        binding: ProviderBinding,
        catalogEntry: ProviderCatalogEntry
    ) async -> ProviderCatalogEntry {
        ProviderRegistry.ensureBootstrapped()
        guard let provider = ProviderRegistry.textInferenceProvider(forBinding: binding) else {
            return catalogEntry
        }
        if let prepared = await provider.prepareDynamicModel(
            ProviderDynamicPrepareContext(binding: binding, catalogEntry: catalogEntry)
        ) {
            return prepared
        }
        return catalogEntry
    }

    public static func preferRuntimeResolvedModel(binding: ProviderBinding) -> Bool {
        ProviderRegistry.ensureBootstrapped()
        guard let provider = ProviderRegistry.textInferenceProvider(forBinding: binding) else {
            return false
        }
        return provider.preferRuntimeResolvedModel(
            ProviderDynamicModelPreferenceContext(
                binding: binding,
                endpointModelId: binding.endpointModelId
            )
        )
    }
}
