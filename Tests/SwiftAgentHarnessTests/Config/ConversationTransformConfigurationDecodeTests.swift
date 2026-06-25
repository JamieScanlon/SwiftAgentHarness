import Foundation
import Testing
@testable import SwiftAgentHarness

/// CR-D config migration: the LLM-only `toolResultSummarizationCharacterThreshold` knob is deprecated
/// but retained, so configs that still carry the key (or omit it) must keep decoding without error.
@Suite("ConversationTransformConfiguration decode")
struct ConversationTransformConfigurationDecodeTests {
    @Test("Legacy toolResultSummarizationCharacterThreshold key still decodes")
    func decodesLegacyKey() {
        let block: [String: Any] = [
            "contextCompaction": [
                "toolResultSummarizationCharacterThreshold": 7777,
            ],
        ]
        let config = ConversationTransformConfiguration.configuration(fromJSON: block)
        #expect(config.contextCompaction.toolResultSummarizationCharacterThreshold == 7777)
    }

    @Test("Absent toolResultSummarizationCharacterThreshold falls back to default")
    func decodesAbsentKey() {
        let block: [String: Any] = [
            "contextCompaction": [
                "model": "some-model",
            ],
        ]
        let config = ConversationTransformConfiguration.configuration(fromJSON: block)
        #expect(
            config.contextCompaction.toolResultSummarizationCharacterThreshold
                == ContextCompactionConfiguration.default.toolResultSummarizationCharacterThreshold
        )
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
}
