import Foundation
import Logging
import SwiftAgentKit

/// Runtime hooks invoked by the Model Pool at dispatch time.
public enum ProviderRuntimeHooks {
    public static func toolSchemaCompatProfile(
        binding: ProviderBinding,
        compat: ProviderModelCompat? = nil
    ) -> ToolSchemaCompatProfile {
        if let profile = compat?.toolSchemaProfile {
            return profile
        }
        switch binding.providerId {
        case "openai":
            if openAIModelSupportsStrictTools(binding.endpointModelId) {
                return ToolSchemaCompatProfile(toolSchemaMode: .openAIStrict)
            }
            return ToolSchemaCompatProfile(toolSchemaMode: .permissive)
        case "ollama", "lmstudio":
            return ToolSchemaCompatProfile(toolSchemaMode: .grammarConstrained)
        default:
            return ToolSchemaCompatProfile(toolSchemaMode: .permissive)
        }
    }

    static func normalizeToolSchemaBatch(
        entries: [ToolRegistryEntry],
        binding: ProviderBinding?,
        compat: ProviderModelCompat? = nil
    ) -> ProviderToolSchemaBatchResult {
        guard let binding else { return .empty }
        let profile = toolSchemaCompatProfile(binding: binding, compat: compat ?? compatForBinding(binding))
        return ProviderToolSchemaTransform.normalize(entries: entries, profile: profile)
    }

    public static func logToolSchemaDiagnostics(
        _ diagnostics: [ToolSchemaNormalizationDiagnostic],
        logger: Logger?
    ) {
        for diagnostic in diagnostics {
            switch diagnostic.severity {
            case .warning:
                logger?.warning("[ProviderRuntimeHooks] \(diagnostic.logLine)")
            case .error:
                logger?.error("[ProviderRuntimeHooks] \(diagnostic.logLine)")
            }
        }
    }

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
        if let provider = ProviderRegistry.textInferenceProvider(forBinding: binding),
           let pluginContribution = provider.resolveSystemPromptContribution(
               ProviderSystemPromptContext(
                   providerID: provider.manifest.id,
                   endpointModelId: binding.endpointModelId
               )
           ) {
            return pluginContribution
        }
        return ProviderCatalogLoader.systemPromptContribution(for: binding)
    }

    public static func cacheTtlEligibility(binding: ProviderBinding?) -> ProviderCacheTTLEligibility {
        guard let binding else { return .none }
        ProviderRegistry.ensureBootstrapped()
        guard let provider = ProviderRegistry.textInferenceProvider(forBinding: binding) else {
            return .none
        }
        return provider.cacheTtlEligibility(
            ProviderSystemPromptContext(
                providerID: provider.manifest.id,
                endpointModelId: binding.endpointModelId
            )
        )
    }

    public static func selectPromptCacheBreakpoints(
        candidates: [PromptCacheBreakpointCandidate],
        binding: ProviderBinding?,
        capabilities: [LLMCapability],
        strategy: PromptCacheStrategy,
        messages: [Message]
    ) -> ProviderPromptCacheBreakpointPlan {
        guard let binding else { return .empty }
        ProviderRegistry.ensureBootstrapped()
        guard let provider = ProviderRegistry.textInferenceProvider(forBinding: binding) else {
            return selectPromptCacheBreakpoints(
                candidates: candidates,
                binding: binding,
                capabilities: capabilities,
                strategy: strategy,
                messages: messages
            )
        }
        let eligibility = provider.cacheTtlEligibility(
            ProviderSystemPromptContext(
                providerID: provider.manifest.id,
                endpointModelId: binding.endpointModelId
            )
        )
        return provider.selectPromptCacheBreakpoints(
            candidates,
            context: ProviderPromptCacheBreakpointContext(
                binding: binding,
                capabilities: capabilities,
                cacheTtlEligibility: eligibility,
                strategy: strategy,
                messages: messages
            )
        )
    }

    private static func selectPromptCacheBreakpoints(
        candidates: [PromptCacheBreakpointCandidate],
        binding: ProviderBinding,
        capabilities: [LLMCapability],
        strategy: PromptCacheStrategy,
        messages: [Message]
    ) -> ProviderPromptCacheBreakpointPlan {
        let eligibility = cacheTtlEligibility(binding: binding)
        let context = ProviderPromptCacheBreakpointContext(
            binding: binding,
            capabilities: capabilities,
            cacheTtlEligibility: eligibility,
            strategy: strategy,
            messages: messages
        )
        switch binding.modelProtocol {
        case .anthropic:
            return PromptCacheBreakpointSelectionPolicy.anthropic(candidates: candidates, context: context)
        case .lmStudio:
            return PromptCacheBreakpointSelectionPolicy.lmStudio(candidates: candidates, context: context)
        case .openAIAPI, .ollama:
            return PromptCacheBreakpointSelectionPolicy.implicit(candidates: candidates, context: context)
        }
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

    private static func openAIModelSupportsStrictTools(_ modelId: String) -> Bool {
        let normalized = modelId.lowercased()
        let prefixes = ["gpt-4.1", "gpt-4o", "o1", "o3", "o4"]
        return prefixes.contains { normalized.hasPrefix($0) }
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
        case "anthropic", "openai":
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
