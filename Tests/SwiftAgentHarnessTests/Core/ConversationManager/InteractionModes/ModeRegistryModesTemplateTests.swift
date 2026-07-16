import EasyJSON
import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("Mode registry — modes.md template behaviors")
struct ModeRegistryModesTemplateTests {
    @Test("extends merges tools deny union and allow replacement")
    func extendsMergesToolSlices() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "restricted-chat",
                    extends: "chat",
                    tools: .object([
                        "allow": .array([.string("tool_a")]),
                        "deny": .array([.string("tool_x")]),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let profile = try await registry.resolve(modeId: "restricted-chat")
        #expect(profile.tools.allow == ["tool_a"])
        #expect(profile.tools.deny.contains("tool_x"))
        #expect(profile.interactionMode == .chat)
    }

    @Test("profilesForPicker exposes label and falls back to id")
    func pickerRowsUseLabels() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "labeled",
                    interactionMode: .plan,
                    assemblyKind: .planCollaboration,
                    allowsProactiveCompactionTriggers: true,
                    appliesAgentBuildOrchestratorHarness: false,
                    semanticLayerTags: [],
                    label: "Zebra Mode",
                    profileDescription: "Desc",
                    symbol: "Z"
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let rows = await registry.profilesForPicker()
        let labeled = try #require(rows.first { $0.id == "labeled" })
        #expect(labeled.label == "Zebra Mode")
        #expect(labeled.description == "Desc")
        #expect(labeled.symbol == "Z")
    }

