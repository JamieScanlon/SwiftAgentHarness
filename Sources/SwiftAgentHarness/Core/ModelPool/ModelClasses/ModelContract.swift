import EasyJSON
import Foundation

/// The shape of a call to a model (spec: `ModelContract`). Models are classified by contract first,
/// described by facets second, and selected by role third.
public enum ModelContract: String, Sendable, Codable, Hashable, CaseIterable {
    case generate
    case decide
    case embed
    case rerank
    case render
    case transcribe
    case session
    case parse
}

/// Media carried in or out of a contract call (spec: `MediaType`).
public enum ContractMediaType: String, Sendable, Codable, Hashable, CaseIterable {
    case text
    case json
    case image
    case pdf
    case audio
    case video
    case toolCalls = "tool-calls"
    case vector
    case distribution
    case bbox
    case segments
}

/// Interaction pattern kinds (spec: `Interaction["kind"]`).
public enum InteractionKind: String, Sendable, Codable, Hashable, CaseIterable {
    case unary
    case stream
    case job
    case session
    case batch
}

/// One supported interaction pattern with its parameters (spec: `Interaction`).
public enum InteractionPattern: Sendable, Codable, Hashable {
    public enum StreamPartials: String, Sendable, Codable, Hashable {
        case deltas
        case snapshots
    }

    public enum SessionTransport: String, Sendable, Codable, Hashable {
        case websocket
        case webrtc
    }

    case unary
    case stream(partials: StreamPartials?)
    case job(poll: Bool, webhook: Bool, artifactTTLSeconds: Int?, typicalSeconds: ClosedRange<Int>?)
    case session(transports: [SessionTransport], maxLifetimeSeconds: Int?, resumable: Bool, clientSecrets: Bool)
    case batch(discount: Double?)

    public var kind: InteractionKind {
        switch self {
        case .unary: return .unary
        case .stream: return .stream
        case .job: return .job
        case .session: return .session
        case .batch: return .batch
        }
    }
}

/// Ranked output guarantee (spec: `free-text < json-mode < schema-strict < logprobs < calibrated-distribution`).
public enum OutputGuarantee: String, Sendable, Codable, Hashable, CaseIterable, Comparable {
    case freeText = "free-text"
    case jsonMode = "json-mode"
    case schemaStrict = "schema-strict"
    case logprobs
    case calibratedDistribution = "calibrated-distribution"

    public var rank: Int {
        switch self {
        case .freeText: return 0
        case .jsonMode: return 1
        case .schemaStrict: return 2
        case .logprobs: return 3
        case .calibratedDistribution: return 4
        }
    }

    public static func < (lhs: OutputGuarantee, rhs: OutputGuarantee) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Versioned feature support (spec: `FeatureSupport`). Features are keys with versions and params, not booleans.
///
/// Equality and hashing compare ``params`` by canonical (sorted-key) JSON encoding because ``JSON``
/// itself is not `Hashable`.
public struct FeatureSupport: Sendable, Codable {
    public var supported: Bool
    public var version: String?
    public var params: [String: JSON]?

    public init(supported: Bool = true, version: String? = nil, params: [String: JSON]? = nil) {
        self.supported = supported
        self.version = version
        self.params = params
    }

    public func param(_ key: String) -> JSON? {
        params?[key]
    }

    public func stringParam(_ key: String) -> String? {
        guard case .string(let value)? = params?[key] else { return nil }
        return value
    }

    public func stringArrayParam(_ key: String) -> [String]? {
        guard case .array(let values)? = params?[key] else { return nil }
        return values.compactMap { value in
            if case .string(let string) = value { return string }
            return nil
        }
    }

    public func intParam(_ key: String) -> Int? {
        switch params?[key] {
        case .integer(let value)?: return value
        case .double(let value)?: return Int(value)
        default: return nil
        }
    }

