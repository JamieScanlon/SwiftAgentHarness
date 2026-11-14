import Foundation
import SwiftAgentKit

/// Role-level trust filter (spec: `RoleBinding.locality`). Enforced as a hard filter, never a preference.
public enum RoleLocality: String, Sendable, Codable, Hashable {
    case any
    case localOnly = "local-only"
    case noVendorRetention = "no-vendor-retention"

    func admits(_ locality: ModelLocality?) -> Bool {
        switch self {
        case .any:
            return true
        case .localOnly:
            return locality == .local
        case .noVendorRetention:
            return locality == .local || locality == .vendorNoRetention
        }
    }
}

/// A feature a query requires: supported, optionally at a specific version.
public struct RequiredFeature: Sendable, Codable, Hashable {
    public var version: String?

    public init(version: String? = nil) {
        self.version = version
    }
}

/// Soft ranking preferences (spec: `ContractQuery.prefer`).
public struct ContractQueryPreferences: Sendable, Codable, Hashable {
    public var roles: [String]
    public var useClass: String?
    public var family: String?
    public var maxProjectedUSD: Double?
    public var maxP50Ms: Double?

    public init(
        roles: [String] = [],
        useClass: String? = nil,
        family: String? = nil,
        maxProjectedUSD: Double? = nil,
        maxP50Ms: Double? = nil
    ) {
        self.roles = roles
        self.useClass = useClass
        self.family = family
        self.maxProjectedUSD = maxProjectedUSD
        self.maxP50Ms = maxP50Ms
    }
}

/// Hard needs plus preferences over contract profiles (spec: `ContractQuery`).
public struct ContractQuery: Sendable, Codable, Hashable {
    public var contract: ModelContract
    public var interaction: InteractionKind?
    /// Required media (subset match).
    public var input: [ContractMediaType]
    public var output: [ContractMediaType]
    public var minGuarantee: OutputGuarantee?
    public var features: [String: RequiredFeature]
    /// Minimums the request needs.
    public var limits: ContractLimits
    public var prefer: ContractQueryPreferences
    public var excludeFamilies: [String]

    public init(
        contract: ModelContract,
        interaction: InteractionKind? = nil,
        input: [ContractMediaType] = [],
        output: [ContractMediaType] = [],
        minGuarantee: OutputGuarantee? = nil,
        features: [String: RequiredFeature] = [:],
        limits: ContractLimits = ContractLimits(),
        prefer: ContractQueryPreferences = ContractQueryPreferences(),
        excludeFamilies: [String] = []
    ) {
        self.contract = contract
        self.interaction = interaction
        self.input = input
        self.output = output
        self.minGuarantee = minGuarantee
        self.features = features
        self.limits = limits
        self.prefer = prefer
        self.excludeFamilies = excludeFamilies
    }

    /// Why a profile failed the hard filter; `nil` when it passes.
    public func rejection(for profile: ContractProfile) -> String? {
        guard profile.contract == contract else { return "contract \(profile.contract.rawValue) ≠ \(contract.rawValue)" }
        if let interaction, !profile.supportsInteraction(interaction) {
            return "no \(interaction.rawValue) interaction"
        }
        if let missing = input.first(where: { !profile.input.contains($0) }) {
            return "input \(missing.rawValue) unsupported"
        }
        if let missing = output.first(where: { !profile.output.contains($0) }) {
            return "output \(missing.rawValue) unsupported"
        }
        if let minGuarantee, profile.guarantee < minGuarantee {
            return "guarantee \(profile.guarantee.rawValue) below \(minGuarantee.rawValue)"
        }
        for (key, required) in features.sorted(by: { $0.key < $1.key }) {
            guard let feature = profile.feature(key) else { return "feature \(key) unsupported" }
            if let version = required.version, feature.version != version {
                return "feature \(key) version \(feature.version ?? "none") ≠ \(version)"
            }
        }
        if let need = limits.contextTokens, let have = profile.limits.contextTokens, have < need {
            return "context \(have) < \(need)"
        }
        if let need = limits.maxOptions, let have = profile.limits.maxOptions, have < need {
            return "maxOptions \(have) < \(need)"
        }
        if let need = limits.scoreLevels, let have = profile.limits.scoreLevels,
           need.lowerBound < have.lowerBound || need.upperBound > have.upperBound {
            return "score levels \(need) outside \(have)"
        }
        if let need = limits.maxOutputTokens, let have = profile.limits.maxOutputTokens, have < need {
            return "maxOutputTokens \(have) < \(need)"
        }
        return nil
    }
}

/// One dispatchable (entry, binding) pair with the profile that binding actually serves.
public struct ContractCandidate: Sendable, Hashable {
    public var entry: ModelRegistryEntry
    public var binding: ProviderBinding
    public var profile: ContractProfile

    public init(entry: ModelRegistryEntry, binding: ProviderBinding, profile: ContractProfile) {
        self.entry = entry
        self.binding = binding
        self.profile = profile
    }

    /// Stable binding identity used in route receipts.
    public var bindingID: String {
        "\(binding.providerId)/\(binding.endpointModelId)"
    }
}

public extension ModelQuery {
    /// Lifts a legacy chat query to a `generate` contract query (spec: legacy `ModelQuery` compiles to `ContractQuery`).
    var contractQuery: ContractQuery {
        var input: [ContractMediaType] = []
        if mustIncludeCapabilities.contains(.vision) { input.append(.image) }
        if mustIncludeCapabilities.contains(.audio) { input.append(.audio) }
        var output: [ContractMediaType] = []
        if mustIncludeCapabilities.contains(.tools) { output.append(.toolCalls) }
        var minGuarantee: OutputGuarantee?
        if requireResponseFormats.contains(.jsonSchema) {
            minGuarantee = .schemaStrict
        } else if requireResponseFormats.contains(.jsonObject) {
            minGuarantee = .jsonMode
        }
        return ContractQuery(
            contract: .generate,
            interaction: requireStreaming ? .stream : nil,
            input: input,
            output: output,
            minGuarantee: minGuarantee,
            limits: ContractLimits(contextTokens: minimumContextWindow),
            prefer: ContractQueryPreferences(useClass: preferredUseClass, family: preferredFamily),
            excludeFamilies: Array(excludeFamilies).sorted()
        )
    }
}
