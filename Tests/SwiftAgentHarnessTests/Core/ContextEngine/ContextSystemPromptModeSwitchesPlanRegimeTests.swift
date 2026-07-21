import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ContextSystemPromptModeSwitches plan regime")
struct ContextSystemPromptModeSwitchesPlanRegimeTests {
    private func planConversation(id: UUID = UUID()) -> ModelConversation {
        ModelConversation(
            id: id,
            model: Model(
                protocol: .openAIAPI,
                modelName: "plan-regime-test",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            systemPrompt: "plan",
            interactionMode: .plan,
            modeProfileID: InteractionMode.plan.rawValue
        )
    }

    @Test("first-entry plan directive asks for exit_plan_mode approval and omits re-entry copy")
    func firstEntryPlanDirective() throws {
        let id = UUID()
        defer { _ = AgentPlanStore.removeConversationDirectory(for: id) }
        _ = AgentPlanStore.removeConversationDirectory(for: id)

        let profile = ResolvedModeProfile.builtIn(for: .plan)
        let switches = ContextSystemPromptModeSwitches.build(
            conversation: planConversation(id: id),
            strictAgentHarnessPrompts: true,
            resolvedProfile: profile
        )
        let block = switches.assemblyContext.workflowBlock
        #expect(block.contains("exit_plan_mode"))
        #expect(block.contains("approval request") || block.contains("*is* the plan approval"))
        #expect(!block.contains("Do **not** call **exit_plan_mode**"))
        #expect(!block.contains("Re-entry — existing plan.md"))
        #expect(block.contains("DO NOT start execution"))
    }

    @Test("re-entry plan directive surfaces existing plan and requires edit before exit")
    func reEntryPlanDirective() throws {
        let id = UUID()
        defer { _ = AgentPlanStore.removeConversationDirectory(for: id) }
        try AgentPlanStore.ensureConversationDirectory(for: id)
        let url = AgentPlanStore.planURL(for: id)
        try "# Plan\n\n- [ ] id:\(UUID().uuidString) - existing task\n".write(to: url, atomically: true, encoding: .utf8)

        let profile = ResolvedModeProfile.builtIn(for: .plan)
        let switches = ContextSystemPromptModeSwitches.build(
            conversation: planConversation(id: id),
            strictAgentHarnessPrompts: true,
            resolvedProfile: profile
        )
        let block = switches.assemblyContext.workflowBlock
        #expect(block.contains("Re-entry — existing plan.md"))
        #expect(block.contains("edit the artifact before calling exit_plan_mode"))
        #expect(block.contains(AgentPlanStore.planPathString(for: id)))
        #expect(block.contains("exit_plan_mode"))
    }
}
