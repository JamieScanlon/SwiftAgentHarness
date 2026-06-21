import EasyJSON
import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ModeProfileSkills")
struct ModeProfileSkillsTests {

    @Test("Bundled PromptConfig mode profiles parse and resolve")
    func bundledPromptConfigModeProfilesResolve() async throws {
        let config = ModeProfileConfiguration.loadFromPromptConfigBundle()
        #expect(!config.profiles.isEmpty)
        let registry = ModeRegistryTestSupport.makeService(
            seedingBuiltIns: true,
            modeProfileConfiguration: config
        )
        let registryDiagnostics = await registry.configurationDiagnostics()
        let diagnostics = config.diagnostics + registryDiagnostics
        #expect(diagnostics.isEmpty, "Unexpected diagnostics: \(diagnostics)")
        for raw in config.profiles {
            _ = try await registry.resolve(modeId: raw.id)
        }
        for mode in [InteractionMode.chat, .plan, .agent] {
            _ = try await registry.resolve(modeId: mode.rawValue)
        }
    }

    @Test("nil skills allow imposes no profile constraint")
    func nilAllowPermitsAll() {
        let slice = ModeProfileSkillsSlice.neutral
        let ctx = skillPolicyContext(skills: slice)
        #expect(slice.isSkillAllowed(name: "any-skill", context: ctx))
    }

    @Test("empty skills allow list denies all")
    func emptyAllowDeniesAll() {
        let slice = ModeProfileSkillsSlice(allow: [], deny: [])
        let ctx = skillPolicyContext(skills: slice)
        #expect(!slice.isSkillAllowed(name: "any-skill", context: ctx))
    }

    @Test("wildcard skills allow list permits any name")
    func wildcardAllowPermitsAll() {
        let slice = ModeProfileSkillsSlice(allow: ["*"], deny: [])
        let ctx = skillPolicyContext(skills: slice)
        #expect(slice.isSkillAllowed(name: "any-skill", context: ctx))
    }

    @Test("explicit skills allow list permits only listed names")
    func explicitAllowList() {
        let slice = ModeProfileSkillsSlice(allow: ["skill-a", "skill-b"], deny: [])
        let ctx = skillPolicyContext(skills: slice)
        #expect(slice.isSkillAllowed(name: "skill-a", context: ctx))
        #expect(slice.isSkillAllowed(name: "skill-b", context: ctx))
        #expect(!slice.isSkillAllowed(name: "other-skill", context: ctx))
    }

    @Test("extends merges skills allow replacement and deny union")
    func extendsMergesSkillSlices() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "restricted-chat",
                    extends: "chat",
                    skills: .object([
                        "allow": .array([.string("skill_a")]),
                        "deny": .array([.string("skill_x")]),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let profile = try await registry.resolve(modeId: "restricted-chat")
        #expect(profile.skills.allow == ["skill_a"])
        #expect(profile.skills.deny.contains("skill_x"))
    }

    @Test("deny beats allow on skills slice")
    func denyBeatsAllow() {
        let slice = ModeProfileSkillsSlice(allow: ["*"], deny: ["blocked"])
        let ctx = ModePolicyContext(
            interactionMode: .chat,
            resolvedProfile: ResolvedModeProfile(
                id: "test",
                interactionMode: .chat,
                assemblyKind: .chat,
                allowsProactiveCompactionTriggers: false,
                appliesAgentBuildOrchestratorHarness: false,
                builtInSeedVersion: 0,
                semanticLayerTags: [],
                skills: slice
            )
        )
        #expect(slice.isSkillAllowed(name: "allowed", context: ctx))
        #expect(!slice.isSkillAllowed(name: "blocked", context: ctx))
    }

    @Test("deny star blocks all skills")
    func denyStarBlocksAll() {
        let slice = ModeProfileSkillsSlice(allow: ["*"], deny: ["*"])
        let ctx = ModePolicyContext(
            interactionMode: .chat,
            resolvedProfile: ResolvedModeProfile(
                id: "test",
                interactionMode: .chat,
                assemblyKind: .chat,
                allowsProactiveCompactionTriggers: false,
                appliesAgentBuildOrchestratorHarness: false,
                builtInSeedVersion: 0,
                semanticLayerTags: [],
                skills: slice
            )
        )
        #expect(!slice.isSkillAllowed(name: "any", context: ctx))
    }

    @Test("includeSkills false denies regardless of allow")
    func includeSkillsFalseDenies() {
        let slice = ModeProfileSkillsSlice(allow: ["*"], deny: [])
        var profile = ResolvedModeProfile.syntheticSeed(id: "test", interactionMode: .chat, assemblyKind: .chat)
        profile.skills = slice
        profile.context.includeSkills = false
        let ctx = ModePolicyContext(interactionMode: .chat, resolvedProfile: profile)
        #expect(!slice.isSkillAllowed(name: "any", context: ctx))
    }

    @Test("routing skill allowlist intersection")
    func routingAllowlistIntersection() {
        let model = Model(
            protocol: .openAIAPI,
            modelName: "skills-test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "s",
            routingPrefs: ConversationRoutingPrefs(
                explicitToolPolicy: .allowlist(tools: [], skills: ["skill-a"])
            )
        )
        #expect(ModeProfileSkillsSlice.isSkillAllowedByRoutingPolicy(name: "skill-a", conversation: conversation))
        #expect(!ModeProfileSkillsSlice.isSkillAllowedByRoutingPolicy(name: "skill-b", conversation: conversation))
    }

    @Test("routing skill denylist blocks listed names")
    func routingDenylistBlocks() {
        let model = Model(
            protocol: .openAIAPI,
            modelName: "skills-test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "s",
            routingPrefs: ConversationRoutingPrefs(
                explicitToolPolicy: .denylist(tools: [], skills: ["skill-b"])
            )
        )
        #expect(ModeProfileSkillsSlice.isSkillAllowedByRoutingPolicy(name: "skill-a", conversation: conversation))
        #expect(!ModeProfileSkillsSlice.isSkillAllowedByRoutingPolicy(name: "skill-b", conversation: conversation))
    }

    private func skillPolicyContext(skills: ModeProfileSkillsSlice) -> ModePolicyContext {
        var profile = ResolvedModeProfile.syntheticSeed(id: "test", interactionMode: .chat, assemblyKind: .chat)
        profile.skills = skills
        return ModePolicyContext(interactionMode: .chat, resolvedProfile: profile)
    }
}