    public func intPairParam(_ key: String) -> (Int, Int)? {
        guard case .array(let values)? = params?[key], values.count == 2 else { return nil }
        func int(_ json: JSON) -> Int? {
            switch json {
            case .integer(let value): return value
            case .double(let value): return Int(value)
            default: return nil
            }
        }
        guard let low = int(values[0]), let high = int(values[1]) else { return nil }
        return (low, high)
    }
}

extension FeatureSupport: Hashable {
    public static func == (lhs: FeatureSupport, rhs: FeatureSupport) -> Bool {
        lhs.supported == rhs.supported
            && lhs.version == rhs.version
            && CanonicalJSON.data(lhs.params) == CanonicalJSON.data(rhs.params)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(supported)
        hasher.combine(version)
        hasher.combine(CanonicalJSON.data(params))
    }
}

/// Stable, sorted-key JSON encoding used for equality, hashing, and cache keys.
enum CanonicalJSON {
    static func data<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data()
    }

    static func string<T: Encodable>(_ value: T) -> String {
        String(decoding: data(value), as: UTF8.self)
    }
}

/// Per-offering limits (spec: `ContractLimits`).
public struct ContractLimits: Sendable, Codable, Hashable {
    public var contextTokens: Int?
    public var maxOutputTokens: Int?
    /// Embeddings, images, or questions per decide call.
    public var maxItemsPerCall: Int?
    public var maxOptions: Int?
    /// Inclusive `[min, max]` score levels for `decide`.
    public var scoreLevels: ClosedRange<Int>?
    public var maxDurationSeconds: Int?
    public var resolutions: [String]?
    public var maxImageEdgePx: Int?
    public var maxImageTokens: Int?
    public var concurrentJobs: Int?

    public init(
        contextTokens: Int? = nil,
        maxOutputTokens: Int? = nil,
        maxItemsPerCall: Int? = nil,
        maxOptions: Int? = nil,
        scoreLevels: ClosedRange<Int>? = nil,
        maxDurationSeconds: Int? = nil,
        resolutions: [String]? = nil,
        maxImageEdgePx: Int? = nil,
        maxImageTokens: Int? = nil,
        concurrentJobs: Int? = nil
    ) {
        self.contextTokens = contextTokens
        self.maxOutputTokens = maxOutputTokens
        self.maxItemsPerCall = maxItemsPerCall
        self.maxOptions = maxOptions
        self.scoreLevels = scoreLevels
        self.maxDurationSeconds = maxDurationSeconds
        self.resolutions = resolutions
        self.maxImageEdgePx = maxImageEdgePx
        self.maxImageTokens = maxImageTokens
        self.concurrentJobs = concurrentJobs
    }

    /// Downward-only merge: each limit takes the tighter of the two values.
    public func narrowed(by other: ContractLimits) -> ContractLimits {
        func minOpt(_ a: Int?, _ b: Int?) -> Int? {
            switch (a, b) {
            case let (a?, b?): return Swift.min(a, b)
            default: return a ?? b
            }
        }
        var merged = ContractLimits(
            contextTokens: minOpt(contextTokens, other.contextTokens),
            maxOutputTokens: minOpt(maxOutputTokens, other.maxOutputTokens),
            maxItemsPerCall: minOpt(maxItemsPerCall, other.maxItemsPerCall),
            maxOptions: minOpt(maxOptions, other.maxOptions),
            maxDurationSeconds: minOpt(maxDurationSeconds, other.maxDurationSeconds),
            maxImageEdgePx: minOpt(maxImageEdgePx, other.maxImageEdgePx),
            maxImageTokens: minOpt(maxImageTokens, other.maxImageTokens),
            concurrentJobs: minOpt(concurrentJobs, other.concurrentJobs)
        )
        switch (scoreLevels, other.scoreLevels) {
        case let (a?, b?):
            let low = Swift.max(a.lowerBound, b.lowerBound)
            let high = Swift.min(a.upperBound, b.upperBound)
            merged.scoreLevels = low <= high ? low...high : nil
        default:
            merged.scoreLevels = scoreLevels ?? other.scoreLevels
        }
        switch (resolutions, other.resolutions) {
        case let (a?, b?):
            merged.resolutions = a.filter { b.contains($0) }
        default:
            merged.resolutions = resolutions ?? other.resolutions
        }
        return merged
    }
}

