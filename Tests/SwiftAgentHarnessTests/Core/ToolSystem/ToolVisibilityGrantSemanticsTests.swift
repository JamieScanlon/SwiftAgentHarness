import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Tool Visibility Grant semantics")
struct ToolVisibilityGrantSemanticsTests {
    private func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "grant-semantics",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
    }

    private func conversation(mode: InteractionMode = .agent) -> ModelConversation {
        ModelConversation(
            id: UUID(),
            model: makeModel(),
            systemPrompt: "sys",
            interactionMode: mode
        )
    }

    private func mcpEntry(_ name: String = "mcp_search") -> ToolRegistryEntry {
        ToolRegistryEntry(
            definition: ToolDefinition(name: name, description: "d", parameters: [], type: .mcpTool),
            source: .mcp,
            transportKind: .mcp
        )
    }

    private func localEntry(_ name: String = "read_file") -> ToolRegistryEntry {
        ToolRegistryEntry(
            definition: ToolDefinition(name: name, description: "d", parameters: [], type: .function),
            source: .local
        )
    }

    private func pluginEntry(_ name: String = "plugin_echo") -> ToolRegistryEntry {
        ToolRegistryEntry(
            definition: ToolDefinition(name: name, description: "d", parameters: [], type: .function),
            source: .local,
            groupPolicyTags: ["plugins"]
        )
    }

    private func profile(
        id: String = InteractionMode.agent.rawValue,
        mode: InteractionMode = .agent,
        tools: ModeProfileToolsSlice,
        allowsHostGrants: Bool? = nil
    ) -> ResolvedModeProfile {
        ResolvedModeProfile(
            id: id,
            interactionMode: mode,
            assemblyKind: .agentBuild,
            allowsProactiveCompactionTriggers: true,
            appliesAgentBuildOrchestratorHarness: true,
            allowsHostGrants: allowsHostGrants,
            builtInSeedVersion: 0,
            semanticLayerTags: [],
            tools: tools
        )
    }

    private func modeContext(
        for conversation: ModelConversation,
        profile: ResolvedModeProfile
    ) -> ModePolicyContext {
        ModePolicyContext(conversation: conversation, resolvedProfile: profile)
    }

    private func gatewayWithMCPGrant(
        modes: ToolVisibilityGrantModes = .allUserFacing
    ) -> DefaultToolSystemGateway {
        let store = ToolVisibilityGrantStore()
        store.register(
            ToolVisibilityGrantRecord(
                id: ToolVisibilityGrantStore.mcpRegistrationID,
                grant: .grant(modes: modes),
                match: .registrySource(.mcp)
            )
        )
        return DefaultToolSystemGateway(visibilityGrants: store)
    }

    private func evaluate(
        gateway: DefaultToolSystemGateway,
        entry: ToolRegistryEntry,
        conversation: ModelConversation,
        profile: ResolvedModeProfile
    ) -> ToolAvailabilityDecision {
        gateway.evaluateAvailability(
            entry: entry,
            conversation: conversation,
            modePolicyContext: modeContext(for: conversation, profile: profile),
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: .unrestricted,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
    }

    private func evaluateGating(
        gateway: DefaultToolSystemGateway,
        entry: ToolRegistryEntry,
        conversation: ModelConversation,
        profile: ResolvedModeProfile
    ) -> ToolPolicyGatingDecision {
        gateway.evaluateCallGating(
            entry: entry,
            call: ToolCallRequest(id: "c1", name: entry.name, arguments: .object([:])),
            conversation: conversation,
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: .unrestricted,
            modePolicyContext: modeContext(for: conversation, profile: profile),
            groupIndex: .empty,
            durableRules: []
        )
    }

    @Test("MCP allUserFacing grant widens closed allow on chat/plan/agent and auto-allows gating")
    func mcpGrantWidensUserFacingModes() {
        let closed = ModeProfileToolsSlice(allow: ["bash"], deny: [], approvalPolicy: nil)
        let gateway = gatewayWithMCPGrant()
        let entry = mcpEntry()

        for mode in [InteractionMode.chat, .plan, .agent] {
            let conversation = conversation(mode: mode)
            let profile = profile(
                id: mode.rawValue,
                mode: mode,
                tools: closed
            )
            #expect(profile.allowsHostGrants == true)
            let decision = evaluate(
                gateway: gateway,
                entry: entry,
                conversation: conversation,
                profile: profile
            )
            #expect(decision.allowed == true)
            #expect(decision.blockReason == nil)

            let gating = evaluateGating(
                gateway: gateway,
                entry: entry,
                conversation: conversation,
                profile: profile
            )
            #expect(gating.behavior == .allow)
        }
    }

    @Test("mode deny still beats MCP host visibility grant")
    func modeDenyBeatsGrant() {
        let conversation = conversation()
        let profile = profile(
            tools: ModeProfileToolsSlice(allow: ["bash"], deny: ["mcp_search"], approvalPolicy: nil)
        )
        let decision = evaluate(
            gateway: gatewayWithMCPGrant(),
            entry: mcpEntry(),
            conversation: conversation,
            profile: profile
        )
        #expect(decision.allowed == false)
        #expect(decision.blockReason == .promptConfigDenylist)
    }

    @Test("machine profiles never widen via host grants")
    func machineProfilesRejectGrants() {
        let gateway = gatewayWithMCPGrant()
        let entry = mcpEntry()
        for id in ConversationLineageInference.machineSubAgentModeProfileIDs.sorted() {
            let profile = profile(
                id: id,
                tools: ModeProfileToolsSlice(allow: ["bash"], deny: [], approvalPolicy: nil),
                allowsHostGrants: true
            )
            #expect(profile.allowsHostGrants == false)
            #expect(profile.allowsHostGrantsSource == .machinePinned)

            let decision = evaluate(
                gateway: gateway,
                entry: entry,
                conversation: conversation(),
                profile: profile
            )
            #expect(decision.allowed == false)
            #expect(decision.blockReason == .hostVisibilityGrantMiss)
            #expect(decision.grantRejectionCause == .flagDisabled)
        }
    }

    @Test("native provider inheritModeLists stays closed-world")
    func nativeInheritDoesNotWiden() {
        let store = ToolVisibilityGrantStore()
        store.register(
            ToolVisibilityGrantRecord(
                id: ToolVisibilityGrantStore.hostProvidersRegistrationID,
                grant: .inheritModeLists,
                match: .groupPolicyTag("plugins")
            )
        )
        let gateway = DefaultToolSystemGateway(visibilityGrants: store)
        let conversation = conversation()
        let profile = profile(
            tools: ModeProfileToolsSlice(allow: ["bash"], deny: [], approvalPolicy: nil)
        )
        let decision = evaluate(
            gateway: gateway,
            entry: pluginEntry(),
            conversation: conversation,
            profile: profile
        )
        #expect(decision.allowed == false)
        #expect(decision.blockReason == .promptConfigAllowlist)
        #expect(decision.grantRejectionCause == nil)
    }

    @Test("explicit grant modes admit only listed profile IDs")
    func explicitGrantModes() {
        let gateway = gatewayWithMCPGrant(modes: .explicit(["plan"]))
        let entry = mcpEntry()
        let closed = ModeProfileToolsSlice(allow: ["bash"], deny: [], approvalPolicy: nil)

        let planDecision = evaluate(
            gateway: gateway,
            entry: entry,
            conversation: conversation(mode: .plan),
            profile: profile(id: "plan", mode: .plan, tools: closed)
        )
        #expect(planDecision.allowed == true)

        let agentDecision = evaluate(
            gateway: gateway,
            entry: entry,
            conversation: conversation(mode: .agent),
            profile: profile(id: "agent", mode: .agent, tools: closed)
        )
        #expect(agentDecision.allowed == false)
        #expect(agentDecision.blockReason == .hostVisibilityGrantMiss)
        #expect(agentDecision.grantRejectionCause == .modesExcludeProfile)
    }

    @Test("empty allow + matching grant is hostVisibilityGrantMiss with emptyAllowLockdown")
    func emptyAllowSuppressesGrant() {
        let gateway = gatewayWithMCPGrant()
        let profile = profile(
            tools: ModeProfileToolsSlice(allow: [], deny: [], approvalPolicy: nil)
        )
        #expect(profile.allowsHostGrants == false)
        #expect(profile.allowsHostGrantsSource == .derivedEmptyAllow)

        let decision = evaluate(
            gateway: gateway,
            entry: mcpEntry(),
            conversation: conversation(),
            profile: profile
        )
        #expect(decision.allowed == false)
        #expect(decision.blockReason == .hostVisibilityGrantMiss)
        #expect(decision.grantRejectionCause == .emptyAllowLockdown)

        let gating = evaluateGating(
            gateway: gateway,
            entry: mcpEntry(),
            conversation: conversation(),
            profile: profile
        )
        #expect(gating.behavior != .allow)
    }

    @Test("empty allow without matching grant remains promptConfigAllowlist")
    func emptyAllowWithoutGrantIsAllowlist() {
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let profile = profile(
            tools: ModeProfileToolsSlice(allow: [], deny: [], approvalPolicy: nil)
        )
        let decision = evaluate(
            gateway: gateway,
            entry: mcpEntry(),
            conversation: conversation(),
            profile: profile
        )
        #expect(decision.blockReason == .promptConfigAllowlist)
        #expect(decision.grantRejectionCause == nil)
    }

    @Test("explicit allowsHostGrants true escapes empty-allow lockdown")
    func explicitTrueEscapesEmptyAllow() {
        let gateway = gatewayWithMCPGrant()
        let profile = profile(
            tools: ModeProfileToolsSlice(allow: [], deny: [], approvalPolicy: nil),
            allowsHostGrants: true
        )
        #expect(profile.allowsHostGrants == true)
        #expect(profile.allowsHostGrantsSource == .explicit)

        let decision = evaluate(
            gateway: gateway,
            entry: mcpEntry(),
            conversation: conversation(),
            profile: profile
        )
        #expect(decision.allowed == true)
    }

    @Test("explain maps grant miss distinctly from mode allowlist")
    func explainGrantMissDistinctFromAllowlist() throws {
        let store = ToolVisibilityGrantStore()
        store.register(
            ToolVisibilityGrantRecord(
                id: ToolVisibilityGrantStore.mcpRegistrationID,
                grant: .grant(modes: .allUserFacing),
                match: .registrySource(.mcp)
            )
        )
        let gateway = DefaultToolSystemGateway(visibilityGrants: store)
        let conversation = conversation()
        let profile = profile(
            tools: ModeProfileToolsSlice(allow: ["bash"], deny: [], approvalPolicy: nil)
        )
        // Machine pin
        let machine = self.profile(
            id: "subagent-minimal",
            tools: ModeProfileToolsSlice(allow: ["bash"], deny: [], approvalPolicy: nil),
            allowsHostGrants: true
        )
        let report = ToolPolicyAvailabilityExplainer.explain(
            entries: [mcpEntry()],
            conversation: conversation,
            modePolicyContext: modeContext(for: conversation, profile: machine),
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: .unrestricted,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil,
            gateway: gateway
        )
        let row = try #require(report.rows.first)
        #expect(row.gatewayBlockReason == .hostVisibilityGrantMiss)
        #expect(row.primaryScope == .hostVisibilityGrant)
        #expect(row.fixItConfigKey?.contains("allowsHostGrants") == true)
        #expect(row.fixItConfigKey?.contains("modeProfiles.agent.tools.allow") != true)

        let allowlistReport = ToolPolicyAvailabilityExplainer.explain(
            entries: [localEntry()],
            conversation: conversation,
            modePolicyContext: modeContext(for: conversation, profile: profile),
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: .unrestricted,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil,
            gateway: gateway
        )
        let allowlistRow = try #require(allowlistReport.rows.first)
        #expect(allowlistRow.gatewayBlockReason == .promptConfigAllowlist)
        #expect(allowlistRow.primaryScope == .modeAllow)
    }

    @Test("coherence emits grantSuppressedByEmptyAllow once per grant record")
    func coherenceGrantSuppressedNote() {
        let table = ToolVisibilityGrantTable(records: [
            ToolVisibilityGrantRecord(
                id: "mcp",
                grant: .grant(modes: .allUserFacing),
                match: .registrySource(.mcp)
            )
        ])
        let profile = profile(
            tools: ModeProfileToolsSlice(allow: [], deny: [], approvalPolicy: nil)
        )
        let conversation = conversation()
        let report = ToolPolicyCoherenceAnalyzer.analyze(
            entries: [mcpEntry("a"), mcpEntry("b"), localEntry()],
            modePolicyContext: modeContext(for: conversation, profile: profile),
            toolPolicy: .unrestricted,
            conversation: conversation,
            grantTable: table
        )
        #expect(report.grantSuppressedByEmptyAllow.count == 1)
        #expect(report.grantSuppressedByEmptyAllow.first?.ruleToken == "mcp")
        #expect(report.grantSuppressedByEmptyAllow.first?.detail.contains("2 tool") == true)

        let openProfile = self.profile(
            tools: ModeProfileToolsSlice(allow: ["bash"], deny: [], approvalPolicy: nil)
        )
        let openReport = ToolPolicyCoherenceAnalyzer.analyze(
            entries: [mcpEntry()],
            modePolicyContext: modeContext(for: conversation, profile: openProfile),
            toolPolicy: .unrestricted,
            conversation: conversation,
            grantTable: table
        )
        #expect(openReport.grantSuppressedByEmptyAllow.isEmpty)
    }

    @Test("PromptConfig overlay cannot enable allowsHostGrants on machine profiles")
    func machineOverlayCannotEnableHostGrants() async throws {
        let configuration = ModeProfileConfiguration(
            profiles: [
                .init(
                    id: "subagent-minimal",
                    interactionMode: .agent,
                    assemblyKind: .agentBuild,
                    allowsProactiveCompactionTriggers: false,
                    appliesAgentBuildOrchestratorHarness: false,
                    semanticLayerTags: [],
                    allowsHostGrants: true
                )
            ],
            diagnostics: []
        )
        let service = ModeRegistryService(modeProfileConfiguration: configuration)
        let resolved = try await service.resolve(modeId: "subagent-minimal")
        let diagnostics = await service.configurationDiagnostics()
        #expect(resolved.allowsHostGrants == false)
        #expect(resolved.allowsHostGrantsSource == .machinePinned)
        #expect(diagnostics.contains(where: { $0.contains("allowsHostGrants=true ignored") }))
    }

    @Test("child empty allow derives lockdown even when parent explicitly allows host grants")
    func childEmptyAllowBeatsInheritedExplicit() {
        let parent = profile(
            id: "parent-open",
            tools: ModeProfileToolsSlice(allow: ["*"], deny: [], approvalPolicy: nil),
            allowsHostGrants: true
        )
        #expect(parent.allowsHostGrantsSource == .explicit)

        let childResolved = ResolvedModeProfile.resolveAllowsHostGrants(
            id: "child-lockdown",
            tools: ModeProfileToolsSlice(allow: [], deny: []),
            explicitOnThisRow: nil,
            inherited: (parent.allowsHostGrants, parent.allowsHostGrantsSource)
        )
        #expect(childResolved.value == false)
        #expect(childResolved.source == .derivedEmptyAllow)
    }

    @Test("merge path keeps parent explicit allowsHostGrants false across child overlay")
    func mergePathKeepsExplicitFalseSticky() async throws {
        let configuration = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "grants-off",
                    interactionMode: .agent,
                    assemblyKind: .agentBuild,
                    allowsProactiveCompactionTriggers: true,
                    appliesAgentBuildOrchestratorHarness: true,
                    semanticLayerTags: [],
                    allowsHostGrants: false,
                    tools: .object([
                        "allow": .array([.string("bash")]),
                    ])
                ),
                ModeProfileConfiguration.RawProfile(
                    id: "grants-off-child",
                    extends: "grants-off",
                    tools: .object([
                        "allow": .array([.string("bash"), .string("read_file")]),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(
            seedingBuiltIns: true,
            modeProfileConfiguration: configuration
        )
        let parent = try await registry.resolve(modeId: "grants-off")
        #expect(parent.allowsHostGrants == false)
        #expect(parent.allowsHostGrantsSource == .explicit)

        let child = try await registry.resolve(modeId: "grants-off-child")
        #expect(child.tools.allow == ["bash", "read_file"])
        #expect(child.allowsHostGrants == false)
        #expect(child.allowsHostGrantsSource == .explicit)
    }
}
