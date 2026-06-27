import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("AgentHarnessConfiguration decode")
struct AgentHarnessConfigurationDecodeTests {
    @Test("Default strictAgentHarnessPrompts is true")
    func defaultStrictPromptsEnabled() {
        #expect(AgentHarnessConfiguration.default.strictAgentHarnessPrompts == true)
    }

    @Test("Default maxTurnLoopContinuationRounds is unlimited")
    func defaultMaxTurnLoopContinuationRoundsUnlimited() {
        #expect(AgentHarnessConfiguration.default.maxTurnLoopContinuationRounds == Int.max)
    }

    @Test("Missing JSON keys fall back to defaults")
    func harnessJSONMissingKeyUsesDefault() {
        let config = AgentHarnessConfiguration.configuration(fromAgentHarnessJSON: [:])
        #expect(config.maxTurnLoopContinuationRounds == Int.max)
        #expect(config.useAgentLoop == true)
    }

    @Test("maxTurnLoopContinuationRounds clamps high values to 500")
    func harnessJSONClampsBuildRoundsHighValues() {
        let config = AgentHarnessConfiguration.configuration(
            fromAgentHarnessJSON: ["maxTurnLoopContinuationRounds": 600]
        )
        #expect(config.maxTurnLoopContinuationRounds == 500)
    }

    @Test("maxCorrectionRetries clamps high values to 20")
    func harnessJSONClampsCorrectionRetries() {
        let config = AgentHarnessConfiguration.configuration(
            fromAgentHarnessJSON: ["maxCorrectionRetries": 999]
        )
        #expect(config.maxCorrectionRetries == 20)
    }

    @Test("orchestratorPoolIdleTTLSeconds override is preserved")
    func harnessJSONPreservesPoolTTL() {
        let config = AgentHarnessConfiguration.configuration(
            fromAgentHarnessJSON: ["orchestratorPoolIdleTTLSeconds": 120]
        )
        #expect(config.orchestratorPoolIdleTTLSeconds == 120)
    }

    @Test("orchestratorPoolMaxEntries override is preserved")
    func harnessJSONPreservesPoolMaxEntries() {
        let config = AgentHarnessConfiguration.configuration(
            fromAgentHarnessJSON: ["orchestratorPoolMaxEntries": 8]
        )
        #expect(config.orchestratorPoolMaxEntries == 8)
    }

    @Test("repeatToolCallStreakThreshold override is preserved")
    func harnessJSONPreservesRepeatStreak() {
        let config = AgentHarnessConfiguration.configuration(
            fromAgentHarnessJSON: ["repeatToolCallStreakThreshold": 7]
        )
        #expect(config.repeatToolCallStreakThreshold == 7)
    }

    @Test("legacyStreamedTextSurfaces decodes string array")
    func harnessJSONDecodesLegacyStreamedTextSurfaces() {
        let config = AgentHarnessConfiguration.configuration(
            fromAgentHarnessJSON: ["legacyStreamedTextSurfaces": ["cli"]]
        )
        #expect(config.legacyStreamedTextSurfaces == Set(["cli"]))
    }
}
