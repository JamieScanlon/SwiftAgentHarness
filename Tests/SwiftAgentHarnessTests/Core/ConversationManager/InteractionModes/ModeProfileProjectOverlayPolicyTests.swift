import EasyJSON
import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Mode profile project overlay policy")
struct ModeProfileProjectOverlayPolicyTests {
    @Test("Project overlay strips tools allow escalation")
    func projectOverlayStripsToolsAllowEscalation() {
        var diagnostics: [String] = []
        let raw = ModeProfileConfiguration.RawProfile(
            id: "project-agent",
            extends: InteractionMode.agent.rawValue,
            tools: .object(["allow": .array([.string("*")])])
        )

        let sanitized = ModeProfileProjectOverlayPolicy.sanitize(raw, diagnostics: &diagnostics)
        #expect(sanitized?.tools == nil)
        #expect(sanitized?.id == "project-agent")
        #expect(diagnostics.contains("modeProfiles[project-agent] project overlay stripped security slice 'tools'"))
    }

    @Test("Project overlay rejects built-in profile ids")
    func projectOverlayRejectsBuiltInProfileIDs() {
        var diagnostics: [String] = []
        let raw = ModeProfileConfiguration.RawProfile(
            id: InteractionMode.agent.rawValue,
            extends: InteractionMode.chat.rawValue
        )

        let sanitized = ModeProfileProjectOverlayPolicy.sanitize(raw, diagnostics: &diagnostics)
        #expect(sanitized == nil)
        #expect(diagnostics.contains("modeProfiles[agent] project overlay rejected: protected profile id"))
    }

    @Test("Project overlay rejects machine sub-agent profile ids")
    func projectOverlayRejectsMachineProfileIDs() {
        var diagnostics: [String] = []
        let raw = ModeProfileConfiguration.RawProfile(
            id: "trigger-delegate",
            extends: InteractionMode.agent.rawValue,
            tools: .object(["allow": .array([.string("*")])])
        )

        let sanitized = ModeProfileProjectOverlayPolicy.sanitize(raw, diagnostics: &diagnostics)
        #expect(sanitized == nil)
        #expect(diagnostics.contains("modeProfiles[trigger-delegate] project overlay rejected: protected profile id"))
    }

    @Test("Project overlay rejects new root profiles without extends")
    func projectOverlayRejectsRootProfilesWithoutExtends() {
        var diagnostics: [String] = []
        let raw = ModeProfileConfiguration.RawProfile(
            id: "standalone-mode",
            interactionMode: .agent,
            assemblyKind: .agentBuild,
            allowsProactiveCompactionTriggers: true,
            appliesAgentBuildOrchestratorHarness: true,
            semanticLayerTags: []
        )

        let sanitized = ModeProfileProjectOverlayPolicy.sanitize(raw, diagnostics: &diagnostics)
        #expect(sanitized == nil)
        #expect(diagnostics.contains("modeProfiles[standalone-mode] project overlay rejected: requires extends"))
    }

    @Test("Project overlay keeps cosmetic context fields")
    func projectOverlayKeepsCosmeticContextFields() {
        var diagnostics: [String] = []
        let raw = ModeProfileConfiguration.RawProfile(
            id: "project-plan",
            extends: InteractionMode.plan.rawValue,
            context: .object([
                "compactionLevel": .string("aggressive"),
                "modeDirective": .string("Stay concise."),
                "sectionOverrides": .object(["tools": .string("Use only listed tools.")]),
                "includeSkills": .boolean(true),
                "memoryInjection": .string("always"),
            ])
        )

        let sanitized = ModeProfileProjectOverlayPolicy.sanitize(raw, diagnostics: &diagnostics)
        let context = sanitized?.context?.objectFields
        #expect(context?.optionalString(for: "compactionLevel") == "aggressive")
        #expect(context?.optionalString(for: "modeDirective") == "Stay concise.")
        #expect(context?["sectionOverrides"]?.objectFields?["tools"]?.stringValue == "Use only listed tools.")
        #expect(context?.keys.contains("includeSkills") == false)
        #expect(context?.keys.contains("memoryInjection") == false)
        #expect(diagnostics.contains("modeProfiles[project-plan] project overlay stripped trust-adjacent context field 'includeSkills'"))
        #expect(diagnostics.contains("modeProfiles[project-plan] project overlay stripped trust-adjacent context field 'memoryInjection'"))
    }
}

private extension JSON {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}
