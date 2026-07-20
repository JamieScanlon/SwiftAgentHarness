import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("SystemPromptContributionResolver")
struct SystemPromptContributionResolverTests {

    @Test("Same-layer section override conflict returns error")
    func sameLayerOverrideConflict() throws {
        let first = SystemPromptContribution(
            source: .mode,
            sectionOverrides: [.toolGuidance: "first"]
        )
        let second = SystemPromptContribution(
            source: .mode,
            sectionOverrides: [.toolGuidance: "second"]
        )
        #expect(throws: SystemPromptContributionConflict.self) {
            try SystemPromptContributionResolver.resolve(contributions: [first, second])
        }
    }

    @Test("Cross-layer override lets later layer win")
    func crossLayerOverrideWins() throws {
        let provider = SystemPromptContribution(
            source: .provider,
            sectionOverrides: [.toolGuidance: "provider tools"]
        )
        let mode = SystemPromptContribution(
            source: .mode,
            sectionOverrides: [.toolGuidance: "mode tools"]
        )
        let resolution = try SystemPromptContributionResolver.resolve(contributions: [provider, mode])
        #expect(resolution.resolved.sectionOverrides[.toolGuidance] == "mode tools")
        #expect(resolution.resolved.provenance[.toolGuidance] == .mode)
    }

    @Test("Constraints section cannot be suppressed, overridden, or directive-appended")
    func constraintsOverrideProof() throws {
        let mode = SystemPromptContribution(
            source: .mode,
            sectionOverrides: [SystemPromptSectionName.constraints: "tampered"],
            sectionDirectives: [SystemPromptSectionName.constraints: "extra rule"],
            suppress: [SystemPromptSectionName.constraints, .skills]
        )
        let resolution = try SystemPromptContributionResolver.resolve(contributions: [mode])
        #expect(resolution.resolved.suppressions.contains(SystemPromptSectionName.constraints) == false)
        #expect(resolution.resolved.suppressions.contains(SystemPromptSectionName.skills))
        #expect(resolution.resolved.sectionOverrides[SystemPromptSectionName.constraints] == nil)
        #expect(resolution.resolved.sectionDirectives[SystemPromptSectionName.constraints] == nil)
    }

    @Test("Per-turn stablePrefix from volatile layer is rejected")
    func volatileStablePrefixRejected() {
        let mode = SystemPromptContribution(
            source: .mode,
            stablePrefix: "must not apply"
        )
        #expect(throws: SystemPromptContributionConflict.self) {
            try SystemPromptContributionResolver.resolve(contributions: [mode])
        }
    }

    @Test("Provider stablePrefix is accepted")
    func providerStablePrefixAccepted() throws {
        let provider = SystemPromptContribution(
            source: .provider,
            stablePrefix: "provider prefix"
        )
        let resolution = try SystemPromptContributionResolver.resolve(contributions: [provider])
        #expect(resolution.stablePrefix == "provider prefix")
    }

    @Test("Legacy keys map to canonical sections")
    func legacyKeyMapping() {
        #expect(SystemPromptSectionName.canonicalSection(forLegacyKey: "tools") == .toolGuidance)
        #expect(SystemPromptSectionName.canonicalSection(forLegacyKey: "workflow") == .modeDirective)
        #expect(SystemPromptSectionName.canonicalSection(forLegacyKey: "sub_agent_context") == .dynamicAdditions)
        #expect(SystemPromptSectionName.canonicalSection(forLegacyKey: "interaction_style") == .dynamicAdditions)
    }
}
