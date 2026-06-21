import EasyJSON
import Foundation
import SwiftAgentKit
import SwiftAgentKitSkills

/// After successful skill activation/deactivation tools, persists `SkillLoader` state into the current conversation metadata.
struct PersistingActivatedSkillsToolProvider: ToolProvider {
    let inner: any ToolProvider
    let onActivationStateChanged: @Sendable () async -> Void

    var name: String { inner.name }

    func availableTools() async -> [ToolDefinition] {
        await inner.availableTools()
    }

    func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
        let result = try await inner.executeTool(toolCall)
        if result.success {
            switch toolCall.name {
            case SkillsToolProvider.activateToolName, SkillsToolProvider.deactivateToolName:
                await onActivationStateChanged()
            default:
                break
            }
        }
        return result
    }

    func executeToolOutcome(_ toolCall: ToolCall) async throws -> ToolExecutionOutcome {
        let outcome = try await inner.executeToolOutcome(toolCall)
        if case .completed(let result) = outcome, result.success {
            switch toolCall.name {
            case SkillsToolProvider.activateToolName, SkillsToolProvider.deactivateToolName:
                await onActivationStateChanged()
            default:
                break
            }
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
}
