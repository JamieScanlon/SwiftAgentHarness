import EasyJSON
import Foundation
import SwiftAgentKit
import SwiftAgentKitSkills

/// Wraps ``SkillsToolProvider`` and blocks `agent-skill-activate` when the skill is not allowed for the current conversation.
struct SkillPolicySkillsToolProvider: ToolProvider {
    let inner: SkillsToolProvider
    let canActivateSkill: @Sendable (String) async -> Bool

    var name: String { inner.name }

    func availableTools() async -> [ToolDefinition] {
        await inner.availableTools()
    }

    func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
        if toolCall.name == SkillsToolProvider.activateToolName {
            guard let skillName = extractSkillName(from: toolCall.arguments) else {
                return ToolResult(
                    success: false,
                    content: "Missing skill_name parameter.",
                    metadata: .object(["source": .string("skills_tool")]),
                    toolCallId: toolCall.id
                )
            }
            if !(await canActivateSkill(skillName)) {
                return ToolResult(
                    success: false,
                    content: "Skill '\(skillName)' is not available for this conversation (policy or user settings).",
                    metadata: .object([
                        "source": .string("skills_tool"),
                        "skill_name": .string(skillName),
                        "action": .string("denied"),
                    ]),
                    toolCallId: toolCall.id
                )
            }
        }
        let result = try await inner.executeTool(toolCall)
        if toolCall.name == SkillsToolProvider.activateToolName, result.success,
           let skillName = extractSkillName(from: toolCall.arguments) {
            return ToolResult(
                success: result.success,
                content: SkillActivationBodyFormatter.formattedActivateResult(
                    name: skillName,
                    fullInstructions: result.content
                ),
                metadata: result.metadata,
                toolCallId: result.toolCallId
            )
        }
        return result
    }

    func executeToolOutcome(_ toolCall: ToolCall) async throws -> ToolExecutionOutcome {
        if toolCall.name == SkillsToolProvider.activateToolName {
            guard let skillName = extractSkillName(from: toolCall.arguments) else {
                return .completed(ToolResult(
                    success: false,
                    content: "Missing skill_name parameter.",
                    metadata: .object(["source": .string("skills_tool")]),
                    toolCallId: toolCall.id
                ))
            }
            if !(await canActivateSkill(skillName)) {
                return .completed(ToolResult(
                    success: false,
                    content: "Skill '\(skillName)' is not available for this conversation (policy or user settings).",
                    metadata: .object([
                        "source": .string("skills_tool"),
                        "skill_name": .string(skillName),
                        "action": .string("denied"),
                    ]),
                    toolCallId: toolCall.id
                ))
            }
        }
        let outcome = try await inner.executeToolOutcome(toolCall)
        if toolCall.name == SkillsToolProvider.activateToolName,
           case .completed(let result) = outcome, result.success,
           let skillName = extractSkillName(from: toolCall.arguments) {
            return .completed(ToolResult(
                success: result.success,
                content: SkillActivationBodyFormatter.formattedActivateResult(
                    name: skillName,
                    fullInstructions: result.content
                ),
                metadata: result.metadata,
                toolCallId: result.toolCallId
            ))
        }
        return outcome
    }

    func cancelPending(handleID: String, toolCallID: String) async -> Bool {
        await inner.cancelPending(handleID: handleID, toolCallID: toolCallID)
    }

    func parallelSafety(for toolCall: ToolCall) async -> ToolParallelSafety {
        await inner.parallelSafety(for: toolCall)
    }

    func registrationSource(for definition: ToolDefinition) async -> ToolRegistrationSource {
        await inner.registrationSource(for: definition)
    }

    func effectClass(for definition: ToolDefinition) async -> ToolEffectClass {
        await inner.effectClass(for: definition)
    }

    func executionParallelHint(for definition: ToolDefinition) async -> ToolExecutionParallelHint {
        await inner.executionParallelHint(for: definition)
    }

    func policyTags(for definition: ToolDefinition) async -> [ToolPolicyTag] {
        await inner.policyTags(for: definition)
    }

    func rawSchema(for definition: ToolDefinition) async -> JSON? {
        await inner.rawSchema(for: definition)
    }

    private func extractSkillName(from arguments: JSON) -> String? {
        guard case .object(let dict) = arguments,
              let value = dict["skill_name"] else {
            return nil
        }
        if case .string(let s) = value { return s }
        return nil
    }
}
