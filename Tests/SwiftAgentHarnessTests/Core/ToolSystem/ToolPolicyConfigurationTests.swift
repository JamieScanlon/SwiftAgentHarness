import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ToolPolicyConfiguration")
struct ToolPolicyConfigurationTests {
    @Test("unrestricted policy defaults to conservative dispatch")
    func unrestrictedDefaultsToConservativeDispatch() {
        let policy = ToolPolicyConfiguration.unrestricted
        #expect(policy.parallelDispatchEnabled == false)
        #expect(policy.pendingToolTimeoutSeconds == nil)
    }

    @Test("stable allowlist signature includes dispatch contract")
    func stableSignatureIncludesDispatchContract() {
        let base = ToolPolicyConfiguration(
            parallelDispatchEnabled: false,
            pendingToolTimeoutSeconds: nil
        )
        let enabled = ToolPolicyConfiguration(
            parallelDispatchEnabled: true,
            pendingToolTimeoutSeconds: 30
        )
        #expect(base.stableAllowlistSignature() != enabled.stableAllowlistSignature())
    }

    @Test("deny policy precedence and sensitivity metadata are available")
    func denyAndSensitivityPolicy() async throws {
        let policy = ToolPolicyConfiguration(
            sensitiveToolNames: ["dangerous_tool"],
            escalationRequiredToolNames: ["dangerous_tool"],
            approvalRequiredToolNames: ["dangerous_tool"],
            elevatedToolNames: ["dangerous_tool"]
        )
        var chatProfile = try await ModeRegistryTestSupport.makeService(seedingBuiltIns: true).resolve(modeId: InteractionMode.chat.rawValue)
        chatProfile.tools = ModeProfileToolsSlice(allow: ["*"], deny: ["dangerous_tool"], approvalPolicy: nil)
        let chatContext = ModePolicyContext(interactionMode: .chat, resolvedProfile: chatProfile)
        #expect(policy.isToolAllowed(name: "dangerous_tool", context: chatContext))
        #expect(policy.isToolDenied(name: "dangerous_tool", context: chatContext))
        #expect(policy.isToolSensitive(name: "dangerous_tool"))
        #expect(policy.requiresEscalation(name: "dangerous_tool"))
        #expect(policy.requiresApproval(name: "dangerous_tool"))
        #expect(policy.isElevatedTool(name: "dangerous_tool"))
        var agentProfile = try await ModeRegistryTestSupport.makeService(seedingBuiltIns: true).resolve(modeId: InteractionMode.agent.rawValue)
        agentProfile.tools = ModeProfileToolsSlice(allow: ["*"], deny: ["blocked_build"], approvalPolicy: nil)
        let agentContext = ModePolicyContext(interactionMode: .agent, resolvedProfile: agentProfile)
        #expect(policy.isToolDenied(name: "blocked_build", context: agentContext))
    }

    @Test("execution environment policy metadata is exposed")
    func executionEnvironmentPolicyMetadata() {
        let policy = ToolPolicyConfiguration(
            executionEnvironmentPolicy: .init(
                disallowed: [.unknown],
                approvalRequired: [.mcp],
                escalationRequired: [.a2a],
                disallowedAdapterIDs: ["tool-env.local.restricted"],
                approvalRequiredAdapterIDs: ["tool-env.mcp.review"],
                escalationRequiredAdapterIDs: ["tool-env.a2a.remote"]
            )
        )
        #expect(policy.isExecutionEnvironmentAllowed(kind: .local))
        #expect(policy.isExecutionEnvironmentAllowed(kind: .unknown) == false)
        #expect(policy.requiresExecutionEnvironmentApproval(kind: .mcp))
        #expect(policy.requiresExecutionEnvironmentEscalation(kind: .a2a))
        #expect(policy.isExecutionEnvironmentAdapterAllowed(adapterID: "tool-env.local.restricted") == false)
        #expect(policy.requiresExecutionEnvironmentAdapterApproval(adapterID: "tool-env.mcp.review"))
        #expect(policy.requiresExecutionEnvironmentAdapterEscalation(adapterID: "tool-env.a2a.remote"))
    }

