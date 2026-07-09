import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ToolPolicyExplainInspector")
struct ToolPolicyExplainInspectorTests {
    private let gateway = DefaultToolSystemGateway()

    private func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "explain-test",
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

    @Test("empty mode allow blocks at modeAllow with profile fix-it key")
    func emptyModeAllowBlocks() throws {
        let conversation = ModelConversation(
            id: UUID(),
            model: makeModel(),
            systemPrompt: "sys",
            interactionMode: .agent
        )
        let modeCtx = modeContext(
            conversation: conversation,
            tools: ModeProfileToolsSlice(allow: [], deny: [], approvalPolicy: nil)
        )
        let entries = [localEntry("read_file"), localEntry("bash")]
        let report = ToolPolicyAvailabilityExplainer.explain(
            entries: entries,
            conversation: conversation,
            modePolicyContext: modeCtx,
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: .unrestricted,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil,
            gateway: gateway
        )
        #expect(report.blockedCount == entries.count)
        let row = try #require(report.rows.first)
        #expect(row.status == .blocked)
        #expect(row.primaryScope == .modeAllow)
        #expect(row.fixItConfigKey?.contains("modeProfiles.") == true)
        #expect(row.fixItConfigKey?.contains(".tools.allow") == true)
    }

    @Test("mode deny group:mcp blocks MCP tools at modeDeny")
    func modeDenyGroupMCP() throws {
        let conversation = ModelConversation(
            id: UUID(),
            model: makeModel(),
            systemPrompt: "sys",
            interactionMode: .agent
        )
        let modeCtx = modeContext(
            conversation: conversation,
            tools: ModeProfileToolsSlice(allow: ["*"], deny: ["group:mcp"], approvalPolicy: nil)
        )
        let entries = [localEntry("read_file"), mcpEntry("search")]
        let report = ToolPolicyAvailabilityExplainer.explain(
            entries: entries,
            conversation: conversation,
            modePolicyContext: modeCtx,
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: .unrestricted,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil,
            gateway: gateway
        )
        let mcpRow = try #require(report.rows.first { $0.toolName == "search" })
        #expect(mcpRow.status == .blocked)
        #expect(mcpRow.primaryScope == .modeDeny)
        let readRow = try #require(report.rows.first { $0.toolName == "read_file" })
        #expect(readRow.status == .effective)
    }

    @Test("routing deny group:mcp blocks at routingToolPolicy")
    func routingDenyGroupMCP() throws {
        var conversation = ModelConversation(
            id: UUID(),
            model: makeModel(),
            systemPrompt: "sys",
            interactionMode: .agent
        )
        conversation.routingPrefs = ConversationRoutingPrefs(
            explicitToolPolicy: .denylist(tools: ["group:mcp"], skills: [])
        )
        let modeCtx = modeContext(
            conversation: conversation,
            tools: ModeProfileToolsSlice(allow: ["*"], deny: [], approvalPolicy: nil)
        )
        let entries = [localEntry("read_file"), mcpEntry("lookup")]
        let report = ToolPolicyAvailabilityExplainer.explain(
            entries: entries,
            conversation: conversation,
            modePolicyContext: modeCtx,
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: .unrestricted,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil,
            gateway: gateway
        )
        let mcpRow = try #require(report.rows.first { $0.toolName == "lookup" })
        #expect(mcpRow.status == .blocked)
        #expect(mcpRow.primaryScope == .routingToolPolicy)
    }

    @Test("approval-required tool is approval-gated not hard blocked")
    func approvalGatedStatus() throws {
        let conversation = ModelConversation(
            id: UUID(),
            model: makeModel(),
            systemPrompt: "sys",
            interactionMode: .agent
        )
        let modeCtx = modeContext(
            conversation: conversation,
            tools: ModeProfileToolsSlice(allow: ["*"], deny: [], approvalPolicy: nil)
        )
        let toolName = ConversationsToolProvider.listConversationsToolName
        let entries = [localEntry(toolName)]
        let policy = ToolPolicyConfiguration(approvalRequiredToolNames: [toolName])
        let report = ToolPolicyAvailabilityExplainer.explain(
            entries: entries,
            conversation: conversation,
            modePolicyContext: modeCtx,
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: policy,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil,
            gateway: gateway
        )
        let row = try #require(report.rows.first)
        #expect(row.status == .approvalGated)
        #expect(row.primaryScope == .approval)
        #expect(report.approvalGatedCount == 1)
        #expect(report.blockedCount == 0)
    }

    @Test("formatter includes fix-it config key line")
    func formatterFixItKey() {
        let conversation = ModelConversation(
            id: UUID(),
            model: makeModel(),
            systemPrompt: "sys",
            interactionMode: .agent
        )
        let modeCtx = modeContext(
            conversation: conversation,
            tools: ModeProfileToolsSlice(allow: ["group:fs"], deny: [], approvalPolicy: nil)
        )
        let entries = [localEntry("bash")]
        let report = ToolPolicyAvailabilityExplainer.explain(
            entries: entries,
            conversation: conversation,
            modePolicyContext: modeCtx,
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: .unrestricted,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil,
            gateway: gateway
        )
        let formatted = ToolPolicyExplainFormatter.format(report: report)
        #expect(formatted.contains("fix-it:"))
        #expect(formatted.contains("modeProfiles."))
        #expect(formatted.contains(".tools.allow"))
    }
}
