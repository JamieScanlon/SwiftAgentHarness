import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ModelQuery")
struct ModelQueryTests {
    @Test("matches requires capability subset and minimum context when set")
    func matchesFilters() {
        let entry = ModelRegistryEntry(
            id: UUID(),
            capabilities: [.completion, .tools],
            maxContextLength: 8192,
            providers: [
                ProviderBinding(
                    providerId: "ollama",
                    modelProtocol: .ollama,
                    endpointModelId: "m",
                    serverURL: URL(string: "http://localhost:11434")!,
                    priority: 0
                )
            ],
            useClasses: []
        )
        let needTools = ModelQuery(mustIncludeCapabilities: [.tools], minimumContextWindow: 4000)
        #expect(needTools.matches(entry))

        let needVision = ModelQuery(mustIncludeCapabilities: [.vision])
        #expect(!needVision.matches(entry))

        let needHuge = ModelQuery(mustIncludeCapabilities: [], minimumContextWindow: 100_000)
        #expect(!needHuge.matches(entry))
    }

    @Test("matches applies request-feature filters")
    func matchesRequestFeatures() {
        let binding = ProviderBinding(
            providerId: "lmstudio",
            modelProtocol: .lmStudio,
            endpointModelId: "m",
            serverURL: URL(string: "http://localhost:1234")!,
            priority: 0
        )
        let rich = ModelRegistryEntry(
            id: UUID(),
            capabilities: [.completion],
            requestFeatures: ModelRequestFeatures(
                streaming: true,
                responseFormats: [.text, .jsonObject, .jsonSchema],
                parallelToolCalls: .uncapped,
                reasoningEfforts: [.low, .medium]
            ),
            providers: [binding]
        )
        let poor = ModelRegistryEntry(
            id: UUID(),
            capabilities: [.completion],
            requestFeatures: ModelRequestFeatures(
                streaming: false,
                responseFormats: [.text],
                parallelToolCalls: .unsupported,
                reasoningEfforts: []
            ),
            providers: [binding]
        )

        let qSchema = ModelQuery(requireResponseFormats: [.jsonSchema])
        #expect(qSchema.matches(rich))
        #expect(!qSchema.matches(poor))

        let qParallel = ModelQuery(requireParallelToolCalls: true)
        #expect(qParallel.matches(rich))
        #expect(!qParallel.matches(poor))

        let qStream = ModelQuery(requireStreaming: true)
        #expect(qStream.matches(rich))
        #expect(!qStream.matches(poor))

        let qEffort = ModelQuery(requireReasoningEfforts: [.medium])
        #expect(qEffort.matches(rich))
        #expect(!qEffort.matches(poor))
    }

    @Test("rank orders by preferred use class then context length")
    func rankOrders() {
        let idA = UUID()
        let idB = UUID()
        let binding = ProviderBinding(
            providerId: "ollama",
            modelProtocol: .ollama,
            endpointModelId: "m",
            serverURL: URL(string: "http://localhost:11434")!,
            priority: 0
        )
        let a = ModelRegistryEntry(
            id: idA,
            capabilities: [.completion],
            maxContextLength: 4096,
            providers: [binding],
            useClasses: ["planning"]
        )
        let b = ModelRegistryEntry(
            id: idB,
            capabilities: [.completion],
            maxContextLength: 8192,
            providers: [binding],
            useClasses: []
        )
        let q = ModelQuery(mustIncludeCapabilities: [.completion], preferredUseClass: "planning")
        let ranked = ModelQuery.rank(entries: [b, a], query: q)
        #expect(ranked.first?.id == idA)
        #expect(ranked.last?.id == idB)
    }

    @Test("rank prefers stronger observed performance when other preferences tie")
    func rankPrefersObservedPerformance() {
        let binding = ProviderBinding(
            providerId: "ollama",
            modelProtocol: .ollama,
            endpointModelId: "m",
            serverURL: URL(string: "http://localhost:11434")!,
            priority: 0
        )
        let fast = ModelRegistryEntry(
            id: UUID(),
            capabilities: [.completion],
            providers: [binding],
            performance: ModelObservedPerformance(p50LatencyMs: 80, tokensPerSecond: 120)
        )
        let slow = ModelRegistryEntry(
            id: UUID(),
            capabilities: [.completion],
            providers: [binding],
            performance: ModelObservedPerformance(p50LatencyMs: 450, tokensPerSecond: 20)
        )
        let ranked = ModelQuery.rank(entries: [slow, fast], query: ModelQuery(mustIncludeCapabilities: [.completion]))
        #expect(ranked.first?.id == fast.id)
    }

