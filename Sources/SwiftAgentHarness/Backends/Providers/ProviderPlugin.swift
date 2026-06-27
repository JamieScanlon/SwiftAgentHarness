import Foundation
import Logging
import SwiftAgentKit

/// Text-inference provider runtime contract (spec: ProviderPlugin wire codec + hooks).
public protocol TextInferenceProviding: Sendable {
    var manifest: ProviderManifest { get }
    var modelProtocol: ModelProtocol { get }

    func staticCatalogEntries() -> [ProviderCatalogEntry]
    func resolveDynamicModel(_ context: ProviderDynamicModelContext) async -> ProviderCatalogEntry?
    func discoverEntries(logger: Logger?) async -> [ModelRegistryEntry]
    func normalizeProviderModelId(_ raw: String) -> String
    func makeAdapter(context: ProviderAdapterContext) -> any LLMProtocol
    func normalizeToolSchemas(_ tools: [ToolDefinition], context: ProviderToolNormalizationContext) -> [ToolDefinition]
    func resolveSystemPromptContribution(_ context: ProviderSystemPromptContext) -> ProviderSystemPromptContribution?
    func cacheTtlEligibility(_ context: ProviderSystemPromptContext) -> ProviderCacheTTLEligibility
    func failoverError(_ error: Error) -> ProviderFailoverClassification
}

public extension TextInferenceProviding {
    func normalizeProviderModelId(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func resolveDynamicModel(_ context: ProviderDynamicModelContext) async -> ProviderCatalogEntry? {
        nil
    }

    func normalizeToolSchemas(
        _ tools: [ToolDefinition],
        context: ProviderToolNormalizationContext
    ) -> [ToolDefinition] {
        ProviderToolSchemaNormalizer.normalize(tools, providerID: manifest.id, strictMode: context.strictMode)
    }

    func resolveSystemPromptContribution(_ context: ProviderSystemPromptContext) -> ProviderSystemPromptContribution? {
        nil
    }

    func cacheTtlEligibility(_ context: ProviderSystemPromptContext) -> ProviderCacheTTLEligibility {
        .none
    }

    func failoverError(_ error: Error) -> ProviderFailoverClassification {
        DefaultProviderFailoverClassifier.classify(error)
    }

    func discoverEntries(logger: Logger?) async -> [ModelRegistryEntry] {
        guard let endpoint = manifest.defaultEndpoint else { return [] }
        return staticCatalogEntries().map {
            $0.toRegistryEntry(providerID: manifest.id, serverURL: endpoint.baseURL)
        }
    }
}

public struct ProviderRegistration: Sendable {
    public let manifest: ProviderManifest
    public let textInference: (any TextInferenceProviding)?

    public init(manifest: ProviderManifest, textInference: (any TextInferenceProviding)? = nil) {
        self.manifest = manifest
        self.textInference = textInference
    }
}

public enum ProviderRegistryError: Error, Equatable, Sendable {
    case notRegistered(ProviderID)
    case slotUnavailable(ProviderCapabilitySlot, providerID: ProviderID)
}
