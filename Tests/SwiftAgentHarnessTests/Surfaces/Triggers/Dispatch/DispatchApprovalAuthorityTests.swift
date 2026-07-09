import Foundation
import Testing
import SwiftAgentKit
import SwiftAgentKitOrchestrator
@testable import SwiftAgentHarness

@Suite("Dispatch approval authority")
struct DispatchApprovalAuthorityTests {
    private func gatedSnapshot(toolName: String = "gated_tool") -> RuntimeToolTurnPolicySnapshot {
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: toolName, description: "d", parameters: [], type: .function),
            source: .local
        )
        let decision = ToolAvailabilityDecision(
            allowed: false,
            blockReason: .approvalRequired,
            isSensitive: false,
            requiresEscalation: false,
            requiresApproval: true,
            isElevated: false,
            approvalGranted: false,
            approvalRoute: .user,
            delegationPermissionPolicy: nil,
            delegationTrustLevel: nil
        )
        return RuntimeToolTurnPolicySnapshot(
            availabilitySnapshots: [RuntimeToolAvailabilitySnapshot(entry: entry, decision: decision)],
            effectiveEntries: [entry],
            dispatchContract: .conservativeDefault
        )
    }

    @Test("AgentLoopToolDispatch returns approvalRequired before invokeTool for gated tools")
    func harnessGateReturnsApprovalRequired() async {
        let snapshot = gatedSnapshot()
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        let outcome = await AgentLoopToolDispatch.dispatch(
            call: ToolCallRequest(id: "call-1", name: "gated_tool", arguments: .object([:])),
            conversationID: UUID(),
            runID: UUID(),
            orchestrator: orchestrator,
            snapshot: snapshot
        )
        guard case .approvalRequired(let toolName, let toolCallID) = outcome else {
            Issue.record("Expected approvalRequired, got \(outcome)")
            return
        }
        #expect(toolName == "gated_tool")
        #expect(toolCallID == "call-1")
    }

    @Test("AgentLoopToolDispatch denies tools absent from advertised effective entries")
    func harnessGateDeniesUnadvertisedTools() async {
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "blocked_tool", description: "d", parameters: [], type: .function),
            source: .local
        )
        let decision = ToolAvailabilityDecision(
            allowed: false,
            blockReason: .promptConfigDenylist,
            isSensitive: false,
            requiresEscalation: false,
            requiresApproval: false,
            isElevated: false,
            approvalGranted: false,
            approvalRoute: nil,
            delegationPermissionPolicy: nil,
            delegationTrustLevel: nil
        )
        let snapshot = RuntimeToolTurnPolicySnapshot(
            availabilitySnapshots: [RuntimeToolAvailabilitySnapshot(entry: entry, decision: decision)],
            effectiveEntries: [],
            dispatchContract: .conservativeDefault
        )
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        let outcome = await AgentLoopToolDispatch.dispatch(
            call: ToolCallRequest(id: "call-2", name: "blocked_tool", arguments: .object([:])),
            conversationID: UUID(),
            runID: UUID(),
            orchestrator: orchestrator,
            snapshot: snapshot
        )
        guard case .denied(let message) = outcome else {
            Issue.record("Expected denied, got \(outcome)")
            return
        }
        #expect(message.content.contains("tool not in effective allow-list"))
    }

    @Test("legacy call name passes effective-list gate when canonical tool is advertised")
    func legacyCallNamePassesEffectiveListGate() async {
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "read_file", description: "d", parameters: [], type: .function),
            source: .local
        )
        let decision = ToolAvailabilityDecision(
            allowed: false,
            blockReason: .approvalRequired,
            isSensitive: false,
            requiresEscalation: false,
            requiresApproval: true,
            isElevated: false,
            approvalGranted: false,
            approvalRoute: .user,
            delegationPermissionPolicy: nil,
            delegationTrustLevel: nil
        )
        let snapshot = RuntimeToolTurnPolicySnapshot(
            availabilitySnapshots: [RuntimeToolAvailabilitySnapshot(entry: entry, decision: decision)],
            effectiveEntries: [entry],
            dispatchContract: .conservativeDefault
        )
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        let outcome = await AgentLoopToolDispatch.dispatch(
            call: ToolCallRequest(id: "call-legacy", name: "read", arguments: .object([:])),
            conversationID: UUID(),
            runID: UUID(),
            orchestrator: orchestrator,
            snapshot: snapshot
        )
        guard case .approvalRequired(let toolName, let toolCallID) = outcome else {
            Issue.record("Expected approvalRequired for legacy alias, got \(outcome)")
            return
        }
        #expect(toolName == "read")
        #expect(toolCallID == "call-legacy")
    }
}
