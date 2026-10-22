import Foundation
import SwiftAgentKit

/// Model lifecycle (spec: `ModelEntry.lifecycle`).
public struct ModelLifecycle: Sendable, Codable, Hashable {
    public enum Status: String, Sendable, Codable, Hashable {
        case preview
        case active
        case deprecated
        case retired
    }

    public var status: Status
    public var retiresAt: Date?
    /// Set when this id is a moving alias. Aliases never carry tuned thresholds.
    public var aliasOf: String?
    /// Vendor aliases (e.g. `vendor-latest`) known to point at this pinned version. They select this entry as pins
    /// and lookup names, but are never sent on the wire and never carry tuned thresholds.
    public var aliases: [String]

    public init(status: Status = .active, retiresAt: Date? = nil, aliasOf: String? = nil, aliases: [String] = []) {
        self.status = status
        self.retiresAt = retiresAt
        self.aliasOf = aliasOf
        self.aliases = aliases
    }

    public static let active = ModelLifecycle()

    private enum CodingKeys: String, CodingKey {
        case status, retiresAt, aliasOf, aliases
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(Status.self, forKey: .status)
        retiresAt = try container.decodeIfPresent(Date.self, forKey: .retiresAt)
        aliasOf = try container.decodeIfPresent(String.self, forKey: .aliasOf)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }

    /// Whether `id` follows a moving-alias naming pattern (`*-latest`, `*-preview`).
    public static func looksLikeMovingAlias(_ id: String) -> Bool {
        let lowered = id.lowercased()
        return lowered == "latest" || lowered.hasSuffix("-latest") || lowered.hasSuffix("-preview")
    }
}

/// Where a model runs, used by role locality filters (spec: `Locality`).
public enum ModelLocality: String, Sendable, Codable, Hashable {
    case local
    case vendor
    /// Hosted, with a no-retention agreement for request content.
    case vendorNoRetention = "vendor-no-retention"
}

public extension ModelRegistryEntry {
    /// Effective contract profiles. Entries without explicit ``contracts`` synthesize one `generate` profile from the
    /// legacy chat-shaped fields, so existing rows keep working unchanged.
    var contractProfiles: [ContractProfile] {
        contracts.isEmpty ? [synthesizedGenerateProfile] : contracts
    }

    func profile(for contract: ModelContract) -> ContractProfile? {
        contractProfiles.first { $0.contract == contract }
    }

    func supports(_ contract: ModelContract) -> Bool {
        profile(for: contract) != nil
    }

    /// Whether `version` names a moving alias rather than a pinned version this entry serves: a declared alias, the
    /// entry's own id when it is configured as an alias, or a `*-latest` / `*-preview` id.
    func isAliasName(_ version: String, binding: ProviderBinding) -> Bool {
        if lifecycle.aliases.contains(version) { return true }
        if lifecycle.aliasOf != nil && version == binding.endpointModelId { return true }
        return ModelLifecycle.looksLikeMovingAlias(version)
    }

    /// The profile a specific binding serves: the model profile narrowed by the binding's override, if any.
    func profile(for contract: ModelContract, binding: ProviderBinding) -> ContractProfile? {
        guard let modelProfile = profile(for: contract) else { return nil }
        guard let override = binding.contractOverrides?.first(where: { $0.contract == contract }) else {
            return modelProfile
        }
        return modelProfile.narrowed(by: override)
    }

    /// Effective price vector: explicit ``prices`` first, otherwise the legacy per-1M budget.
    func effectivePrices(binding: ProviderBinding?) -> PriceVector {
        if let bindingPrices = binding?.prices, !bindingPrices.isEmpty { return bindingPrices }
        if !prices.isEmpty { return prices }
        return .fromLegacy(binding?.cost ?? cost)
    }

    /// `generate` profile derived from ``capabilities`` / ``requestFeatures`` / context limits.
    var synthesizedGenerateProfile: ContractProfile {
        var input: [ContractMediaType] = [.text]
        if capabilities.contains(.vision) { input.append(.image) }
        if capabilities.contains(.audio) { input.append(.audio) }
        var output: [ContractMediaType] = [.text]
        if capabilities.contains(.tools) { output.append(.toolCalls) }
        if capabilities.contains(.imageGeneration) { output.append(.image) }

        var interaction: [InteractionPattern] = [.unary]
        if requestFeatures.streaming { interaction.append(.stream(partials: .deltas)) }

        let guarantee: OutputGuarantee
        if requestFeatures.responseFormats.contains(.jsonSchema) {
            guarantee = .schemaStrict
        } else if requestFeatures.responseFormats.contains(.jsonObject) {
            guarantee = .jsonMode
        } else {
            guarantee = .freeText
        }

        var features: [String: FeatureSupport] = [:]
        if capabilities.contains(.tools) { features["tools"] = FeatureSupport() }
        if capabilities.contains(.thinking) { features["reasoning"] = FeatureSupport(params: ["mode": .string("optional")]) }
        if capabilities.contains(.reasoningRequired) {
            features["reasoning"] = FeatureSupport(params: ["mode": .string("required")])
        }
        if capabilities.contains(.promptCacheEphemeral) || capabilities.contains(.promptCachePersistent) {
            features["promptCache"] = FeatureSupport()
        }

        return ContractProfile(
            contract: .generate,
            surface: Self.surface(for: primaryBinding?.modelProtocol),
            interaction: interaction,
            input: input,
            output: output,
            guarantee: guarantee,
            features: features,
            limits: ContractLimits(contextTokens: maxContextLength, maxOutputTokens: maxOutputTokens)
        )
    }

    private static func surface(for modelProtocol: ModelProtocol?) -> ContractSurface {
        switch modelProtocol {
        case .anthropic: return .anthropicMessages
        case .ollama: return .ollamaChat
        case .openAIAPI, .lmStudio, .none: return .openAIChat
        }
    }
}
