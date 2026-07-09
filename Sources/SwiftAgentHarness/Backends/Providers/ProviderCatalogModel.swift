import Foundation
import Logging
import SwiftAgentKit

public enum ProviderCacheTTLEligibility: String, Sendable, Codable, Hashable {
    case none
    case short
    case long
}

public enum ToolSchemaMode: String, Sendable, Codable, Hashable {
    case permissive
    case openAIStrict
    case grammarConstrained
    case googleStripped
}

public struct ToolSchemaCompatProfile: Sendable, Equatable, Hashable, Codable {
    public var toolSchemaMode: ToolSchemaMode
    public var stripKeywords: [String]?

    public init(
        toolSchemaMode: ToolSchemaMode = .permissive,
        stripKeywords: [String]? = nil
    ) {
        self.toolSchemaMode = toolSchemaMode
        self.stripKeywords = stripKeywords
    }
}

public struct ProviderModelCompat: Sendable, Equatable, Hashable, Codable {
    public var supportsEagerToolInputStreaming: Bool?
    public var thinkingFormat: String?
    public var toolSchemaProfile: ToolSchemaCompatProfile?

    public init(
        supportsEagerToolInputStreaming: Bool? = nil,
        thinkingFormat: String? = nil,
        toolSchemaProfile: ToolSchemaCompatProfile? = nil
    ) {
        self.supportsEagerToolInputStreaming = supportsEagerToolInputStreaming
        self.thinkingFormat = thinkingFormat
        self.toolSchemaProfile = toolSchemaProfile
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
    public var canonicalModelKey: String?
    public var modelFamily: String?

    public init(
        registryID: UUID,
        endpointModelId: String,
        displayName: String? = nil,
        modelConfig: ModelConfig,
        maxContextLength: Int? = nil,
        maxOutputTokens: Int? = nil,
        capabilities: Set<LLMCapability>? = nil,
        compat: ProviderModelCompat? = nil,
        canonicalModelKey: String? = nil,
        modelFamily: String? = nil
    ) {
        self.registryID = registryID
        self.endpointModelId = endpointModelId
        self.displayName = displayName
        self.modelConfig = modelConfig
        self.maxContextLength = maxContextLength
        self.maxOutputTokens = maxOutputTokens
        self.capabilities = capabilities
        self.compat = compat
        self.canonicalModelKey = canonicalModelKey ?? modelConfig.canonicalModelKey
        self.modelFamily = modelFamily ?? modelConfig.modelFamily
    }

    public func toRegistryEntry(
        providerID: ProviderID,
        serverURL: URL,
        authProfile: String? = nil,
        priority: Int = 0,
        toolChoiceModesOverride: Set<ToolChoiceMode>? = nil
    ) -> ModelRegistryEntry {
        let entryCost = modelConfig.hardcodedCost
        let entryRouting = modelConfig.hardcodedRouting
            ?? ModelManager.defaultRoutingMetadata(for: modelConfig.modelProtocol)
        let binding = ProviderBinding(
            providerId: providerID,
            modelProtocol: modelConfig.modelProtocol,
            endpointModelId: endpointModelId,
            serverURL: serverURL,
            priority: priority,
            authProfile: authProfile,
            toolChoiceModesOverride: toolChoiceModesOverride,
            cost: entryCost,
            routing: entryRouting
        )
        let resolvedKey = canonicalModelKey
        let resolvedFamily = modelFamily ?? resolvedKey.flatMap(LogicalModelKey.inferredFamily(from:))
        return ModelRegistryEntry(
            id: registryID,
            family: resolvedFamily,
            displayName: displayName ?? endpointModelId,
            capabilities: capabilities ?? Set(modelConfig.hardcodedCapabilities),
            requestFeatures: ModelManager.mergedRequestFeaturesFromConfig(modelConfig),
            maxContextLength: maxContextLength,
            maxOutputTokens: maxOutputTokens,
            providers: [binding],
            useClasses: [],
            cost: entryCost,
            routing: entryRouting,
            compat: compat,
            canonicalModelKey: resolvedKey
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
    public var resolvedCredential: AuthProfile?
    public var compat: ProviderModelCompat?
    public var logger: Logger?

    public var supportsEagerToolInputStreaming: Bool {
        ProviderRuntimeHooks.effectiveSupportsEagerToolInputStreaming(
            binding: binding,
            compat: compat
        )
    }

    public init(
        binding: ProviderBinding,
        model: Model,
        systemPrompt: SystemPrompt,
        authProfileStore: AuthProfileStore = .production(),
        resolvedCredential: AuthProfile? = nil,
        compat: ProviderModelCompat? = nil,
        logger: Logger? = nil
    ) {
        self.binding = binding
        self.model = model
        self.systemPrompt = systemPrompt
        self.authProfileStore = authProfileStore
        self.resolvedCredential = resolvedCredential
        self.compat = compat
        self.logger = logger
    }
}
