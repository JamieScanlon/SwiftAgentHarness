import EasyJSON
import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Mode profile allow+/deny+ merge")
struct ModeProfileAdditiveMergeTests {
    @Test("allow+ onto parent wildcard stays open")
    func allowPlusOntoWildcardIsNoOp() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "plus-chat",
                    extends: "chat",
                    tools: .object([
                        "allow+": .array([.string("extra_tool")]),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let profile = try await registry.resolve(modeId: "plus-chat")
        #expect(profile.tools.allow == ["*"])
    }

    @Test("allow+ onto parent nil stays open — never materialize closed world")
    func allowPlusOntoNilIsNoOp() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "open-parent",
                    interactionMode: .chat,
                    assemblyKind: .chat,
                    allowsProactiveCompactionTriggers: false,
                    appliesAgentBuildOrchestratorHarness: false,
                    semanticLayerTags: [],
                    tools: .object([:])
                ),
                ModeProfileConfiguration.RawProfile(
                    id: "plus-open",
                    extends: "open-parent",
                    tools: .object([
                        "allow+": .array([.string("foo")]),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let parent = try await registry.resolve(modeId: "open-parent")
        #expect(parent.tools.allow == nil)
        let child = try await registry.resolve(modeId: "plus-open")
        #expect(child.tools.allow == nil)
    }

    @Test("allow replace then allow+ append is stage-wise")
    func allowThenAllowPlus() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "stage-chat",
                    extends: "chat",
                    tools: .object([
                        "allow": .array([.string("bash"), .string("read_file")]),
                        "allow+": .array([.string("mcp_search")]),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let profile = try await registry.resolve(modeId: "stage-chat")
        #expect(profile.tools.allow == ["bash", "mcp_search", "read_file"])
    }

    @Test("allow empty plus allow+ empty keeps lockdown and derivedEmptyAllow")
    func emptyAllowPlusEmptyKeepsLockdown() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "locked",
                    extends: "chat",
                    tools: .object([
                        "allow": .array([]),
                        "allow+": .array([]),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let profile = try await registry.resolve(modeId: "locked")
        #expect(profile.tools.allow == [])
        #expect(profile.allowsHostGrants == false)
        #expect(profile.allowsHostGrantsSource == .derivedEmptyAllow)
    }

    @Test("allow empty plus allow+ entries opens hatch from lockdown")
    func emptyAllowPlusEntries() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "hatch",
                    extends: "chat",
                    tools: .object([
                        "allow": .array([]),
                        "allow+": .array([.string("foo")]),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let profile = try await registry.resolve(modeId: "hatch")
        #expect(profile.tools.allow == ["foo"])
        #expect(profile.allowsHostGrants == true)
        #expect(profile.allowsHostGrantsSource == .derivedUserFacing)
    }

    @Test("deny and deny+ are append-only aliases and cannot strip parent deny")
    func denyAndDenyPlusAppendOnly() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "deny-parent",
                    interactionMode: .agent,
                    assemblyKind: .agentBuild,
                    allowsProactiveCompactionTriggers: true,
                    appliesAgentBuildOrchestratorHarness: true,
                    semanticLayerTags: [],
                    tools: .object([
                        "allow": .array([.string("*")]),
                        "deny": .array([.string("parent_denied")]),
                    ])
                ),
                ModeProfileConfiguration.RawProfile(
                    id: "deny-child",
                    extends: "deny-parent",
                    tools: .object([
                        "deny": .array([.string("child_denied")]),
                        "deny+": .array([.string("plus_denied")]),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let profile = try await registry.resolve(modeId: "deny-child")
        #expect(profile.tools.deny.contains("parent_denied"))
        #expect(profile.tools.deny.contains("child_denied"))
        #expect(profile.tools.deny.contains("plus_denied"))
    }

    @Test("skills.allow+ mirrors tools open-world no-op and replace-then-append")
    func skillsAllowPlus() async throws {
        let starConfig = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "skills-star",
                    extends: "chat",
                    skills: .object([
                        "allow": .array([.string("*")]),
                        "allow+": .array([.string("extra_skill")]),
                    ])
                ),
            ],
            diagnostics: []
        )
        let starRegistry = ModeRegistryTestSupport.makeService(
            seedingBuiltIns: true,
            modeProfileConfiguration: starConfig
        )
        let starProfile = try await starRegistry.resolve(modeId: "skills-star")
        #expect(starProfile.skills.allow == ["*"])

        let closedConfig = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "skills-closed",
                    extends: "chat",
                    skills: .object([
                        "allow": .array([.string("skill_a")]),
                        "allow+": .array([.string("skill_b")]),
                        "deny+": .array([.string("skill_x")]),
                    ])
                ),
            ],
            diagnostics: []
        )
        let closedRegistry = ModeRegistryTestSupport.makeService(
            seedingBuiltIns: true,
            modeProfileConfiguration: closedConfig
        )
        let closedProfile = try await closedRegistry.resolve(modeId: "skills-closed")
        #expect(closedProfile.skills.allow == ["skill_a", "skill_b"])
        #expect(closedProfile.skills.deny.contains("skill_x"))
    }
}
