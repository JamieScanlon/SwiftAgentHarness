import EasyJSON
import Foundation
import Logging
import SwiftAgentKit

/// Termination-focused tools for terminal-tool runtime policies.
public struct TerminationToolProvider: ToolProvider, ToolDescriptorHinting {
    public static let finishToolName = "finish"
    public static let askUserToolName = "ask_user"
    public static let thinkToolName = "think"

    private let dataProvider: ConversationsDataProviding
    private let logger: Logger?

    public var name: String { "Termination" }
    public var descriptorHintsByToolName: [String: ToolDescriptorHints] {
        [
            Self.finishToolName: ToolDescriptorHints(effectClass: .readOnly, parallelHint: .serialOnly),
            Self.askUserToolName: ToolDescriptorHints(effectClass: .readOnly, parallelHint: .serialOnly),
            Self.thinkToolName: ToolDescriptorHints(effectClass: .readOnly, parallelHint: .serialOnly),
        ]
    }

    public init(dataProvider: ConversationsDataProviding, logger: Logger? = nil) {
        self.dataProvider = dataProvider
        self.logger = logger ?? SwiftAgentKitLogging.logger(
            for: .custom(subsystem: "SwiftAgentHarness", component: "TerminationToolProvider")
        )
    }

    public func availableTools() async -> [ToolDefinition] {
        [
            ToolDefinition(
                name: Self.finishToolName,
                description: "Signal that autonomous work for this turn is complete and terminate the terminal-tool loop.",
                parameters: [
                    .init(name: "conversation_id", description: "Conversation UUID", type: "string", required: true),
                    .init(name: "summary", description: "Optional completion summary.", type: "string", required: false),
                ],
                type: .function
            ),
            ToolDefinition(
                name: Self.askUserToolName,
                description: "Escalate to the user with a structured question and options, then terminate the terminal-tool loop.",
                parameters: [
                    .init(name: "conversation_id", description: "Conversation UUID", type: "string", required: true),
                    .init(name: "question", description: "Question shown to the user.", type: "string", required: true),
                    .init(
                        name: "options",
                        description: "JSON array string: [{\"id\":\"opt_id\",\"label\":\"Option label\"}, ...] (min 2 options).",
                        type: "string",
                        required: true
                    ),
                    .init(name: "allow_multiple", description: "Optional boolean; default false.", type: "boolean", required: false),
                    .init(name: "default_option_id", description: "Optional default option id.", type: "string", required: false),
                ],
                type: .function
            ),
            ToolDefinition(
                name: Self.thinkToolName,
                description: "Record an optional thinking snapshot and continue the loop without terminating.",
                parameters: [
                    .init(name: "conversation_id", description: "Conversation UUID", type: "string", required: true),
                    .init(name: "snapshot", description: "Optional short reasoning snapshot.", type: "string", required: false),
                ],
                type: .function
            ),
        ]
    }

    public func policyTags(for definition: ToolDefinition) async -> [ToolPolicyTag] {
        guard definition.name == Self.askUserToolName else { return [] }
        return [ToolRegistryResultFormattingPolicy.exactContentObservationPolicyTag()]
    }