    @Test("profilesForPicker exposes summary chips aligned with resolved profiles")
    func pickerRowsExposeSummary() async throws {
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true)
        let chat = try await registry.resolve(modeId: InteractionMode.chat.rawValue)
        let plan = try await registry.resolve(modeId: InteractionMode.plan.rawValue)
        let rows = await registry.profilesForPicker()
        let chatRow = try #require(rows.first { $0.id == InteractionMode.chat.rawValue })
        let planRow = try #require(rows.first { $0.id == InteractionMode.plan.rawValue })
        #expect(chatRow.summary?.maxIterations == chat.runtime.maxIterations)
        #expect(planRow.summary?.maxIterations == plan.runtime.maxIterations)
        #expect(chatRow.summary?.toolPolicy == "all")
        #expect(planRow.summary?.compaction == nil)
    }

    @Test("resolveReportingFallback uses chat when id unknown")
    func fallbackLogsAndReturnsChat() async {
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true)
        let log = Logger(label: "test.mode.registry")
        let (profile, didFallback) = await registry.resolveReportingFallback(modeId: "totally_unknown_mode", logger: log)
        #expect(didFallback)
        #expect(profile.id == InteractionMode.chat.rawValue)
    }

    @Test("Tool policy context path is driven by mode profile tools slice")
    func toolPolicyUsesProfileAllowForContextPath() {
        let policy = ToolPolicyConfiguration()
        var resolved = ResolvedModeProfile.builtIn(for: .chat)
        resolved.tools = ModeProfileToolsSlice(allow: ["tool_b"], deny: [], approvalPolicy: nil)
        let ctx = ModePolicyContext(interactionMode: .chat, resolvedProfile: resolved)
        #expect(policy.isToolAllowed(name: "tool_a", context: ctx) == false)
        #expect(policy.isToolAllowed(name: "tool_b", context: ctx))
    }

    @Test("built-in mode profiles seed canonical tools slices")
    func builtInProfilesSeedToolsSlices() async throws {
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true)
        let chat = try await registry.resolve(modeId: InteractionMode.chat.rawValue)
        let plan = try await registry.resolve(modeId: InteractionMode.plan.rawValue)
        let agent = try await registry.resolve(modeId: InteractionMode.agent.rawValue)
        #expect(chat.tools.allow == ["*"])
        #expect(plan.tools.allow?.contains("create_plan") == true)
        #expect(plan.tools.allow?.contains("exit_plan_mode") == true)
        #expect(plan.tools.allow?.contains("ask_user") == true)
        #expect(plan.tools.allow?.contains("think") == true)
        #expect(plan.tools.allow?.contains("finish") == true)
        #expect(plan.tools.allow?.contains("declare_agent_build_complete") == false)
        #expect(agent.tools.allow?.contains("add_plan_note") == true)
        #expect(agent.tools.allow?.contains("enter_plan_mode") == true)
        #expect(agent.tools.allow?.contains("think") == true)
        #expect(agent.tools.allow?.contains("finish") == true)
        #expect(agent.tools.allow?.contains("ask_user") == true)
        #expect(ToolNamePolicyNormalization.listContains(agent.tools.allow ?? [], name: "Coding Agent"))
    }

    @Test("built-in mode profiles seed canonical runtime slices")
    func builtInProfilesSeedRuntimeSlices() async throws {
        let registry = ModeRegistryTestSupport.makeService(
            seedingBuiltIns: true,
            modeProfileConfiguration: .empty
        )
        let chat = try await registry.resolve(modeId: InteractionMode.chat.rawValue)
        let plan = try await registry.resolve(modeId: InteractionMode.plan.rawValue)
        let agent = try await registry.resolve(modeId: InteractionMode.agent.rawValue)
        #expect(chat.runtime.maxIterations == nil)
        #expect(chat.runtime.stopOnApprovalRequest == false)
        #expect(chat.runtime.termination?.policy == .bareMessage)
        #expect(plan.runtime.maxIterations == ModeRegistryService.builtInPlanMaxIterations)
        #expect(plan.runtime.stopOnApprovalRequest == true)
        #expect(plan.runtime.termination?.policy == .terminalTool)
        #expect(plan.runtime.termination?.recovery?.strategy == .forcedToolChoice)
        #expect(plan.runtime.termination?.recovery?.rollbackStalledTurn == true)
        #expect(plan.runtime.termination?.recovery?.maxAttempts == 2)
        #expect(plan.runtime.termination?.recovery?.reminder == .escalating)
        #expect(agent.runtime.maxIterations == nil)
        #expect(agent.runtime.stopOnApprovalRequest == nil)
        #expect(agent.runtime.termination?.policy == .terminalTool)
        #expect(agent.runtime.termination?.recovery?.strategy == .forcedToolChoice)
        #expect(agent.runtime.termination?.recovery?.maxAttempts == 2)
    }

    @Test("bundled PromptConfig plan and agent profiles allow native workspace tools")
    func bundledPromptConfigAllowsNativeWorkspaceTools() async throws {
        let registry = ModeRegistryTestSupport.makeService(
            seedingBuiltIns: true,
            modeProfileConfiguration: try HarnessConversationTestFixtures.promptConfigFixture().modeProfiles
        )
        let plan = try await registry.resolve(modeId: InteractionMode.plan.rawValue)
        let agent = try await registry.resolve(modeId: InteractionMode.agent.rawValue)
        let workspaceTools = [
            WorkspaceFilesystemToolProvider.bashToolName,
            WorkspaceFilesystemToolProvider.readFileToolName,
            WorkspaceFilesystemToolProvider.writeFileToolName,
            WorkspaceFilesystemToolProvider.editFileToolName,
            WorkspaceFilesystemToolProvider.globToolName,
            WorkspaceFilesystemToolProvider.grepToolName,
            WorkspaceFilesystemToolProvider.processToolName,
            WorkspaceFilesystemToolProvider.processSendKeysToolName,
        ]
        for tool in workspaceTools {
            #expect(plan.tools.allow?.contains(tool) == true, "plan profile missing \(tool)")
            #expect(agent.tools.allow?.contains(tool) == true, "agent profile missing \(tool)")
        }
    }

    @Test("bundled PromptConfig agent profile overrides termination recovery maxAttempts")
    func bundledPromptConfigAgentRecoveryMaxAttempts() async throws {
        let registry = ModeRegistryTestSupport.makeService(
            seedingBuiltIns: true,
            modeProfileConfiguration: try HarnessConversationTestFixtures.promptConfigFixture().modeProfiles
        )
        let agent = try await registry.resolve(modeId: InteractionMode.agent.rawValue)
        #expect(agent.runtime.maxIterations == nil)
        #expect(agent.runtime.termination?.recovery?.maxAttempts == 10)
        #expect(agent.runtime.termination?.recovery?.behavioralInjectAfterStalls == 2)
        #expect(agent.runtime.termination?.recovery?.behavioralRecoveryTemperature == 0.2)
    }

    @Test("config maxIterations key with non-numeric value clears inherited cap")
    func configMaxIterationsNonNumericClearsCap() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                .init(
                    id: "uncapped-plan",
                    extends: InteractionMode.plan.rawValue,
                    runtime: .object(["maxIterations": .string("")])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(
            seedingBuiltIns: true,
            modeProfileConfiguration: config
        )
        #expect(try await registry.resolve(modeId: "uncapped-plan").runtime.maxIterations == nil)
    }

    @Test("ModeProfileRuntimeSlice init clamps non-positive maxIterations")
    func runtimeSliceInitClampsNonPositiveMaxIterations() {
        #expect(ModeProfileRuntimeSlice(maxIterations: nil).maxIterations == nil)
        #expect(ModeProfileRuntimeSlice(maxIterations: 0).maxIterations == 1)
        #expect(ModeProfileRuntimeSlice(maxIterations: -5).maxIterations == 1)
        #expect(ModeProfileRuntimeSlice(maxIterations: 8).maxIterations == 8)
    }

    @Test("config maxIterations below 1 clamp to 1")
    func configMaxIterationsBelowOneClamps() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                .init(
                    id: "clamp-zero",
                    extends: InteractionMode.chat.rawValue,
                    runtime: .object(["maxIterations": .integer(0)])
                ),
                .init(
                    id: "clamp-negative",
                    extends: InteractionMode.chat.rawValue,
                    runtime: .object(["maxIterations": .integer(-99)])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(
            seedingBuiltIns: true,
            modeProfileConfiguration: config
        )
        #expect(try await registry.resolve(modeId: "clamp-zero").runtime.maxIterations == 1)
        #expect(try await registry.resolve(modeId: "clamp-negative").runtime.maxIterations == 1)
    }

    @Test("config maxIterations valid overlay values pass through")
    func configMaxIterationsValidValuesPassThrough() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                .init(
                    id: "cap-500",
                    extends: InteractionMode.plan.rawValue,
                    runtime: .object(["maxIterations": .integer(500)])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(
            seedingBuiltIns: true,
            modeProfileConfiguration: config
        )
        #expect(try await registry.resolve(modeId: "cap-500").runtime.maxIterations == 500)
    }

    @Test("built-in mode profiles seed permissive sub-agent allow-list")
    func builtInProfilesSeedSubAgentAllowList() async throws {
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true)
        let chat = try await registry.resolve(modeId: InteractionMode.chat.rawValue)
        let plan = try await registry.resolve(modeId: InteractionMode.plan.rawValue)
        let agent = try await registry.resolve(modeId: InteractionMode.agent.rawValue)
        #expect(chat.subAgents.allow == ["*"])
        #expect(plan.subAgents.allow == ["*"])
        #expect(agent.subAgents.allow == ["*"])
    }

    @Test("extends cycle is skipped with diagnostics")
    func cycleDiagnostics() async {
        let config = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(id: "a", extends: "b"),
                ModeProfileConfiguration.RawProfile(id: "b", extends: "a"),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let diag = await registry.configurationDiagnostics().joined(separator: "\n")
        #expect(diag.contains("cycle"))
    }

    @Test("extends merges context slice overrides and suppressions")
    func extendsMergesContextSlices() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "base-context",
                    interactionMode: .chat,
                    assemblyKind: .chat,
                    allowsProactiveCompactionTriggers: false,
                    appliesAgentBuildOrchestratorHarness: false,
                    semanticLayerTags: [],
                    context: .object([
                        "modeDirective": .string("Base directive"),
                        "suppressSections": .array([.string("tools")]),
                        "sectionOverrides": .object(["triggers": .string("Base triggers")]),
                        "memoryInjection": .string("on"),
                    ])
                ),
                ModeProfileConfiguration.RawProfile(
                    id: "derived-context",
                    extends: "base-context",
                    context: .object([
                        "modeDirective": .string("Derived directive"),
                        "suppressSections": .array([.string("skills")]),
                        "sectionOverrides": .object(["tools": .string("Tool override")]),
                        "memoryInjection": .string("off"),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let profile = try await registry.resolve(modeId: "derived-context")
        #expect(profile.context.modeDirective == "Derived directive")
        #expect(profile.context.memoryInjection == "off")
        #expect(profile.context.suppressSections.contains("tools"))
        #expect(profile.context.suppressSections.contains("skills"))
        #expect(profile.context.sectionOverrides["triggers"] == "Base triggers")
        #expect(profile.context.sectionOverrides["tools"] == "Tool override")
    }

    @Test("extends merges runtime termination overlays")
    func extendsMergesRuntimeTerminationSlices() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "runtime-parent",
                    interactionMode: .agent,
                    assemblyKind: .agentBuild,
                    allowsProactiveCompactionTriggers: true,
                    appliesAgentBuildOrchestratorHarness: true,
                    semanticLayerTags: [],
                    runtime: .object([
                        "termination": .object([
                            "policy": .string("terminal-tool"),
                            "recovery": .object([
                                "strategy": .string("forced-tool-choice"),
                                "rollbackStalledTurn": .boolean(true),
                                "maxAttempts": .integer(2),
                                "reminder": .string("escalating"),
                            ]),
                        ]),
                    ])
                ),
                ModeProfileConfiguration.RawProfile(
                    id: "runtime-child",
                    extends: "runtime-parent",
                    runtime: .object([
                        "termination": .object([
                            "recovery": .object([
                                "maxAttempts": .integer(5),
                                "reminder": .string("off"),
                            ]),
                        ]),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let profile = try await registry.resolve(modeId: "runtime-child")
        #expect(profile.runtime.termination?.policy == .terminalTool)
        #expect(profile.runtime.termination?.recovery?.strategy == .forcedToolChoice)
        #expect(profile.runtime.termination?.recovery?.rollbackStalledTurn == true)
        #expect(profile.runtime.termination?.recovery?.maxAttempts == 5)
        #expect(profile.runtime.termination?.recovery?.reminder == .off)
    }

    @Test("terminal-tool policy defaults recovery when omitted")
    func terminalToolDefaultsRecoveryWhenOmitted() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "terminal-default-recovery",
                    extends: InteractionMode.chat.rawValue,
                    runtime: .object([
                        "termination": .object([
                            "policy": .string("terminal-tool"),
                        ]),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let profile = try await registry.resolve(modeId: "terminal-default-recovery")
        #expect(profile.runtime.termination?.policy == .terminalTool)
        #expect(profile.runtime.termination?.recovery?.strategy == .forcedToolChoice)
        #expect(profile.runtime.termination?.recovery?.rollbackStalledTurn == true)
        #expect(profile.runtime.termination?.recovery?.maxAttempts == 2)
        #expect(profile.runtime.termination?.recovery?.reminder == .escalating)
    }

    @Test("runtime termination onBareMessage legacy key diagnostic is reported")
    func runtimeTerminationLegacyOnBareMessageDiagnostic() async {
        let config = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "legacy-runtime",
                    extends: InteractionMode.agent.rawValue,
                    runtime: .object([
                        "termination": .object([
                            "onBareMessage": .string("recover"),
                        ]),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let diagnostics = await registry.configurationDiagnostics().joined(separator: "\n")
        #expect(diagnostics.contains("modeProfiles[legacy-runtime].runtime.termination.onBareMessage is no longer supported"))
    }

    @Test("runtime termination invalid enum diagnostics are reported")
    func runtimeTerminationInvalidDiagnostics() async {
        let config = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "invalid-runtime",
                    extends: InteractionMode.agent.rawValue,
                    runtime: .object([
                        "termination": .object([
                            "policy": .string("invalid-policy"),
                        ]),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let diagnostics = await registry.configurationDiagnostics().joined(separator: "\n")
        #expect(diagnostics.contains("modeProfiles[invalid-runtime].runtime.termination.policy invalid"))
    }

    @Test("extends merges sub-agent allow-list with wildcard normalization")
    func extendsMergesSubAgentAllowList() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "delegate-restricted",
                    extends: InteractionMode.agent.rawValue,
                    subAgents: .object([
                        "allow": .array([
                            .string("Coding Agent"),
                            .string("web research agent"),
                            .string("Coding Agent"),
                        ]),
                    ])
                ),
                ModeProfileConfiguration.RawProfile(
                    id: "delegate-wildcard",
                    extends: InteractionMode.agent.rawValue,
                    subAgents: .object([
                        "allow": .string("*"),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let restricted = try await registry.resolve(modeId: "delegate-restricted")
        let wildcard = try await registry.resolve(modeId: "delegate-wildcard")
        #expect(restricted.subAgents.allow == ["Coding Agent", "web research agent"])
        #expect(wildcard.subAgents.allow == ["*"])
    }

    @Test("sub-agent allow-list diagnostics report malformed values")
    func subAgentAllowListMalformedDiagnostics() async {
        let config = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "malformed-subagents",
                    extends: InteractionMode.agent.rawValue,
                    subAgents: .object([
                        "allow": .boolean(true),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let diagnostics = await registry.configurationDiagnostics().joined(separator: "\n")
        #expect(diagnostics.contains("modeProfiles[malformed-subagents].subAgents.allow must be '*' or [String]"))
    }

    @Test("tools allow-list diagnostics report malformed values and fail closed")
    func toolsAllowListMalformedDiagnostics() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "malformed-tools",
                    extends: InteractionMode.agent.rawValue,
                    tools: .object([
                        "allow": .string("read_file"),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let profile = try await registry.resolve(modeId: "malformed-tools")
        let diagnostics = await registry.configurationDiagnostics().joined(separator: "\n")
        #expect(profile.tools.allow == [])
        #expect(diagnostics.contains("modeProfiles[malformed-tools].tools.allow must be '*' or [String]"))
    }

    @Test("skills allow-list diagnostics report malformed values and fail closed")
    func skillsAllowListMalformedDiagnostics() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "malformed-skills",
                    extends: InteractionMode.agent.rawValue,
                    skills: .object([
                        "allow": .boolean(true),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let profile = try await registry.resolve(modeId: "malformed-skills")
        let diagnostics = await registry.configurationDiagnostics().joined(separator: "\n")
        #expect(profile.skills.allow == [])
        #expect(diagnostics.contains("modeProfiles[malformed-skills].skills.allow must be '*' or [String]"))
    }

    @Test("tools allow-list accepts string wildcard")
    func toolsAllowListStringWildcard() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "wildcard-tools",
                    extends: InteractionMode.agent.rawValue,
                    tools: .object([
                        "allow": .string("*"),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let profile = try await registry.resolve(modeId: "wildcard-tools")
        #expect(profile.tools.allow == ["*"])
    }
}
