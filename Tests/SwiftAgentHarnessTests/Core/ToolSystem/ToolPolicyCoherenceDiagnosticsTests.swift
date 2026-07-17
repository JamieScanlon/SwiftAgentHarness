import Foundation
import Logging
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ToolPolicyCoherenceDiagnostics")
struct ToolPolicyCoherenceDiagnosticsTests {
    private func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "coherence-test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
    }

    private func localEntry(_ name: String) -> ToolRegistryEntry {
        ToolRegistryEntry(
            definition: ToolDefinition(name: name, description: "", parameters: [], type: .function),
            source: .local
        )
    }

    private func mcpEntry(_ name: String) -> ToolRegistryEntry {
        ToolRegistryEntry(
            definition: ToolDefinition(name: name, description: "", parameters: [], type: .mcpTool),
            source: .mcp,
            transportKind: .mcp
        )
    }

    private func modeContext(
        conversation: ModelConversation,
        tools: ModeProfileToolsSlice
    ) -> ModePolicyContext {
        var resolved = ResolvedModeProfile.builtIn(for: .agent)
        resolved.tools = tools
        return ModePolicyContext(conversation: conversation, resolvedProfile: resolved)
    }

    private func makeConversation(routingPrefs: ConversationRoutingPrefs? = nil) -> ModelConversation {
        ModelConversation(
            id: UUID(),
            model: makeModel(),
            systemPrompt: "sys",
            interactionMode: .agent,
            routingPrefs: routingPrefs
        )
    }

    @Test("bare allow nonexistent_tool emits unknownEntry")
    func bareAllowUnknownEntry() {
        let conversation = makeConversation()
        let modeCtx = modeContext(
            conversation: conversation,
            tools: ModeProfileToolsSlice(allow: ["nonexistent_tool", "read_file"], deny: [], approvalPolicy: nil)
        )
        let entries = [localEntry("read_file"), localEntry("bash")]
        let report = ToolPolicyCoherenceAnalyzer.analyze(
            entries: entries,
            modePolicyContext: modeCtx,
            toolPolicy: .unrestricted,
            conversation: conversation
        )
        #expect(report.unknownEntries.contains { $0.ruleToken == "nonexistent_tool" && $0.scope == .modeToolsAllow })
    }

    @Test("glob mcp_* with no MCP tools emits unknownEntry")
    func globNoMatchUnknownEntry() {
        let conversation = makeConversation()
        let modeCtx = modeContext(
            conversation: conversation,
            tools: ModeProfileToolsSlice(allow: ["mcp_*", "read_file"], deny: [], approvalPolicy: nil)
        )
        let entries = [localEntry("read_file"), localEntry("bash")]
        let report = ToolPolicyCoherenceAnalyzer.analyze(
            entries: entries,
            modePolicyContext: modeCtx,
            toolPolicy: .unrestricted,
            conversation: conversation
        )
        #expect(report.unknownEntries.contains { $0.ruleToken == "mcp_*" })
    }

    @Test("mode allow bash shadowed by mode deny group:runtime")
    func modeAllowShadowedByRuntimeDeny() throws {
        let conversation = makeConversation()
        let modeCtx = modeContext(
            conversation: conversation,
            tools: ModeProfileToolsSlice(allow: ["bash", "read_file"], deny: ["group:runtime"], approvalPolicy: nil)
        )
        let entries = [localEntry("read_file"), localEntry("bash")]
        let report = ToolPolicyCoherenceAnalyzer.analyze(
            entries: entries,
            modePolicyContext: modeCtx,
            toolPolicy: .unrestricted,
            conversation: conversation
        )
        let shadow = try #require(report.shadowedAllows.first { $0.ruleToken == "bash" })
        #expect(shadow.shadowedBy.contains("group:runtime"))
        #expect(!report.shadowedAllows.contains { $0.ruleToken == "read_file" })
    }

    @Test("mode deny star shadows all mode allows")
    func modeDenyStarShadowsAllAllows() {
        let conversation = makeConversation()
        let modeCtx = modeContext(
            conversation: conversation,
            tools: ModeProfileToolsSlice(allow: ["read_file", "bash"], deny: ["*"], approvalPolicy: nil)
        )
        let entries = [localEntry("read_file"), localEntry("bash")]
        let report = ToolPolicyCoherenceAnalyzer.analyze(
            entries: entries,
            modePolicyContext: modeCtx,
            toolPolicy: .unrestricted,
            conversation: conversation
        )
        #expect(report.shadowedAllows.count == 2)
        #expect(report.shadowedAllows.allSatisfy { $0.shadowedBy.contains("*") })
    }

    @Test("routing deny does not shadow mode allow in different slice")
    func routingDenyDoesNotShadowModeAllow() {
        let conversation = makeConversation(
            routingPrefs: ConversationRoutingPrefs(
                explicitToolPolicy: .denylist(tools: ["group:mcp"], skills: [])
            )
        )
        let modeCtx = modeContext(
            conversation: conversation,
            tools: ModeProfileToolsSlice(allow: ["bash", "read_file"], deny: [], approvalPolicy: nil)
        )
        let entries = [localEntry("read_file"), localEntry("bash"), mcpEntry("search")]
        let report = ToolPolicyCoherenceAnalyzer.analyze(
            entries: entries,
            modePolicyContext: modeCtx,
            toolPolicy: .unrestricted,
            conversation: conversation
        )
        #expect(report.shadowedAllows.isEmpty)
    }

    @Test("formatter coherence section includes fix-it and shadowed markers")
    func formatterCoherenceSection() {
        let conversation = makeConversation()
        let modeCtx = modeContext(
            conversation: conversation,
            tools: ModeProfileToolsSlice(allow: ["bash"], deny: ["group:runtime"], approvalPolicy: nil)
        )
        let entries = [localEntry("bash")]
        let explainReport = ToolPolicyAvailabilityExplainer.explain(
            entries: entries,
            conversation: conversation,
            modePolicyContext: modeCtx,
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: .unrestricted,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil,
            gateway: DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        )
        let coherenceReport = ToolPolicyCoherenceAnalyzer.analyze(
            entries: entries,
            modePolicyContext: modeCtx,
            toolPolicy: .unrestricted,
            conversation: conversation
        )
        let formatted = ToolPolicyExplainFormatter.format(
            report: explainReport,
            coherenceReport: coherenceReport
        )
        #expect(formatted.contains("Policy coherence:"))
        #expect(formatted.contains("fix-it:"))
        #expect(formatted.contains("Shadowed allows"))
        #expect(formatted.contains("shadowed by:"))
    }

    @Test("diagnostics actor deduplicates by catalog fingerprint")
    func diagnosticsDedup() async {
        let box = CoherenceLogCaptureBox()
        var logger = Logger(label: "coherence-test")
        logger.logLevel = .warning
        logger.handler = CoherenceLogCaptureHandler(box: box)

        let conversation = makeConversation()
        let modeCtx = modeContext(
            conversation: conversation,
            tools: ModeProfileToolsSlice(allow: ["nonexistent_tool"], deny: [], approvalPolicy: nil)
        )
        let entries = [localEntry("read_file")]
        let report = ToolPolicyCoherenceAnalyzer.analyze(
            entries: entries,
            modePolicyContext: modeCtx,
            toolPolicy: .unrestricted,
            conversation: conversation
        )
        let fingerprint = ToolPolicyCoherenceAnalyzer.catalogFingerprint(from: entries)

        await ToolPolicyCoherenceDiagnostics.shared.resetForTesting()
        await ToolPolicyCoherenceDiagnostics.shared.log(
            report: report,
            catalogFingerprint: fingerprint,
            logger: logger
        )
        await ToolPolicyCoherenceDiagnostics.shared.log(
            report: report,
            catalogFingerprint: fingerprint,
            logger: logger
        )
        #expect(box.warnings.count == 1)

        let expandedEntries = [localEntry("read_file"), localEntry("bash")]
        let expandedFingerprint = ToolPolicyCoherenceAnalyzer.catalogFingerprint(from: expandedEntries)
        await ToolPolicyCoherenceDiagnostics.shared.log(
            report: report,
            catalogFingerprint: expandedFingerprint,
            logger: logger
        )
        #expect(box.warnings.count == 2)
    }

    @Test("clean catalog shows no coherence issues in formatter")
    func cleanCoherenceSection() {
        let conversation = makeConversation()
        let modeCtx = modeContext(
            conversation: conversation,
            tools: ModeProfileToolsSlice(allow: ["read_file"], deny: [], approvalPolicy: nil)
        )
        let entries = [localEntry("read_file")]
        let coherenceReport = ToolPolicyCoherenceAnalyzer.analyze(
            entries: entries,
            modePolicyContext: modeCtx,
            toolPolicy: .unrestricted,
            conversation: conversation
        )
        let section = ToolPolicyExplainFormatter.formatCoherenceSection(coherenceReport)
        #expect(section.contains("Policy coherence:"))
        #expect(section.contains("No coherence issues detected."))
    }

    @Test("prompt config unknown sensitive tool emits unknownEntry")
    func promptConfigUnknownEntry() {
        let conversation = makeConversation()
        let modeCtx = modeContext(
            conversation: conversation,
            tools: ModeProfileToolsSlice(allow: nil, deny: [], approvalPolicy: nil)
        )
        let entries = [localEntry("read_file")]
        let policy = ToolPolicyConfiguration(sensitiveToolNames: ["missing_sensitive_tool"])
        let report = ToolPolicyCoherenceAnalyzer.analyze(
            entries: entries,
            modePolicyContext: modeCtx,
            toolPolicy: policy,
            conversation: conversation
        )
        #expect(report.unknownEntries.contains {
            $0.ruleToken == "missing_sensitive_tool" && $0.scope == .promptConfigSensitive
        })
    }

    @Test("grant covering profile without allowsHostGrants emits grantInactiveWithoutOptIn info")
    func grantInactiveWithoutOptIn() {
        let conversation = makeConversation()
        let modeCtx = modeContext(
            conversation: conversation,
            tools: ModeProfileToolsSlice(allow: ["bash"], deny: [], approvalPolicy: nil)
        )
        #expect(modeCtx.resolvedProfile.allowsHostGrants == false)
        let table = ToolVisibilityGrantTable(records: [
            ToolVisibilityGrantRecord(
                id: "mcp",
                grant: .grant(modes: .allOptedIn),
                match: .registrySource(.mcp)
            )
        ])
        let report = ToolPolicyCoherenceAnalyzer.analyze(
            entries: [mcpEntry("mcp_search"), mcpEntry("mcp_other"), localEntry("bash")],
            modePolicyContext: modeCtx,
            toolPolicy: .unrestricted,
            conversation: conversation,
            grantTable: table
        )
        #expect(report.grantsInactiveWithoutOptIn.count == 1)
        #expect(report.grantsInactiveWithoutOptIn.first?.ruleToken == "mcp")
        #expect(report.grantsInactiveWithoutOptIn.first?.detail.contains("2 tool") == true)
        #expect(report.grantsInactiveWithoutOptIn.first?.scope == .hostVisibilityGrant)
        #expect(
            report.grantsInactiveWithoutOptIn.first?.fixItConfigKey(profileID: "agent")
                .contains("allowsHostGrants") == true
        )

        let section = ToolPolicyExplainFormatter.formatCoherenceSection(report)
        #expect(section.contains("Grants inactive without opt-in"))
        #expect(section.contains("allowsHostGrants"))
    }

    @Test("grant inactive diagnostic skips when profile opted in")
    func grantInactiveSkippedWhenOptedIn() {
        let conversation = makeConversation()
        var resolved = ResolvedModeProfile.builtIn(for: .agent)
        resolved.tools = ModeProfileToolsSlice(allow: ["bash"], deny: [], approvalPolicy: nil)
        resolved.allowsHostGrants = true
        resolved.allowsHostGrantsSource = .explicit
        let modeCtx = ModePolicyContext(conversation: conversation, resolvedProfile: resolved)
        let table = ToolVisibilityGrantTable(records: [
            ToolVisibilityGrantRecord(
                id: "mcp",
                grant: .grant(modes: .allOptedIn),
                match: .registrySource(.mcp)
            )
        ])
        let report = ToolPolicyCoherenceAnalyzer.analyze(
            entries: [mcpEntry("mcp_search")],
            modePolicyContext: modeCtx,
            toolPolicy: .unrestricted,
            conversation: conversation,
            grantTable: table
        )
        #expect(report.grantsInactiveWithoutOptIn.isEmpty)
    }

    @Test("grant inactive diagnostic skips machine-pinned profiles")
    func grantInactiveSkippedForMachinePin() {
        let conversation = makeConversation()
        let profile = ResolvedModeProfile(
            id: "subagent-minimal",
            interactionMode: .agent,
            assemblyKind: .agentBuild,
            allowsProactiveCompactionTriggers: false,
            appliesAgentBuildOrchestratorHarness: false,
            allowsHostGrants: true,
            builtInSeedVersion: 0,
            semanticLayerTags: [],
            tools: ModeProfileToolsSlice(allow: ["bash"], deny: [], approvalPolicy: nil)
        )
        #expect(profile.allowsHostGrantsSource == .machinePinned)
        let modeCtx = ModePolicyContext(conversation: conversation, resolvedProfile: profile)
        let table = ToolVisibilityGrantTable(records: [
            ToolVisibilityGrantRecord(
                id: "mcp",
                grant: .grant(modes: .allOptedIn),
                match: .registrySource(.mcp)
            )
        ])
        let report = ToolPolicyCoherenceAnalyzer.analyze(
            entries: [mcpEntry("mcp_search")],
            modePolicyContext: modeCtx,
            toolPolicy: .unrestricted,
            conversation: conversation,
            grantTable: table
        )
        #expect(report.grantsInactiveWithoutOptIn.isEmpty)
    }

    @Test("inheritModeLists registration does not emit grant inactive diagnostic")
    func inheritDoesNotEmitInactive() {
        let conversation = makeConversation()
        let modeCtx = modeContext(
            conversation: conversation,
            tools: ModeProfileToolsSlice(allow: ["bash"], deny: [], approvalPolicy: nil)
        )
        let table = ToolVisibilityGrantTable(records: [
            ToolVisibilityGrantRecord(
                id: "mcp",
                grant: .inheritModeLists,
                match: .registrySource(.mcp)
            )
        ])
        let report = ToolPolicyCoherenceAnalyzer.analyze(
            entries: [mcpEntry("mcp_search")],
            modePolicyContext: modeCtx,
            toolPolicy: .unrestricted,
            conversation: conversation,
            grantTable: table
        )
        #expect(report.grantsInactiveWithoutOptIn.isEmpty)
    }

    @Test("explicit grant modes exclude non-listed profiles from inactive diagnostic")
    func explicitModesExcludeOtherProfiles() {
        let conversation = makeConversation()
        let modeCtx = modeContext(
            conversation: conversation,
            tools: ModeProfileToolsSlice(allow: ["bash"], deny: [], approvalPolicy: nil)
        )
        #expect(modeCtx.resolvedProfile.id == "agent")
        let table = ToolVisibilityGrantTable(records: [
            ToolVisibilityGrantRecord(
                id: "mcp",
                grant: .grant(modes: .explicit(["plan"])),
                match: .registrySource(.mcp)
            )
        ])
        let report = ToolPolicyCoherenceAnalyzer.analyze(
            entries: [mcpEntry("mcp_search")],
            modePolicyContext: modeCtx,
            toolPolicy: .unrestricted,
            conversation: conversation,
            grantTable: table
        )
        #expect(report.grantsInactiveWithoutOptIn.isEmpty)
    }
}

private final class CoherenceLogCaptureBox: @unchecked Sendable {
    private var messages: [String] = []
    private let lock = NSLock()

    func append(_ message: String) {
        lock.withLock { messages.append(message) }
    }

    var warnings: [String] {
        lock.withLock { messages }
    }
}

private struct CoherenceLogCaptureHandler: LogHandler {
    let box: CoherenceLogCaptureBox
    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .trace

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        metadata: Logging.Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        if level >= Logging.Logger.Level.warning {
            box.append(message.description)
        }
    }
}