/// Wire surfaces codecs speak (open set; spec: `ContractProfile.surface`).
public struct ContractSurface: RawRepresentable, Sendable, Codable, Hashable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let anthropicMessages: ContractSurface = "anthropic-messages"
    public static let openAIChat: ContractSurface = "openai-chat"
    public static let openAIResponses: ContractSurface = "openai-responses"
    public static let ollamaChat: ContractSurface = "ollama-chat"
    public static let systemOne: ContractSurface = "systemone"
    public static let openAIDecisions: ContractSurface = "openai-decisions"
    /// Decide answered by a `generate` model (always uncalibrated).
    public static let llmEmulation: ContractSurface = "llm-emulation"
}

/// One contract an offering supports, with its facets (spec: `ContractProfile`).
public struct ContractProfile: Sendable, Codable, Hashable {
    public var contract: ModelContract
    public var surface: ContractSurface
    public var interaction: [InteractionPattern]
    public var input: [ContractMediaType]
    public var output: [ContractMediaType]
    /// Strongest guarantee the surface can deliver.
    public var guarantee: OutputGuarantee
    public var features: [String: FeatureSupport]
    public var limits: ContractLimits

    public init(
        contract: ModelContract,
        surface: ContractSurface,
        interaction: [InteractionPattern],
        input: [ContractMediaType],
        output: [ContractMediaType],
        guarantee: OutputGuarantee,
        features: [String: FeatureSupport] = [:],
        limits: ContractLimits = ContractLimits()
    ) {
        self.contract = contract
        self.surface = surface
        self.interaction = interaction
        self.input = input
        self.output = output
        self.guarantee = guarantee
        self.features = features
        self.limits = limits
    }

    public func supportsInteraction(_ kind: InteractionKind) -> Bool {
        interaction.contains { $0.kind == kind }
    }

    public func feature(_ key: String) -> FeatureSupport? {
        guard let feature = features[key], feature.supported else { return nil }
        return feature
    }

    /// Applies a binding's override downward: a binding can narrow but never widen the model's profile.
    ///
    /// The binding's surface wins (it is a serving fact). Interaction patterns and media are intersected,
    /// the guarantee takes the weaker rung, limits take the tighter value, and a feature survives only when
    /// both sides support it (the binding's version and params win).
    public func narrowed(by binding: ContractProfile) -> ContractProfile {
        guard binding.contract == contract else { return self }
        let bindingKinds = Set(binding.interaction.map(\.kind))
        var mergedInteraction: [InteractionPattern] = []
        for pattern in interaction where bindingKinds.contains(pattern.kind) {
            mergedInteraction.append(binding.interaction.first { $0.kind == pattern.kind } ?? pattern)
        }
        var mergedFeatures: [String: FeatureSupport] = [:]
        for (key, modelFeature) in features {
            guard let bindingFeature = binding.features[key] else {
                mergedFeatures[key] = modelFeature
                continue
            }
            if modelFeature.supported && bindingFeature.supported {
                mergedFeatures[key] = bindingFeature
            } else {
                mergedFeatures[key] = FeatureSupport(supported: false)
            }
        }
        return ContractProfile(
            contract: contract,
            surface: binding.surface,
            interaction: mergedInteraction,
            input: input.filter { binding.input.contains($0) },
            output: output.filter { binding.output.contains($0) },
            guarantee: Swift.min(guarantee, binding.guarantee),
            features: mergedFeatures,
            limits: limits.narrowed(by: binding.limits)
        )
    }
}
