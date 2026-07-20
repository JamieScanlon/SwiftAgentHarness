import Foundation
import SwiftAgentKit

/// USD pricing scaffold used by the Model Pool catalog (spec: `ModelEntry.cost`).
///
/// All fields are optional; `combinedPer1MUSD` only resolves when both input and output are populated.
/// Today the catalog leaves every field nil — the "populate cost catalog" task fills these and exposes them on the wire.
public struct ModelCostBudget: Sendable, Hashable, Codable {
    public var inputPer1MUSD: Double?
    public var outputPer1MUSD: Double?
    public var cachedInputPer1MUSD: Double?

    public init(
        inputPer1MUSD: Double? = nil,
        outputPer1MUSD: Double? = nil,
        cachedInputPer1MUSD: Double? = nil
    ) {
        self.inputPer1MUSD = inputPer1MUSD
        self.outputPer1MUSD = outputPer1MUSD
        self.cachedInputPer1MUSD = cachedInputPer1MUSD
    }

    /// Sum of input + output prices when both are present; nil otherwise.
    public var combinedPer1MUSD: Double? {
        guard let i = inputPer1MUSD, let o = outputPer1MUSD else { return nil }
        return i + o
    }
}

/// Rolling observed performance telemetry attached to registry entries.
public struct ModelObservedPerformance: Sendable, Hashable, Codable {
    public var p50LatencyMs: Double?
    public var tokensPerSecond: Double?

    public init(p50LatencyMs: Double? = nil, tokensPerSecond: Double? = nil) {
        self.p50LatencyMs = p50LatencyMs
        self.tokensPerSecond = tokensPerSecond
    }
}

/// Optional model routing hints mirrored from registry rows.
public struct ModelRoutingMetadata: Sendable, Hashable, Codable {
    public var rateLimit: ModelRateLimitMetadata?

    public init(rateLimit: ModelRateLimitMetadata? = nil) {
        self.rateLimit = rateLimit
    }
}

/// Registry metadata describing nominal per-model rate limit windows.
public struct ModelRateLimitMetadata: Sendable, Hashable, Codable {
    public var requests: Int
    public var tokens: Int
    public var windowMs: Int

    public init(requests: Int, tokens: Int, windowMs: Int) {
        self.requests = requests
        self.tokens = tokens
        self.windowMs = windowMs
    }
}

public struct ModelConfig: Sendable {
    public var uuid: UUID
    public var modelProtocol: ModelProtocol
    /// Adding capabilities here makes sure they are attached to the model. This is a woraround for the API's not providing complete capabilities
    public var hardcodedCapabilities: [LLMCapability] = []
    /// Optional request-feature overlay merged with the protocol baseline during discovery.
    public var hardcodedRequestFeatures: ModelRequestFeatures?
    /// Optional cost overlay attached to discovered registry entries. Currently nil for every row;
    /// the net-new task populates real values once a pricing catalog exists.
    public var hardcodedCost: ModelCostBudget?
    /// Optional routing metadata overlay attached to discovered registry entries.
    public var hardcodedRouting: ModelRoutingMetadata?
    /// Stable logical-model identity for cross-provider binding merge.
    public var canonicalModelKey: String?
    /// Coarse model family for ranking (e.g. `claude-sonnet`), distinct from ``canonicalModelKey``.
    public var modelFamily: String?

    public init(
        uuid: UUID,
        modelProtocol: ModelProtocol,
        hardcodedCapabilities: [LLMCapability] = [],
        hardcodedRequestFeatures: ModelRequestFeatures? = nil,
        hardcodedCost: ModelCostBudget? = nil,
        hardcodedRouting: ModelRoutingMetadata? = nil,
        canonicalModelKey: String? = nil,
        modelFamily: String? = nil
    ) {
        self.uuid = uuid
        self.modelProtocol = modelProtocol
        self.hardcodedCapabilities = hardcodedCapabilities
        self.hardcodedRequestFeatures = hardcodedRequestFeatures
        self.hardcodedCost = hardcodedCost
        self.hardcodedRouting = hardcodedRouting
        self.canonicalModelKey = canonicalModelKey
        self.modelFamily = modelFamily
    }
}
