import Foundation

/// Unit a price component is charged in (spec: `PriceUnit`).
public enum PriceUnit: String, Sendable, Codable, Hashable, CaseIterable {
    case inputToken = "input-token"
    case outputToken = "output-token"
    case cacheReadToken = "cache-read-token"
    case cacheWriteToken = "cache-write-token"
    case reasoningToken = "reasoning-token"
    case audioInputToken = "audio-input-token"
    case audioOutputToken = "audio-output-token"
    case imageInputToken = "image-input-token"
    case imageOutputToken = "image-output-token"
    case image
    case megapixel
    case second
    case minute
    case character
    case page
    case query
    case request
    case session
}

public enum ProcessingTier: String, Sendable, Codable, Hashable {
    case standard
    case batch
    case flex
    case fast
}

/// Conditions under which a price component applies (spec: `PriceComponent.when`).
public struct PriceCondition: Sendable, Codable, Hashable {
    public var tier: ProcessingTier?
    public var contextAbove: Int?
    public var resolution: String?
    public var quality: String?
    public var region: String?

    public init(
        tier: ProcessingTier? = nil,
        contextAbove: Int? = nil,
        resolution: String? = nil,
        quality: String? = nil,
        region: String? = nil
    ) {
        self.tier = tier
        self.contextAbove = contextAbove
        self.resolution = resolution
        self.quality = quality
        self.region = region
    }
}

/// One unit-typed price (spec: `PriceComponent`), e.g. `{unit: input-token, usd: 0.04, per: 1_000_000}`.
public struct PriceComponent: Sendable, Codable, Hashable {
    public var unit: PriceUnit
    public var usd: Double
    public var per: Double
    public var when: PriceCondition?

    public init(unit: PriceUnit, usd: Double, per: Double, when: PriceCondition? = nil) {
        self.unit = unit
        self.usd = usd
        self.per = per
        self.when = when
    }

    public var usdPerUnit: Double {
        per > 0 ? usd / per : 0
    }
}

public typealias PriceVector = [PriceComponent]

public extension Array where Element == PriceComponent {
    /// Unconditional (or matching-tier) price for `unit`, preferring the most specific `contextAbove` threshold met.
    func component(
        for unit: PriceUnit,
        tier: ProcessingTier = .standard,
        contextTokens: Int? = nil
    ) -> PriceComponent? {
        let candidates = filter { component in
            guard component.unit == unit else { return false }
            if let componentTier = component.when?.tier, componentTier != tier { return false }
            if let threshold = component.when?.contextAbove {
                guard let contextTokens, contextTokens > threshold else { return false }
            }
            return true
        }
        // Most specific wins: an explicit tier match over an unconditional price, then the highest threshold met.
        func specificity(_ component: PriceComponent) -> (Int, Int) {
            (component.when?.tier == nil ? 0 : 1, component.when?.contextAbove ?? -1)
        }
        return candidates.max { specificity($0) < specificity($1) }
    }

    /// Bridges the legacy per-1M token budget into a price vector.
    static func fromLegacy(_ cost: ModelCostBudget?) -> PriceVector {
        guard let cost else { return [] }
        var vector: PriceVector = []
        if let input = cost.inputPer1MUSD {
            vector.append(PriceComponent(unit: .inputToken, usd: input, per: 1_000_000))
        }
        if let output = cost.outputPer1MUSD {
            vector.append(PriceComponent(unit: .outputToken, usd: output, per: 1_000_000))
        }
        if let cached = cost.cachedInputPer1MUSD {
            vector.append(PriceComponent(unit: .cacheReadToken, usd: cached, per: 1_000_000))
        }
        return vector
    }
}

/// Projected or settled cost with how it was derived. `usd == nil` means unknown, which is never zero.
public struct CostProjection: Sendable, Equatable {
    public var usd: Double?
    public var basis: String

    public init(usd: Double?, basis: String) {
        self.usd = usd
        self.basis = basis
    }

    public static func unknown(_ basis: String) -> CostProjection {
        CostProjection(usd: nil, basis: basis)
    }
}

/// Cost projection and settlement for `decide` calls: billed on input tokens only.
public enum DecisionCostEstimator {
    /// Rough characters-per-token used only for pre-dispatch projection.
    static let charactersPerToken = 4.0

    public static func project(prices: PriceVector, estimatedInputTokens: Int) -> CostProjection {
        guard let input = prices.component(for: .inputToken, contextTokens: estimatedInputTokens) else {
            if let perRequest = prices.component(for: .request) {
                return CostProjection(usd: perRequest.usdPerUnit, basis: "request")
            }
            return .unknown("no input-token or request price")
        }
        return CostProjection(
            usd: Double(estimatedInputTokens) * input.usdPerUnit,
            basis: "input-token×\(estimatedInputTokens) (estimated)"
        )
    }

    /// Settles on reported input tokens; output tokens are informational and never billed.
    public static func settle(prices: PriceVector, inputTokens: Int?) -> Double? {
        if let inputTokens, let input = prices.component(for: .inputToken, contextTokens: inputTokens) {
            return Double(inputTokens) * input.usdPerUnit
        }
        if let perRequest = prices.component(for: .request) {
            return perRequest.usdPerUnit
        }
        return nil
    }

    /// Settles a `decide` call answered by an LLM emulation. Unlike a real decider, the chat model generates output,
    /// so output tokens are billed at its output price. Unknown when there is no input price to anchor on.
    public static func settleEmulated(prices: PriceVector, usage: DecisionUsage) -> Double? {
        guard let input = settle(prices: prices, inputTokens: usage.inputTokens) else { return nil }
        guard let outputTokens = usage.outputTokens, outputTokens > 0 else { return input }
        guard let output = prices.component(for: .outputToken, contextTokens: usage.inputTokens) else { return nil }
        return input + Double(outputTokens) * output.usdPerUnit
    }

    public static func estimateInputTokens(characterCount: Int) -> Int {
        Int((Double(characterCount) / charactersPerToken).rounded(.up))
    }
}