    @Test("allowSubstitution defaults to false")
    func allowSubstitutionDefaultsOff() {
        let query = ModelQuery()
        #expect(query.allowSubstitution == false)
    }

    @Test("ranked substitution candidates require explicit opt-in and exclude primary")
    func rankedSubstitutionCandidatesOptInAndExclusion() {
        let primaryID = UUID()
        let altAID = UUID()
        let altBID = UUID()
        let binding = ProviderBinding(
            providerId: "ollama",
            modelProtocol: .ollama,
            endpointModelId: "m",
            serverURL: URL(string: "http://localhost:11434")!,
            priority: 0
        )
        let primary = ModelRegistryEntry(
            id: primaryID,
            displayName: "primary",
            capabilities: [.completion],
            maxContextLength: 4096,
            providers: [binding],
            useClasses: ["planning"]
        )
        let altA = ModelRegistryEntry(
            id: altAID,
            displayName: "alt-a",
            capabilities: [.completion],
            maxContextLength: 8192,
            providers: [binding],
            useClasses: ["planning"]
        )
        let altB = ModelRegistryEntry(
            id: altBID,
            displayName: "alt-b",
            capabilities: [.completion],
            maxContextLength: 2048,
            providers: [binding],
            useClasses: []
        )
        let off = ModelQuery(mustIncludeCapabilities: [.completion], preferredUseClass: "planning")
        #expect(
            ModelQuery.rankedSubstitutionCandidates(
                entries: [primary, altB, altA],
                query: off,
                excludingModelID: primaryID
            ).isEmpty
        )