    public func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
        switch toolCall.name {
        case Self.finishToolName:
            return try await executeFinish(toolCall)
        case Self.askUserToolName:
            return try await executeAskUser(toolCall)
        case Self.thinkToolName:
            return try await executeThink(toolCall)
        default:
            throw Error.unknownTool(toolCall.name)
        }
    }

    private func executeFinish(_ toolCall: ToolCall) async throws -> ToolResult {
        let (conversationID, conversationIDString) = try parseConversationID(toolCall)
        guard await dataProvider.getConversation(id: conversationID) != nil else {
            return toolError(toolCall, "Conversation not found: \(conversationIDString)")
        }
        let summary = extractString(from: toolCall.arguments, key: "summary")?.trimmingCharacters(in: .whitespacesAndNewlines)
        logger?.info(
            "finish requested",
            metadata: SwiftAgentKitLogging.metadata(
                ("conversationId", .string(conversationIDString)),
                ("toolCallId", .string(toolCall.id ?? "nil"))
            )
        )
        return ToolResult(
            success: true,
            content: (summary?.isEmpty == false)
                ? "Finished: \(summary!)"
                : "Finished.",
            metadata: .object([
                "source": .string("termination_tool"),
                "action": .string(Self.finishToolName),
                "conversationId": .string(conversationIDString),
                "summary": .string(summary ?? ""),
            ]),
            toolCallId: toolCall.id
        )
    }

    private func executeAskUser(_ toolCall: ToolCall) async throws -> ToolResult {
        let (conversationID, conversationIDString) = try parseConversationID(toolCall)
        guard await dataProvider.getConversation(id: conversationID) != nil else {
            return toolError(toolCall, "Conversation not found: \(conversationIDString)")
        }
        guard let question = extractString(from: toolCall.arguments, key: "question")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !question.isEmpty
        else {
            throw Error.missingParameter("question")
        }
        guard let optionsRaw = extractString(from: toolCall.arguments, key: "options"),
              let optionsData = optionsRaw.data(using: .utf8)
        else {
            throw Error.missingParameter("options")
        }
        let options: [AskUserOptionPayload]
        do {
            options = try JSONDecoder().decode([AskUserOptionPayload].self, from: optionsData)
        } catch {
            return toolError(toolCall, "Invalid options JSON: \(error.localizedDescription)")
        }
        guard options.count >= 2 else {
            return toolError(toolCall, "ask_user requires at least two options.")
        }
        let normalizedOptions = options.map { opt in
            AskUserOptionPayload(
                id: opt.id.trimmingCharacters(in: .whitespacesAndNewlines),
                label: opt.label.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard normalizedOptions.allSatisfy({ !$0.id.isEmpty && !$0.label.isEmpty }) else {
            return toolError(toolCall, "ask_user options must include non-empty id and label.")
        }
        let uniqueIDs = Set(normalizedOptions.map(\.id))
        guard uniqueIDs.count == normalizedOptions.count else {
            return toolError(toolCall, "ask_user option ids must be unique.")
        }

        let allowMultiple = extractBool(from: toolCall.arguments, key: "allow_multiple") ?? false
        let defaultOptionID = extractString(from: toolCall.arguments, key: "default_option_id")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let defaultOptionID,
           !defaultOptionID.isEmpty,
           !uniqueIDs.contains(defaultOptionID) {
            return toolError(toolCall, "default_option_id must match one of the option ids.")
        }

        let payload = AskUserPromptPayload(
            question: question,
            options: normalizedOptions,
            allowMultiple: allowMultiple,
            defaultOptionID: defaultOptionID?.isEmpty == true ? nil : defaultOptionID
        )
        logger?.info(
            "ask_user requested",
            metadata: SwiftAgentKitLogging.metadata(
                ("conversationId", .string(conversationIDString)),
                ("toolCallId", .string(toolCall.id ?? "nil")),
                ("optionCount", .stringConvertible(payload.options.count))
            )
        )
        let optionsMetadata: [JSON] = payload.options.map { option in
            JSON.object([
                "id": JSON.string(option.id),
                "label": JSON.string(option.label),
            ])
        }
        var askUserMetadata: [String: JSON] = [
            "question": .string(payload.question),
            "options": .array(optionsMetadata),
            "allowMultiple": .boolean(payload.allowMultiple),
        ]
        if let defaultOptionID = payload.defaultOptionID {
            askUserMetadata["defaultOptionId"] = .string(defaultOptionID)
        }
        return ToolResult(
            success: true,
            content: payload.question,
            metadata: .object([
                "source": .string("termination_tool"),
                "action": .string(Self.askUserToolName),
                "conversationId": .string(conversationIDString),
                "askUser": .object(askUserMetadata),
            ]),
            toolCallId: toolCall.id
        )
    }

    private func executeThink(_ toolCall: ToolCall) async throws -> ToolResult {
        let (conversationID, conversationIDString) = try parseConversationID(toolCall)
        guard await dataProvider.getConversation(id: conversationID) != nil else {
            return toolError(toolCall, "Conversation not found: \(conversationIDString)")
        }
        let snapshot = extractString(from: toolCall.arguments, key: "snapshot")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        logger?.info(
            "think requested",
            metadata: SwiftAgentKitLogging.metadata(
                ("conversationId", .string(conversationIDString)),
                ("toolCallId", .string(toolCall.id ?? "nil")),
                ("hasSnapshot", .stringConvertible((snapshot?.isEmpty == false)))
            )
        )
        var metadata: [String: JSON] = [
            "source": .string("termination_tool"),
            "action": .string(Self.thinkToolName),
            "conversationId": .string(conversationIDString),
            "hasSnapshot": .boolean(snapshot?.isEmpty == false),
        ]
        if let snapshot, !snapshot.isEmpty {
            metadata["snapshot"] = .string(snapshot)
        }
        return ToolResult(
            success: true,
            content: "Thinking checkpoint recorded.",
            metadata: .object(metadata),
            toolCallId: toolCall.id
        )
    }

    private func parseConversationID(_ toolCall: ToolCall) throws -> (UUID, String) {
        guard let conversationIDString = extractString(from: toolCall.arguments, key: "conversation_id") else {
            throw Error.missingParameter("conversation_id")
        }
        guard let conversationID = UUID(uuidString: conversationIDString) else {
            throw Error.invalidParameter("conversation_id")
        }
        return (conversationID, conversationIDString)
    }

    private func extractString(from arguments: JSON, key: String) -> String? {
        guard case .object(let dict) = arguments,
              let value = dict[key],
              case .string(let text) = value
        else {
            return nil
        }
        return text
    }

    private func extractBool(from arguments: JSON, key: String) -> Bool? {
        guard case .object(let dict) = arguments,
              let value = dict[key],
              case .boolean(let flag) = value
        else {
            return nil
        }
        return flag
    }

    private func toolError(_ toolCall: ToolCall, _ message: String) -> ToolResult {
        ToolResult(
            success: false,
            content: "",
            metadata: .object(["source": .string("termination_tool")]),
            toolCallId: toolCall.id,
            error: message
        )
    }
}

extension TerminationToolProvider {
    enum Error: Swift.Error, Sendable {
        case unknownTool(String)
        case missingParameter(String)
        case invalidParameter(String)
    }
}
