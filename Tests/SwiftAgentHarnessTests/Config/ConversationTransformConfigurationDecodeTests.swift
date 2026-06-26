import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ConversationTransformConfiguration decode")
struct ConversationTransformConfigurationDecodeTests {
    @Test("Legacy toolResultSummarizationCharacterThreshold key is ignored without error")
    func ignoresRemovedLegacyKey() {
        let block: [String: Any] = [
            "contextCompaction": [
                "toolResultSummarizationCharacterThreshold": 7777,
                "model": "some-model",
            ],
        ]
        let config = ConversationTransformConfiguration.configuration(fromJSON: block)
        #expect(config.contextCompaction.model == "some-model")
    }

    @Test("configFingerprint is stable for equal configurations")
    func fingerprintStableForEqualConfigs() {
        let a = ContextCompactionConfiguration.default
        let b = ContextCompactionConfiguration.default
        #expect(
            ContextCompactionCheckpointSupport.configFingerprint(a)
                == ContextCompactionCheckpointSupport.configFingerprint(b)
        )
    }

    // MARK: - CR-E toolResultPruneReplacementMode

    @Test("toolResultPruneReplacementMode decodes one_line_summary and blank strings")
    func decodesReplacementModeStrings() {
        let summaryBlock: [String: Any] = [
            "contextCompaction": ["toolResultPruneReplacementMode": "one_line_summary"],
        ]
        #expect(
            ConversationTransformConfiguration.configuration(fromJSON: summaryBlock)
                .contextCompaction.toolResultPruneReplacementMode == .oneLineSummary
        )
        let blankBlock: [String: Any] = [
            "contextCompaction": ["tool_result_prune_replacement_mode": "blank"],
        ]
        #expect(
            ConversationTransformConfiguration.configuration(fromJSON: blankBlock)
                .contextCompaction.toolResultPruneReplacementMode == .blankMarker
        )
    }

    @Test("Absent toolResultPruneReplacementMode falls back to default (.oneLineSummary)")
    func decodesAbsentReplacementMode() {
        let block: [String: Any] = ["contextCompaction": ["model": "some-model"]]
        #expect(
            ConversationTransformConfiguration.configuration(fromJSON: block)
                .contextCompaction.toolResultPruneReplacementMode
                == ContextCompactionConfiguration.default.toolResultPruneReplacementMode
        )
        #expect(ContextCompactionConfiguration.default.toolResultPruneReplacementMode == .oneLineSummary)
    }

    @Test("Changing toolResultPruneReplacementMode changes configFingerprint")
    func fingerprintReflectsReplacementMode() {
        var blank = ContextCompactionConfiguration.default
        blank.toolResultPruneReplacementMode = .blankMarker
        var summary = ContextCompactionConfiguration.default
        summary.toolResultPruneReplacementMode = .oneLineSummary
        #expect(
            ContextCompactionCheckpointSupport.configFingerprint(blank)
                != ContextCompactionCheckpointSupport.configFingerprint(summary)
        )
    }

    // MARK: - CR-F output reserve

    @Test("resolvedSummarizerMaxOutputTokens floors at 20k and dominates summary budget")
    func resolvedSummarizerOutputReserveFloor() {
        var config = ContextCompactionConfiguration.default
        config.compactionSummaryBudgetProportionalEnabled = true
        config.compactionSummaryBudgetTokens = 2_000
        config.compactionSummarizerMaxOutputTokens = 3_000

        #expect(config.resolvedSummarizerMaxOutputTokens >= 20_000)

        let summaryBudget = ContextCompactionPolicy.resolvedSummaryBudgetTokens(
            tokensCompressed: 200_000,
            config: config
        )
        #expect(summaryBudget <= config.resolvedSummarizerMaxOutputTokens)
    }

    @Test("compactionSummarizerMaxOutputTokens decodes 20000 without the legacy budget clamp")
    func decodeNoLongerClampsSummarizerMaxOutput() {
        let block: [String: Any] = [
            "contextCompaction": [
                "compactionSummarizerMaxOutputTokens": 20_000,
                "compactionSummaryBudgetTokens": 2_000,
            ],
        ]
        let config = ConversationTransformConfiguration.configuration(fromJSON: block).contextCompaction
        #expect(config.compactionSummarizerMaxOutputTokens == 20_000)
        #expect(config.resolvedSummarizerMaxOutputTokens >= 20_000)
    }

    @Test("Default compactionSummarizerMaxOutputTokens is the 20k reserve")
    func defaultSummarizerMaxOutputIsReserve() {
        #expect(ContextCompactionConfiguration.default.compactionSummarizerMaxOutputTokens == 20_000)
    }

    // MARK: - CR-F re-injection budgets

    @Test("Re-injection budget fields decode from snake_case and camelCase")
    func decodesReinjectionBudgets() {
        let block: [String: Any] = [
            "contextCompaction": [
                "reinjection_recent_file_count": 7,
                "reinjectionPerFileTokenBudget": 1_111,
                "reinjection_total_file_token_budget": 22_222,
                "reinjectionPerSkillTokenBudget": 3_333,
                "reinjection_total_skill_token_budget": 44_444,
                "reinjectFileContentEnabled": false,
            ],
        ]
        let config = ConversationTransformConfiguration.configuration(fromJSON: block).contextCompaction
        #expect(config.reinjectionRecentFileCount == 7)
        #expect(config.reinjectionPerFileTokenBudget == 1_111)
        #expect(config.reinjectionTotalFileTokenBudget == 22_222)
        #expect(config.reinjectionPerSkillTokenBudget == 3_333)
        #expect(config.reinjectionTotalSkillTokenBudget == 44_444)
        #expect(config.reinjectFileContentEnabled == false)
    }

    @Test("Absent re-injection budgets fall back to spec defaults")
    func reinjectionBudgetDefaults() {
        let config = ContextCompactionConfiguration.default
        #expect(config.reinjectionRecentFileCount == 5)
        #expect(config.reinjectionPerFileTokenBudget == 5_000)
        #expect(config.reinjectionTotalFileTokenBudget == 50_000)
        #expect(config.reinjectionPerSkillTokenBudget == 5_000)
        #expect(config.reinjectionTotalSkillTokenBudget == 25_000)
        #expect(config.reinjectFileContentEnabled == true)
    }

    @Test("Changing a re-injection budget changes configFingerprint")
    func fingerprintReflectsReinjectionBudgets() {
        var a = ContextCompactionConfiguration.default
        var b = ContextCompactionConfiguration.default
        b.reinjectionTotalFileTokenBudget = a.reinjectionTotalFileTokenBudget + 1
        #expect(
            ContextCompactionCheckpointSupport.configFingerprint(a)
                != ContextCompactionCheckpointSupport.configFingerprint(b)
        )
        a.reinjectFileContentEnabled = false
        b = ContextCompactionConfiguration.default
        #expect(
            ContextCompactionCheckpointSupport.configFingerprint(a)
                != ContextCompactionCheckpointSupport.configFingerprint(b)
        )
    }
}