    @Test("dispatch parser normalizes planner mode casing and trims whitespace")
    func dispatchParserNormalizesPlannerMode() {
        let parsed = ToolPolicyConfiguration.parseDispatchPolicyBlock([
            "parallelEnabled": true,
            "plannerMode": "  mixeddeterministic  ",
            "pendingToolTimeoutSeconds": 12,
        ])
        #expect(parsed.parallelDispatchEnabled == true)
        #expect(parsed.dispatchPlannerMode == .mixedDeterministic)
        #expect(parsed.pendingToolTimeoutSeconds == 12)
    }

    @Test("dispatch parser rejects malformed planner and non-positive timeout")
    func dispatchParserRejectsMalformedValues() {
        let parsed = ToolPolicyConfiguration.parseDispatchPolicyBlock([
            "parallelEnabled": true,
            "plannerMode": "deterministic-mixed",
            "pendingToolTimeoutSeconds": 0,
        ])
        #expect(parsed.parallelDispatchEnabled == true)
        #expect(parsed.dispatchPlannerMode == nil)
        #expect(parsed.pendingToolTimeoutSeconds == nil)
    }

    @Test("dispatch parser defaults when dispatch block is absent")
    func dispatchParserDefaults() {
        let parsed = ToolPolicyConfiguration.parseDispatchPolicyBlock(nil)
        #expect(parsed.parallelDispatchEnabled == false)
        #expect(parsed.dispatchPlannerMode == nil)
        #expect(parsed.pendingToolTimeoutSeconds == nil)
    }

    @Test("stable allowlist signature changes when planner mode changes")
    func stableSignatureTracksPlannerMode() {
        let serial = ToolPolicyConfiguration(
            parallelDispatchEnabled: true,
            dispatchPlannerMode: .serial
        )
        let mixed = ToolPolicyConfiguration(
            parallelDispatchEnabled: true,
            dispatchPlannerMode: .mixedDeterministic
        )
        #expect(serial.stableAllowlistSignature() != mixed.stableAllowlistSignature())
    }

    @Test("mode tools approval policy all requires approval")
    func modeToolsApprovalPolicyAll() async throws {
        let policy = ToolPolicyConfiguration.unrestricted
        var profile = try await ModeRegistryTestSupport.makeService(seedingBuiltIns: true).resolve(modeId: InteractionMode.chat.rawValue)
        profile.tools = ModeProfileToolsSlice(allow: ["*"], deny: [], approvalPolicy: .all)
        let context = ModePolicyContext(interactionMode: .chat, resolvedProfile: profile)

        let requires = policy.requiresApproval(
            toolName: "read_file",
            context: context,
            toolIsReadOnly: true,
            entryRequiresApprovalTag: false
        )
        #expect(requires)
    }

    @Test("mode tools approval policy sideEffects only flags non-readonly")
    func modeToolsApprovalPolicySideEffects() async throws {
        let policy = ToolPolicyConfiguration.unrestricted
        var profile = try await ModeRegistryTestSupport.makeService(seedingBuiltIns: true).resolve(modeId: InteractionMode.chat.rawValue)
        profile.tools = ModeProfileToolsSlice(allow: ["*"], deny: [], approvalPolicy: .sideEffects)
        let context = ModePolicyContext(interactionMode: .chat, resolvedProfile: profile)

        let readonly = policy.requiresApproval(
            toolName: "get_plan",
            context: context,
            toolIsReadOnly: true,
            entryRequiresApprovalTag: false
        )
        let mutating = policy.requiresApproval(
            toolName: "edit_file",
            context: context,
            toolIsReadOnly: false,
            entryRequiresApprovalTag: false
        )
        #expect(readonly == false)
        #expect(mutating)
    }
}
