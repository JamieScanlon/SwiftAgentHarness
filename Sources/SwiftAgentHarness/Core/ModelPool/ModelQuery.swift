import Foundation
import SwiftAgentKit

/// Capability-first model selection (spec `ModelQuery` / `needs` + `prefer`, Swift-native).
public struct ModelQuery: Sendable, Hashable {
    /// Required capabilities (must be a subset of the entry's capabilities).
    public var mustIncludeCapabilities: Set<LLMCapability>
    public var minimumContextWindow: Int?
    public var preferredUseClass: String?
    public var preferredFamily: String?
    public var excludeFamilies: Set<String>
    /// When set, entries above this combined $/1M (input+output) are excluded.
    /// Unknown combined cost follows ``costCapUnknownFallback``.
    public var maximumCostPer1MCombinedUSD: Double?
    /// Behavior when ``maximumCostPer1MCombinedUSD`` is set but a candidate has unknown combined cost.
    public var costCapUnknownFallback: BudgetPolicy.ProjectedCostFallback
    /// When true, callers may attempt ranked cross-model substitution after same-model binding failover exhaustion.
    /// This flag does not change base match/rank filtering on its own.
    public var allowSubstitution: Bool

    /// When true, only entries whose ``ModelRegistryEntry/requestFeatures`` allows streaming.
    public var requireStreaming: Bool = false
    /// Non-empty: every listed format must appear in the entry's ``ModelRequestFeatures/responseFormats``.
    public var requireResponseFormats: Set<ResponseFormatKind> = []
    /// When true, ``ParallelToolCallSupport`` must not be ``unsupported``.
    public var requireParallelToolCalls: Bool = false
    /// Non-empty: must be a subset of the entry's ``ModelRequestFeatures/reasoningEfforts``.
    public var requireReasoningEfforts: Set<ReasoningEffort> = []

    public init(
        mustIncludeCapabilities: Set<LLMCapability> = [],
        minimumContextWindow: Int? = nil,
        preferredUseClass: String? = nil,
        preferredFamily: String? = nil,
        excludeFamilies: Set<String> = [],
        maximumCostPer1MCombinedUSD: Double? = nil,
        costCapUnknownFallback: BudgetPolicy.ProjectedCostFallback = .allowWhenUnknown,
        allowSubstitution: Bool = false,
        requireStreaming: Bool = false,
        requireResponseFormats: Set<ResponseFormatKind> = [],
        requireParallelToolCalls: Bool = false,
        requireReasoningEfforts: Set<ReasoningEffort> = []
    ) {
        self.mustIncludeCapabilities = mustIncludeCapabilities
        self.minimumContextWindow = minimumContextWindow
        self.preferredUseClass = preferredUseClass
        self.preferredFamily = preferredFamily
        self.excludeFamilies = excludeFamilies
        self.maximumCostPer1MCombinedUSD = maximumCostPer1MCombinedUSD
        self.costCapUnknownFallback = costCapUnknownFallback
        self.allowSubstitution = allowSubstitution
        self.requireStreaming = requireStreaming
        self.requireResponseFormats = requireResponseFormats
        self.requireParallelToolCalls = requireParallelToolCalls
        self.requireReasoningEfforts = requireReasoningEfforts
    }

    public func matches(_ entry: ModelRegistryEntry) -> Bool {
        if !mustIncludeCapabilities.isSubset(of: entry.capabilities) {
            return false
        }
        if let minWin = minimumContextWindow {
            guard let ctx = entry.maxContextLength, ctx >= minWin else {
                return false
            }
        }
        if let fam = entry.family, excludeFamilies.contains(fam) {
            return false
        }
        if let cap = maximumCostPer1MCombinedUSD {
            guard let combined = entry.cost?.combinedPer1MUSD else {
                return costCapUnknownFallback == .allowWhenUnknown
            }
            if combined > cap {
                return false
            }
        }
        if requireStreaming, !entry.requestFeatures.streaming {
            return false
        }
        if !requireResponseFormats.isSubset(of: entry.requestFeatures.responseFormats) {
            return false
        }
        if requireParallelToolCalls, entry.requestFeatures.parallelToolCalls == .unsupported {
            return false
        }
        if !requireReasoningEfforts.isSubset(of: entry.requestFeatures.reasoningEfforts) {
            return false
        }
        return true
    }

    /// Ranks registry entries; caller maps to ``Model`` via ``ModelRegistryEntry/toModel()`` if needed.
    public static func rank(entries: [ModelRegistryEntry], query: ModelQuery) -> [ModelRegistryEntry] {
        let filtered = entries.filter { query.matches($0) }
        return filtered.sorted { lhs, rhs in
            let lScore = Self.rankScore(entry: lhs, query: query)
            let rScore = Self.rankScore(entry: rhs, query: query)
            if lScore != rScore {
                return lScore > rScore
            }
            let lCtx = lhs.maxContextLength ?? 0
            let rCtx = rhs.maxContextLength ?? 0
            if lCtx != rCtx {
                return lCtx > rCtx
            }
            return lhs.displayName ?? lhs.id.uuidString < rhs.displayName ?? rhs.id.uuidString
        }
    }

    /// Fallback ranking when only ``Model`` values exist (no registry metadata).
    public static func rank(models: [Model], query: ModelQuery) -> [Model] {
        let entries = models.map { ModelRegistryEntry.from(model: $0) }
        return rank(entries: entries, query: query).map { $0.toModel() }
    }

    /// Returns ranked substitution candidates after excluding the already-tried primary model.
    /// Returns an empty list unless ``allowSubstitution`` is explicitly enabled in the query.
    public static func rankedSubstitutionCandidates(
        entries: [ModelRegistryEntry],
        query: ModelQuery,
        excludingModelID: UUID,
        maxCandidates: Int? = nil
    ) -> [ModelRegistryEntry] {
        guard query.allowSubstitution else { return [] }
        let ranked = rank(entries: entries, query: query).filter { $0.id != excludingModelID }
        guard let maxCandidates else { return ranked }
        return Array(ranked.prefix(max(0, maxCandidates)))
    }

    private static func rankScore(entry: ModelRegistryEntry, query: ModelQuery) -> Int {
        var score = 0
        if let preferred = query.preferredUseClass,
           entry.useClasses.contains(preferred) {
            score += 1000
        }
        if let fam = query.preferredFamily, entry.family == fam {
            score += 500
        }
        if let p50 = entry.performance?.p50LatencyMs {
            // Lower p50 is better; cap contribution to keep use-class/family preference dominant.
            let bounded = max(0.0, min(1500.0, p50))
            score += Int((1500.0 - bounded) / 10.0)
        }
        if let tokensPerSecond = entry.performance?.tokensPerSecond {
            let bounded = max(0.0, min(500.0, tokensPerSecond))
            score += Int(bounded)
        }
        return score
    }
}
