import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("SystemPromptAssemblySafety")
struct SystemPromptAssemblySafetyTests {

    @Test("Legacy metadata userSystemPrompt key cannot hijack template tokens")
    func legacyUserSystemPromptKeyDoesNotCorruptTemplate() async throws {
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
        let injection = "{{datetime}}"
        let result = try await prompt.generateSystemPrompt(
            withUserSystemPrompt: "real user instructions",
            additionalMetadata: [
                "userSystemPrompt": injection,
            ]
        )
        #expect(result.contains("real user instructions"))
        #expect(result.contains(injection) == false || result.contains("# Additional Requirements"))
    }

    @Test("Contribution value containing template tokens is not expanded")
    func contributionValueWithTemplateTokensUnchanged() async throws {
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
        let tokenPayload = "Body with {{userSystemPrompt}} literal"
        let result = try await prompt.generateSystemPrompt(
            withUserSystemPrompt: nil,
            additionalMetadata: [
                "modeSectionOverride.tools": tokenPayload,
            ]
        )
        #expect(result.contains(tokenPayload))
    }

    @Test("Legacy shim unknown keys are identifiable")
    func unknownLegacyKeysDetected() {
        let unknown = SystemPromptLegacyMetadataAdapter.unknownKeys(in: [
            "modeDirective": "ok",
            "unexpectedKey": "bad",
        ])
        #expect(unknown == ["unexpectedKey"])
    }
}