        let on = ModelQuery(
            mustIncludeCapabilities: [.completion],
            preferredUseClass: "planning",
            allowSubstitution: true
        )
        let ranked = ModelQuery.rankedSubstitutionCandidates(
            entries: [primary, altB, altA],
            query: on,
            excludingModelID: primaryID
        )
        #expect(ranked.map(\.id) == [altAID, altBID])
    }

    // MARK: - Cost-aware ranking scaffold

    private static func costEntry(id: UUID, slug: String, cost: ModelCostBudget?) -> ModelRegistryEntry {
        let binding = ProviderBinding(
            providerId: "openai",
            modelProtocol: .openAIAPI,
            endpointModelId: slug,
            serverURL: URL(string: "https://api.openai.com")!,
            priority: 0
        )
        return ModelRegistryEntry(
            id: id,
            displayName: slug,
            capabilities: [.completion],
            maxContextLength: 8192,
            providers: [binding],
            cost: cost
        )
    }

    @Test("rank ignores maximumCostPer1MCombinedUSD when no entry has cost (today's catalog)")
    func costAwareRankingNoOpWhenCostMissing() {
        let idA = UUID(); let idB = UUID()
        let a = Self.costEntry(id: idA, slug: "alpha", cost: nil)
        let b = Self.costEntry(id: idB, slug: "bravo", cost: nil)
        let capped = ModelQuery(maximumCostPer1MCombinedUSD: 5.0)
        let ranked = ModelQuery.rank(entries: [a, b], query: capped)
        // Tie-break falls through to maxContextLength then displayName: alpha < bravo so alpha wins.
        #expect(ranked.first?.id == idA)
        #expect(ranked.count == 2)
    }

    @Test("rank excludes entries above the combined cost cap")
    func costAwareRankingExcludesExpensive() {
        let cheapID = UUID(); let pricyID = UUID()
        let cheap = Self.costEntry(
            id: cheapID,
            slug: "cheap-model",
            cost: ModelCostBudget(inputPer1MUSD: 0.5, outputPer1MUSD: 1.5)
        )
        let pricy = Self.costEntry(
            id: pricyID,
            slug: "pricy-model",
            cost: ModelCostBudget(inputPer1MUSD: 30.0, outputPer1MUSD: 60.0)
        )
        // Cap = $5/1M combined: cheap (2.0) passes, pricy (90.0) is excluded.
        let q = ModelQuery(maximumCostPer1MCombinedUSD: 5.0)
        let ranked = ModelQuery.rank(entries: [pricy, cheap], query: q)
        #expect(ranked.first?.id == cheapID)
        #expect(ranked.count == 1)
    }

    @Test("cost cap exclusion outranks preferredUseClass and preferredFamily preferences")
    func costCapExclusionDominatesPreferences() {
        let pricyID = UUID(); let cheapID = UUID()
        let pricyPreferred = Self.costEntry(
            id: pricyID,
            slug: "pricy-preferred",
            cost: ModelCostBudget(inputPer1MUSD: 50.0, outputPer1MUSD: 50.0)
        )
        // Boost the expensive entry with a use-class match and a family match.
        var pricyWithBoost = pricyPreferred
        pricyWithBoost.useClasses = ["planning"]
        pricyWithBoost.family = "openai"

        let cheap = Self.costEntry(
            id: cheapID,
            slug: "cheap-plain",
            cost: ModelCostBudget(inputPer1MUSD: 0.5, outputPer1MUSD: 0.5)
        )
        let q = ModelQuery(
            preferredUseClass: "planning",
            preferredFamily: "openai",
            maximumCostPer1MCombinedUSD: 5.0
        )
        let ranked = ModelQuery.rank(entries: [pricyWithBoost, cheap], query: q)
        #expect(ranked.first?.id == cheapID)
        #expect(ranked.count == 1)
    }

    @Test("cost cap can reject unknown-cost entries when fallback is denyWhenUnknown")
    func costCapFallbackRejectsUnknown() {
        let id = UUID()
        let unknown = Self.costEntry(id: id, slug: "unknown-cost", cost: nil)
        let ranked = ModelQuery.rank(
            entries: [unknown],
            query: ModelQuery(
                maximumCostPer1MCombinedUSD: 5.0,
                costCapUnknownFallback: .denyWhenUnknown
            )
        )
        #expect(ranked.isEmpty)
    }

    @Test("ModelCostBudget.combinedPer1MUSD is nil unless both input and output are populated")
    func combinedPer1MUSDPartialBudgets() {
        #expect(ModelCostBudget(inputPer1MUSD: 1.0, outputPer1MUSD: 2.0).combinedPer1MUSD == 3.0)
        #expect(ModelCostBudget(inputPer1MUSD: 1.0).combinedPer1MUSD == nil)
        #expect(ModelCostBudget(outputPer1MUSD: 2.0).combinedPer1MUSD == nil)
        #expect(ModelCostBudget().combinedPer1MUSD == nil)
    }

    @Test("ModelRegistryEntry.from(model:cost:) preserves explicit cost overlays")
    func fromModelPreservesCostOverlay() {
        let model = Model(
            protocol: .ollama,
            modelName: "qwen3:30b-a3b",
            serverURL: URL(string: "http://localhost:11434")!,
            capabilities: [.completion],
            modelProtocol: .ollama,
            routing: ModelRoutingMetadata(
                rateLimit: ModelRateLimitMetadata(requests: 8, tokens: 120_000, windowMs: 60_000)
            )
        )
        let overlay = ModelCostBudget(inputPer1MUSD: 0.1, outputPer1MUSD: 0.3, cachedInputPer1MUSD: 0.02)
        let entry = ModelRegistryEntry.from(model: model, cost: overlay)
        #expect(entry.cost == overlay)
        #expect(entry.routing == model.routing)
    }

    @Test("catalog overlays include both budget and premium cost tiers")
    func catalogContainsCostTiers() {
        let budget = Constants.ollamaModelIDMap["gemma3:27b"]?.hardcodedCost
        let premium = Constants.ollamaModelIDMap["deepseek-r1:70b"]?.hardcodedCost
        #expect(budget?.combinedPer1MUSD != nil)
        #expect(premium?.combinedPer1MUSD != nil)
        #expect((budget?.combinedPer1MUSD ?? 0) < (premium?.combinedPer1MUSD ?? 0))
    }

    @Test("ModelQuery cost cap ranking reflects live catalog overlays")
    func costRankingUsesLiveCatalogOverlays() {
        let budgetEntry = Self.costEntry(
            id: UUID(),
            slug: "gemma3:27b",
            cost: Constants.ollamaModelIDMap["gemma3:27b"]?.hardcodedCost
        )
        let premiumEntry = Self.costEntry(
            id: UUID(),
            slug: "deepseek-r1:70b",
            cost: Constants.ollamaModelIDMap["deepseek-r1:70b"]?.hardcodedCost
        )
        let cap = Constants.ollamaModelIDMap["gemma3:27b"]?.hardcodedCost?.combinedPer1MUSD ?? 0
        let ranked = ModelQuery.rank(
            entries: [premiumEntry, budgetEntry],
            query: ModelQuery(maximumCostPer1MCombinedUSD: cap)
        )
        #expect(ranked.first?.slug == "gemma3:27b")
        #expect(ranked.count == 1)
    }
}
