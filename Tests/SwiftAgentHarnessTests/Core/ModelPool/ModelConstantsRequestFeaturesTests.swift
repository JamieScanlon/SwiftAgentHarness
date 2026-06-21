import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import Testing

/// Validates ``Constants.ModelConfig`` overlays for the capability vs request-features split.
@Suite("Constants — model pool overlays")
struct ModelConstantsRequestFeaturesTests {

    @Test("deepseek-r1:70b uses reasoningRequired (not optional thinking) and documents minimal request features")
    func deepseekR170b() {
        let cfg = Constants.ollamaModelIDMap["deepseek-r1:70b"]!
        #expect(cfg.hardcodedCapabilities.contains(.reasoningRequired))
        #expect(!cfg.hardcodedCapabilities.contains(.thinking))
        let rf = cfg.hardcodedRequestFeatures!
        #expect(rf.reasoningEfforts.isEmpty)
        #expect(rf.parallelToolCalls == .unsupported)
    }

    @Test("LM Studio MiniMax models advertise reasoning effort levels")
    func minimaxReasoningEfforts() {
        for key in ["minimax/minimax-m2", "minimax/minimax-m2.5"] {
            let cfg = Constants.lmStudioModelIDMap[key]!
            let rf = cfg.hardcodedRequestFeatures!
            #expect(rf.reasoningEfforts.contains(.low))
            #expect(rf.reasoningEfforts.contains(.high))
        }
    }

    @Test("gpt-oss OpenAI-compat preset exposes structured output + parallel tools")
    func gptOssPreset() {
        let cfg = Constants.lmStudioModelIDMap["openai/gpt-oss-20b"]!
        let rf = cfg.hardcodedRequestFeatures!
        #expect(rf.responseFormats.contains(.jsonSchema))
        #expect(rf.parallelToolCalls == .uncapped)
    }

    @Test("all model catalog entries define complete hardcoded cost budgets")
    func allCatalogEntriesHaveCost() {
        let combined = Array(Constants.ollamaModelIDMap.values) + Array(Constants.lmStudioModelIDMap.values)
        #expect(!combined.isEmpty)
        for config in combined {
            let cost = config.hardcodedCost
            #expect(cost != nil)
            #expect(cost?.inputPer1MUSD != nil)
            #expect(cost?.outputPer1MUSD != nil)
            #expect(cost?.combinedPer1MUSD != nil)
        }
    }

    @Test("per-protocol baselines advertise honest toolChoiceModes")
    func toolChoiceModesBaselines() {
        #expect(ModelManager.requestFeaturesBaseline(for: .ollama).toolChoiceModes == [.auto])
        #expect(ModelManager.requestFeaturesBaseline(for: .openAIAPI).toolChoiceModes == [.auto, .none, .required, .specific])
        #expect(ModelManager.requestFeaturesBaseline(for: .lmStudio).toolChoiceModes == [.auto, .required])
        #expect(ModelManager.requestFeaturesBaseline(for: .anthropic).toolChoiceModes == [.auto, .required, .specific])
    }

    @Test("merge unions toolChoiceModes from baseline and overlay")
    func mergeUnionsToolChoiceModes() {
        let baseline = ModelManager.requestFeaturesBaseline(for: .ollama)
        let overlay = ModelRequestFeatures(
            streaming: true,
            responseFormats: [.text],
            parallelToolCalls: .unsupported,
            reasoningEfforts: [],
            toolChoiceModes: [.required]
        )
        let merged = ModelManager.mergeRequestFeatures(baseline: baseline, overlay: overlay)
        #expect(merged.toolChoiceModes == [.auto, .required])
    }

    @Test("ModelCostBudget round-trips through Codable and remains Hashable")
    func modelCostBudgetRoundTrip() throws {
        let original = ModelCostBudget(inputPer1MUSD: 0.1, outputPer1MUSD: 0.3, cachedInputPer1MUSD: 0.02)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ModelCostBudget.self, from: data)
        #expect(decoded == original)
        let set: Set<ModelCostBudget> = [original]
        #expect(set.contains(decoded))
    }
}
