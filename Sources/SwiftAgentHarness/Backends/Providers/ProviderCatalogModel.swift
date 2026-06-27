import Foundation
import Logging
import SwiftAgentKit

public enum ProviderCacheTTLEligibility: String, Sendable, Codable, Hashable {
    case none
    case short
    case long
}

public struct ProviderModelCompat: Sendable, Equatable, Hashable, Codable {
    public var supportsEagerToolInputStreaming: Bool?
    public var thinkingFormat: String?

    public init(
        supportsEagerToolInputStreaming: Bool? = nil,
        thinkingFormat: String? = nil
    ) {
        self.supportsEagerToolInputStreaming = supportsEagerToolInputStreaming
        self.thinkingFormat = thinkingFormat
    }
}

/// Static or dynamic catalog row contributed by a provider plugin.
public struct ProviderCatalogEntry: Sendable {
    public var registryID: UUID
    public var endpointModelId: String
    public var displayName: String?
    public var modelConfig: ModelConfig
    public var maxContextLength: Int?
    public var maxOutputTokens: Int?
    public var capabilities: Set<LLMCapability>?
    public var compat: ProviderModelCompat?

    public init(
        registryID: UUID,
        endpointModelId: String,
        displayName: String? = nil,
        modelConfig: ModelConfig,
        maxContextLength: Int? = nil,
        maxOutputTokens: Int? = nil,
        capabilities: Set<LLMCapability>? = nil,
        compat: ProviderModelCompat? = nil
    ) {
        self.registryID = registryID
        self.endpointModelId = endpointModelId
        self.displayName = displayName
        self.modelConfig = modelConfig
        self.maxContextLength = maxContextLength
        self.maxOutputTokens = maxOutputTokens
        self.capabilities = capabilities
        self.compat = compat
    }

    public func toRegistryEntry(
        providerID: ProviderID,
        serverURL: URL,
        authProfile: String? = nil,
        priority: Int = 0
    ) -> ModelRegistryEntry {
        let binding = ProviderBinding(
            providerId: providerID,
            modelProtocol: modelConfig.modelProtocol,
            endpointModelId: endpointModelId,
            serverURL: serverURL,
            priority: priority,
            authProfile: authProfile
        )
        return ModelRegistryEntry(
            id: registryID,
            family: providerID,
            displayName: displayName ?? endpointModelId,
            capabilities: capabilities ?? Set(modelConfig.hardcodedCapabilities),
            requestFeatures: ModelManager.mergedRequestFeaturesFromConfig(modelConfig),
            maxContextLength: maxContextLength,
            maxOutputTokens: maxOutputTokens,
            providers: [binding],
            useClasses: [],
            cost: modelConfig.hardcodedCost,
            routing: modelConfig.hardcodedRouting
                ?? ModelManager.defaultRoutingMetadata(for: modelConfig.modelProtocol)
        )
    }
}

public struct ProviderDynamicModelContext: Sendable {
    public var endpointModelId: String
    public var serverURL: URL

    public init(endpointModelId: String, serverURL: URL) {
        self.endpointModelId = endpointModelId
        self.serverURL = serverURL
    }
}

public struct ProviderToolNormalizationContext: Sendable {
    public var providerID: ProviderID
    public var endpointModelId: String
    public var strictMode: Bool

    public init(providerID: ProviderID, endpointModelId: String, strictMode: Bool = false) {
        self.providerID = providerID
        self.endpointModelId = endpointModelId
        self.strictMode = strictMode
    }
}

public enum ProviderNamedSection: String, Sendable, Codable, Hashable, CaseIterable {
    case interactionStyle = "interaction_style"
    case toolCallStyle = "tool_call_style"
    case executionBias = "execution_bias"
}

public struct ProviderSystemPromptContribution: Sendable, Equatable {
    public var stablePrefix: String?
    public var sectionOverrides: [ProviderNamedSection: String]

    public init(
        stablePrefix: String? = nil,
        sectionOverrides: [ProviderNamedSection: String] = [:]
    ) {
        self.stablePrefix = stablePrefix
        self.sectionOverrides = sectionOverrides
    }
}

public struct ProviderSystemPromptContext: Sendable {
    public var providerID: ProviderID
    public var endpointModelId: String

    public init(providerID: ProviderID, endpointModelId: String) {
        self.providerID = providerID
        self.endpointModelId = endpointModelId
    }
}

public struct ProviderAdapterContext: Sendable {
    public var binding: ProviderBinding
    public var model: Model
    public var systemPrompt: SystemPrompt
    public var authProfileStore: AuthProfileStore
    public var logger: Logger?

    public init(
        binding: ProviderBinding,
        model: Model,
        systemPrompt: SystemPrompt,
        authProfileStore: AuthProfileStore = .production(),
        logger: Logger? = nil
    ) {
        self.binding = binding
        self.model = model
        self.systemPrompt = systemPrompt
        self.authProfileStore = authProfileStore
        self.logger = logger
    }
}
