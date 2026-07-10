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

    @Test("softThresholdTokens defaults to 8000 and CE flush defaults on")
    func softThresholdAndFlushDefaults() {
        let config = ContextCompactionConfiguration.default
        #expect(config.softThresholdTokens == 8_000)
        #expect(config.preCompactionMemoryFlushEnabled == true)
    }

    @Test("softThresholdTokens loader clamps to non-negative with upper bound")
    func softThresholdLoaderClamps() {
        let negative: [String: Any] = [
            "contextCompaction": ["softThresholdTokens": -5],
        ]
        #expect(
            ConversationTransformConfiguration.configuration(fromJSON: negative)
                .contextCompaction.softThresholdTokens == 0
        )
        let huge: [String: Any] = [
            "contextCompaction": ["softThresholdTokens": 999_999],
        ]
        let clamped = ConversationTransformConfiguration.configuration(fromJSON: huge).contextCompaction.softThresholdTokens
        #expect(clamped <= 100_000)
        #expect(clamped >= 0)
        let explicit: [String: Any] = [
            "contextCompaction": ["softThresholdTokens": 4_000],
        ]
        #expect(
            ConversationTransformConfiguration.configuration(fromJSON: explicit)
                .contextCompaction.softThresholdTokens == 4_000
        )
    }

    @Test("softProactiveThresholdTokens is hard minus soft headroom")
    func softProactiveThresholdMath() {
        var config = ContextCompactionConfiguration.default
        config.proactiveOutputReserveTokens = 0
        config.proactiveSafetyBufferTokens = 20_000
        config.softThresholdTokens = 8_000
        let hard = ContextCompactionPolicy.proactiveThresholdTokens(
            modelContextLimitTokens: 100_000,
            config: config
        )
        let soft = ContextCompactionPolicy.softProactiveThresholdTokens(
            modelContextLimitTokens: 100_000,
            config: config
        )
        #expect(hard == 80_000)
        #expect(soft == 72_000)
        config.softThresholdTokens = 0
        #expect(
            ContextCompactionPolicy.softProactiveThresholdTokens(
                modelContextLimitTokens: 100_000,
                config: config
            ) == hard
        )
        #expect(
            ContextCompactionPolicy.softProactiveTriggerFires(
                messages: [],
                modelContextLimitTokens: 100_000,
                lastActualPromptTokens: 75_000,
                config: config
            ) == false
        )
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

    // MARK: - Hook toggles and timeout

    @Test("Default configuration enables all transform hooks for every interaction mode")
    func defaultsEnableHooks() {
        let config = ConversationTransformConfiguration.default
        for mode in [InteractionMode.chat, .plan, .agent] {
            let toggles = config.toggles(for: mode)
            #expect(toggles.enableContextTransform)
            #expect(toggles.enableToolResultTransform)
            #expect(toggles.enableTurnSummaryTransform)
        }
    }

    @Test("transformTimeoutSeconds clamps to 1...3600")
    func parserClampsTimeoutRange() {
        let zeroBlock: [String: Any] = ["transformTimeoutSeconds": 0]
        #expect(ConversationTransformConfiguration.configuration(fromJSON: zeroBlock).transformTimeoutSeconds == 1)

        let okBlock: [String: Any] = ["transformTimeoutSeconds": 999]
        #expect(ConversationTransformConfiguration.configuration(fromJSON: okBlock).transformTimeoutSeconds == 999)

        let highBlock: [String: Any] = ["transformTimeoutSeconds": 99_999]
        #expect(ConversationTransformConfiguration.configuration(fromJSON: highBlock).transformTimeoutSeconds == 3600)
    }

    @Test("Top-level hook toggles apply to chat, plan, and agent")
    func parserPreservesHookToggles() {
        let block: [String: Any] = [
            "enableContextTransform": false,
            "enableToolResultTransform": true,
            "enableTurnSummaryTransform": false,
        ]
        let config = ConversationTransformConfiguration.configuration(fromJSON: block)
        for mode in [InteractionMode.chat, .plan, .agent] {
            let toggles = config.toggles(for: mode)
            #expect(toggles.enableContextTransform == false)
            #expect(toggles.enableToolResultTransform == true)
            #expect(toggles.enableTurnSummaryTransform == false)
        }
    }

    @Test("Per-mode overrides merge over the legacy baseline")
    func parserPerModeOverridesMergeWithBaseline() {
        let block: [String: Any] = [
            "enableContextTransform": true,
            "enableToolResultTransform": true,
            "enableTurnSummaryTransform": true,
            "chat": [
                "enableContextTransform": false,
                "enableToolResultTransform": false,
                "enableTurnSummaryTransform": false,
            ],
            "plan": [
                "enableContextTransform": false,
            ],
            "agent": [
                "enableTurnSummaryTransform": false,
            ],
        ]
        let config = ConversationTransformConfiguration.configuration(fromJSON: block)
        #expect(config.chat.enableContextTransform == false)
        #expect(config.chat.enableToolResultTransform == false)
        #expect(config.chat.enableTurnSummaryTransform == false)
        #expect(config.plan.enableContextTransform == false)
        #expect(config.plan.enableToolResultTransform == true)
        #expect(config.plan.enableTurnSummaryTransform == true)
        #expect(config.agent.enableContextTransform == true)
        #expect(config.agent.enableToolResultTransform == true)
        #expect(config.agent.enableTurnSummaryTransform == false)
    }

    @Test("Partial per-mode objects inherit unspecified hooks from baseline")
    func parserPartialPerModeInheritsBaseline() {
        let block: [String: Any] = [
            "enableContextTransform": false,
            "enableToolResultTransform": true,
            "enableTurnSummaryTransform": false,
            "agent": [
                "enableContextTransform": true,
            ],
        ]
        let config = ConversationTransformConfiguration.configuration(fromJSON: block)
        #expect(config.agent.enableContextTransform == true)
        #expect(config.agent.enableToolResultTransform == true)
        #expect(config.agent.enableTurnSummaryTransform == false)
    }

    // MARK: - Context compaction defaults and JSON preservation

    @Test("ContextCompactionConfiguration.default matches spec values")
    func contextCompactionDefaults() {
        let config = ContextCompactionConfiguration.default
        #expect(config.enabled == true)
        #expect(config.model == "gemma4:e4b")
        #expect(config.fallbackContextLimitTokens == 131_072)
        #expect(config.charactersPerToken == 4)
        #expect(config.maxCompactedMiddleMessages == 15)
        #expect(config.maxRecentToolResults == 5)
        #expect(config.maxRecentPerNameToolResults == 5)
        #expect(config.toolResultPruneReplacementMode == .oneLineSummary)
        #expect(config.compactionSummaryBudgetTokens == 2000)
        #expect(config.compactionIdentifierPreservationMode == "strict")
        #expect(config.compactionSummarizerContextLimitTokens == 131_072)
        #expect(config.proactiveSafetyBufferTokens == 13_000)
        #expect(config.proactiveOutputReserveTokens == 20_000)
        #expect(config.reactiveTriggerEnabled == true)
        #expect(config.oversizeRetryMaxAttempts == 3)
        #expect(config.manualToolEnabled == true)
        #expect(config.defaultSummarizationStrategy == "default")
        #expect(config.cacheAwarePruningEnabled == false)
        #expect(config.deterministicToolResultPruningEnabled == true)
        #expect(config.deterministicAttachmentDocumentHygieneEnabled == false)
        #expect(config.compactionSummarizerMaxOutputTokens == 20_000)
        #expect(config.compactionSummaryBudgetProportionalEnabled == true)
        #expect(config.compactionReinjectionEnabled == true)
        #expect(config.compactionCircuitBreakerMaxFailures == 3)
        #expect(config.useSessionTreeProjection == true)
    }

    @Test("Explicit contextCompaction JSON values are preserved")
    func parserPreservesContextCompaction() {
        let block: [String: Any] = [
            "contextCompaction": [
                "enabled": false,
                "model": "custom-model",
                "ollamaServerURL": "http://127.0.0.1:11435",
                "maxCompactedMiddleMessages": 20,
                "compactionToolResultPruneNames": ["web-fetch"],
                "cacheAwarePruningEnabled": true,
                "cacheStablePrefixMessageCount": 6,
                "deterministicAttachmentDocumentHygieneEnabled": true,
                "deterministicDocumentCharacterThreshold": 9000,
            ],
        ]
        let config = ConversationTransformConfiguration.configuration(fromJSON: block).contextCompaction
        #expect(config.enabled == false)
        #expect(config.model == "custom-model")
        #expect(config.ollamaServerURL.absoluteString == "http://127.0.0.1:11435")
        #expect(config.maxCompactedMiddleMessages == 20)
        #expect(config.compactionToolResultPruneNames == ["web-fetch"])
        #expect(config.cacheAwarePruningEnabled == true)
        #expect(config.cacheStablePrefixMessageCount == 6)
        #expect(config.deterministicAttachmentDocumentHygieneEnabled == true)
        #expect(config.deterministicDocumentCharacterThreshold == 9000)
    }

    @Test("max_recent_tool_results snake_case decodes")
    func parserAcceptsSnakeCaseMaxRecentToolResults() {
        let block: [String: Any] = [
            "contextCompaction": ["max_recent_tool_results": 11],
        ]
        #expect(
            ConversationTransformConfiguration.configuration(fromJSON: block)
                .contextCompaction.maxRecentToolResults == 11
        )
    }

    @Test("max_recent_per_name_tool_results snake_case decodes")
    func parserAcceptsSnakeCaseMaxRecentPerNameToolResults() {
        let block: [String: Any] = [
            "contextCompaction": ["max_recent_per_name_tool_results": 12],
        ]
        #expect(
            ConversationTransformConfiguration.configuration(fromJSON: block)
                .contextCompaction.maxRecentPerNameToolResults == 12
        )
    }
}
