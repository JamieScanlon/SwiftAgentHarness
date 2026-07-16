import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ToolPolicyAvailabilityIntegration")
struct ToolPolicyAvailabilityIntegrationTests {
    private let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())

    private func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "tool-policy-test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
    }

    private func modeContext(tools: ModeProfileToolsSlice) -> (ModePolicyContext, ModelConversation) {
        var resolved = ResolvedModeProfile.builtIn(for: .agent)
        resolved.tools = tools
        let conversation = ModelConversation(id: UUID(), model: makeModel(), interactionMode: .agent)
        let context = ModePolicyContext(conversation: conversation, resolvedProfile: resolved)
        return (context, conversation)
    }

    private func mcpEntry(_ name: String) -> ToolRegistryEntry {
        ToolRegistryEntry(
            definition: ToolDefinition(name: name, description: "", parameters: [], type: .mcpTool),
            source: .mcp,
            transportKind: .mcp
        )
    }

    private func readEntry() -> ToolRegistryEntry {
        ToolRegistryEntry(
            definition: ToolDefinition(name: "read_file", description: "", parameters: [], type: .function),
            source: .local
        )
    }

    @Test("mode allow group:fs permits read_file")
    func modeAllowGroupFS() {
        let entries = [readEntry(), mcpEntry("search")]
        let groupIndex = ToolPolicyGroupIndex.build(from: entries)
        var resolved = ResolvedModeProfile.builtIn(for: .agent)
        resolved.tools = ModeProfileToolsSlice(allow: ["group:fs"], deny: [], approvalPolicy: nil)
        let context = ModePolicyContext(interactionMode: .agent, resolvedProfile: resolved)
        let policy = ToolPolicyConfiguration.unrestricted
        #expect(resolved.tools.allow == ["group:fs"])
        #expect(policy.isToolAllowed(
            name: "read_file",
            context: context,
            groupIndex: groupIndex,
            entry: readEntry()
        ))
        #expect(policy.isToolAllowed(
            name: "search",
            context: context,
            groupIndex: groupIndex,
            entry: mcpEntry("search")
        ) == false)
    }

    @Test("routing deny group:mcp blocks MCP tools")
    func routingDenyGroupMCP() {
        let pair = modeContext(tools: ModeProfileToolsSlice(allow: ["*"], deny: [], approvalPolicy: nil))
        let context = pair.0
        var conversation = pair.1
        conversation.routingPrefs = ConversationRoutingPrefs(
            explicitToolPolicy: .denylist(tools: ["group:mcp"], skills: [])
        )
        let entries = [readEntry(), mcpEntry("search")]
        let groupIndex = ToolPolicyGroupIndex.build(from: entries)
        let runtimeConfig = AgentRuntimeTurnConfiguration(enableTools: true, enableAgents: true)

        let mcpDecision = gateway.evaluateAvailability(
            entry: mcpEntry("search"),
            conversation: conversation,
            modePolicyContext: context,
            configuration: runtimeConfig,
            toolPolicy: .unrestricted,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil,
            groupIndex: groupIndex
        )
        #expect(mcpDecision.allowed == false)
        #expect(mcpDecision.blockReason == ToolAvailabilityBlockReason.routingToolWhitelist)
    }
}
