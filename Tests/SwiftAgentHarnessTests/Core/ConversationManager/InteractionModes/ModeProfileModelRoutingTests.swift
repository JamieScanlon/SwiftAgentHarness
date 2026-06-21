import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ModeProfileModelRouting")
struct ModeProfileModelRoutingTests {
    private func profile(modelQuery: String?, fallback: String? = nil) -> ResolvedModeProfile {
        ResolvedModeProfile(
            id: "test",
            interactionMode: .chat,
            assemblyKind: .chat,
            allowsProactiveCompactionTriggers: true,
            appliesAgentBuildOrchestratorHarness: false,
            builtInSeedVersion: ResolvedModeProfile.builtInSeedVersion,
            semanticLayerTags: [],
            model: ModeProfileModelSlice(query: modelQuery, fallback: fallback)
        )
    }

    @Test("effectiveRankingQuery prefers routing JSON over mode query over client hint")
    func rankingPrecedence() {
        let p = profile(modelQuery: "mode-q")
        #expect(
            ModeProfileModelRouting.effectiveRankingQuery(
                clientQuery: "client-q",
                routingQueryJSON: " route-q ",
                resolvedProfile: p
            ) == "route-q"
        )
        #expect(
            ModeProfileModelRouting.effectiveRankingQuery(
                clientQuery: "client-q",
                routingQueryJSON: nil,
                resolvedProfile: p
            ) == "mode-q"
        )
        #expect(
            ModeProfileModelRouting.effectiveRankingQuery(
                clientQuery: "  client-q  ",
                routingQueryJSON: "   ",
                resolvedProfile: ResolvedModeProfile(
                    id: "empty-model",
                    interactionMode: .chat,
                    assemblyKind: .chat,
                    allowsProactiveCompactionTriggers: true,
                    appliesAgentBuildOrchestratorHarness: false,
                    builtInSeedVersion: ResolvedModeProfile.builtInSeedVersion,
                    semanticLayerTags: [],
                    model: .neutral
                )
            ) == "client-q"
        )
    }

    @Test("effectiveModelReference leaves slug/id unchanged")
    func passthroughNonQueryRefs() {
        let p = profile(modelQuery: "mode-q")
        let id = UUID()
        #expect(ModeProfileModelRouting.effectiveModelReference(.id(id), routingQueryJSON: "r", resolvedProfile: p) == .id(id))
        #expect(ModeProfileModelRouting.effectiveModelReference(.slug("m:latest"), routingQueryJSON: "r", resolvedProfile: p) == .slug("m:latest"))
    }

    @Test("effectiveModelReference sets ModelQuery.preferredUseClass from composed ranking")
    func queryRefAdjustsModelQuery() {
        let p = profile(modelQuery: "mode-q")
        var mq = ModelQuery()
        mq.preferredUseClass = "client-class"
        let out = ModeProfileModelRouting.effectiveModelReference(.query(mq), routingQueryJSON: nil, resolvedProfile: p)
        guard case .query(let ranked) = out else {
            Issue.record("Expected .query ref")
            return
        }
        #expect(ranked.preferredUseClass == "mode-q")
    }

    @Test("dispatchQueryWaterfall enforces routing precedence with no cascade")
    func dispatchWaterfallRoutingNoCascade() {
        let p = profile(modelQuery: "mode-q", fallback: "mode-fallback")
        let waterfall = ModeProfileModelRouting.dispatchQueryWaterfall(
            routingQueryJSON: " route-q ",
            resolvedProfile: p
        )
        #expect(waterfall.primarySource == .routingOverride)
        #expect(waterfall.primaryQuery == "route-q")
        #expect(waterfall.modeFallbackQuery == nil)
    }

    @Test("dispatchQueryWaterfall uses mode query then mode fallback")
    func dispatchWaterfallModeQueryAndFallback() {
        let p = profile(modelQuery: "mode-q", fallback: " mode-fallback ")
        let waterfall = ModeProfileModelRouting.dispatchQueryWaterfall(
            routingQueryJSON: nil,
            resolvedProfile: p
        )
        #expect(waterfall.primarySource == .modeQuery)
        #expect(waterfall.primaryQuery == "mode-q")
        #expect(waterfall.modeFallbackQuery == "mode-fallback")
    }

    @Test("dispatchQueryWaterfall ignores fallback when mode query is absent")
    func dispatchWaterfallRequiresModeQuery() {
        let p = profile(modelQuery: nil, fallback: "mode-fallback")
        let waterfall = ModeProfileModelRouting.dispatchQueryWaterfall(
            routingQueryJSON: nil,
            resolvedProfile: p
        )
        #expect(waterfall.primarySource == .none)
        #expect(waterfall.primaryQuery == nil)
        #expect(waterfall.modeFallbackQuery == nil)
    }
}
