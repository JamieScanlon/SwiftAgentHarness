import EasyJSON
import Foundation
import Logging
import SwiftAgentKit

public enum ModeTransitionApplyResult: Sendable, Equatable {
    case applied
    case deferredUntilRunCompletes
}

public protocol ModeTransitionDataProviding: Sendable {
    func getConversation(id: UUID) async -> ModelConversation?
    func transitionConversationMode(
        conversationID: UUID,
        targetMode: InteractionMode,
        initiatedBy: String,
        reason: String?
    ) async throws -> ModeTransitionApplyResult
}

public struct ModeTransitionToolProvider: ToolProvider, ToolDescriptorHinting {
    public static let enterPlanModeToolName = "enter_plan_mode"
    public static let exitPlanModeToolName = "exit_plan_mode"

    private let dataProvider: ModeTransitionDataProviding
    private let resolveConversationID: @Sendable () async -> UUID?
    private let logger: Logger?

    public var name: String { "ModeTransition" }
    public var descriptorHintsByToolName: [String: ToolDescriptorHints] {
        [
            Self.enterPlanModeToolName: ToolDescriptorHints(effectClass: .mutating, parallelHint: .serialOnly),
            Self.exitPlanModeToolName: ToolDescriptorHints(effectClass: .mutating, parallelHint: .serialOnly),
        ]
    }

    public init(
        dataProvider: ModeTransitionDataProviding,
        resolveConversationID: @escaping @Sendable () async -> UUID? = {
            ConversationScope.resolvedConversationID()
        },
        logger: Logger? = nil
    ) {
        self.dataProvider = dataProvider
        self.resolveConversationID = resolveConversationID
        self.logger = logger ?? SwiftAgentKitLogging.logger(
            for: .custom(subsystem: "SwiftAgentHarness", component: "ModeTransitionToolProvider")
        )
    }

    public func availableTools() async -> [ToolDefinition] {
        [
            ToolDefinition(
                name: Self.enterPlanModeToolName,
                description: "Request user consent to enter plan mode for the active conversation. Calling this tool is the approval request; do not ask in free text. Mode transitions the user initiates in the app do not need this tool.",
                parameters: [],
                type: .function
            ),
            ToolDefinition(
                name: Self.exitPlanModeToolName,
                description: "Request approval to exit plan mode and begin implementation (default target: agent). Calling this tool IS the plan approval request — do NOT ask about plan approval via text or ask_user; use ask_user only for requirement clarification. Optional target_mode can be `agent` or `chat`.",
                parameters: [
                    .init(name: "target_mode", description: "Optional mode to transition to: `agent` or `chat`.", type: "string", required: false),
                ],
                type: .function
            ),
        ]
    }

    public func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
        switch toolCall.name {
        case Self.enterPlanModeToolName:
            return try await executeEnterPlanMode(toolCall)
        case Self.exitPlanModeToolName:
            return try await executeExitPlanMode(toolCall)
        default:
            throw Error.unknownTool(toolCall.name)
        }
    }

    private func executeEnterPlanMode(_ toolCall: ToolCall) async throws -> ToolResult {
        guard let conversationID = await resolveConversationID() else {
            return toolError(toolCall, "No active conversation")
        }
        let conversationIDString = conversationID.uuidString
        guard let conversation = await dataProvider.getConversation(id: conversationID) else {
            return toolError(toolCall, "Conversation not found: \(conversationIDString)")
        }
        if conversation.interactionMode == .plan {
            return ToolResult(
                success: true,
                content: "Conversation is already in plan mode.",
                metadata: .object(["source": .string("mode_transition_tool"), "action": .string(Self.enterPlanModeToolName)]),
                toolCallId: toolCall.id
            )
        }
        do {
            let outcome = try await dataProvider.transitionConversationMode(
                conversationID: conversationID,
                targetMode: .plan,
                initiatedBy: "tool",
                reason: Self.enterPlanModeToolName
            )
            logger?.info("enter_plan_mode transitioned conversation \(conversationIDString) -> plan")
            let content = outcome == .deferredUntilRunCompletes
                ? "Mode transition scheduled; will apply when the current run completes."
                : "Conversation transitioned to plan mode."
            return ToolResult(
                success: true,
                content: content,
                metadata: .object(["source": .string("mode_transition_tool"), "action": .string(Self.enterPlanModeToolName)]),
                toolCallId: toolCall.id
            )
        } catch {
            return toolError(toolCall, "Failed to enter plan mode: \(error)")
        }
    }

    private func executeExitPlanMode(_ toolCall: ToolCall) async throws -> ToolResult {
        guard let conversationID = await resolveConversationID() else {
            return toolError(toolCall, "No active conversation")
        }
        let conversationIDString = conversationID.uuidString
        guard await dataProvider.getConversation(id: conversationID) != nil else {
            return toolError(toolCall, "Conversation not found: \(conversationIDString)")
        }
        let targetMode: InteractionMode
        if let targetRaw = extractString(from: toolCall.arguments, key: "target_mode") {
            switch targetRaw.lowercased() {
            case "agent":
                targetMode = .agent
            case "chat":
                targetMode = .chat
            default:
                return toolError(toolCall, "target_mode must be `agent` or `chat`")
            }
        } else {
            targetMode = .agent
        }
        do {
            let outcome = try await dataProvider.transitionConversationMode(
                conversationID: conversationID,
                targetMode: targetMode,
                initiatedBy: "tool",
                reason: Self.exitPlanModeToolName
            )
            logger?.info("exit_plan_mode transitioned conversation \(conversationIDString) -> \(targetMode.rawValue)")
            let content = outcome == .deferredUntilRunCompletes
                ? "Mode transition scheduled; will apply when the current run completes."
                : "Conversation transitioned to \(targetMode.rawValue) mode."
            return ToolResult(
                success: true,
                content: content,
                metadata: .object(["source": .string("mode_transition_tool"), "action": .string(Self.exitPlanModeToolName)]),
                toolCallId: toolCall.id
            )
        } catch {
            return toolError(toolCall, "Failed to exit plan mode: \(error)")
        }
    }

    private func extractString(from arguments: JSON, key: String) -> String? {
        guard case .object(let dict) = arguments,
              let value = dict[key],
              case .string(let text) = value else {
            return nil
        }
        return text
    }

    private func toolError(_ toolCall: ToolCall, _ message: String) -> ToolResult {
        ToolResult(
            success: false,
            content: "",
            metadata: .object(["source": .string("mode_transition_tool")]),
            toolCallId: toolCall.id,
            error: message
        )
    }
}

extension ModeTransitionToolProvider {
    enum Error: Swift.Error, Sendable {
        case unknownTool(String)
    }
}
