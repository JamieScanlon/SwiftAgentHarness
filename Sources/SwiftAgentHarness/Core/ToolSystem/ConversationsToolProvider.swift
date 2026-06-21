//
//  Local function provider for list_conversations and get_conversation.
//  Exposes conversation metadata and paginated conversation messages to the agent.
//

import EasyJSON
import Foundation
import Logging
import SwiftAgentKit

/// Metadata for a conversation (no messages) - used by list_conversations
public struct ConversationMetadata: Codable, Sendable {
    public let id: String
    public let modelName: String
    public let topic: String?
    public let description: String?
    public let messageCount: Int
    public let createdAt: String
    public let updatedAt: String
    public let lifecycle: ConversationLifecycleState?
    public let tags: [String]
    public let controlPlaneRevision: UInt64
    /// Multi-tenant owner (mirrors ``ModelConversation/ownerAccountID``); omitted when unset.
    public let ownerAccountID: UUID?
    /// Mirrors ``ModelConversation/interactionMode`` for catalog subscribers (`conversations/registry`).
    public let interactionMode: InteractionMode?
    /// Stable mode profile pointer (mirrors ``ModelConversation/modeProfileID``).
    public let modeProfileID: String?
    /// Parent conversation for branch / sub-agent trees (mirrors ``ModelConversation/parentConversationID``).
    public let parentConversationID: UUID?
    public let lineageKind: ConversationLineageKind?
    public let origin: ConversationOrigin?
    public let catalogSection: ConversationCatalogSection?

    public init(
        id: String,
        modelName: String,
        topic: String?,
        description: String?,
        messageCount: Int,
        createdAt: String,
        updatedAt: String,
        lifecycle: ConversationLifecycleState? = nil,
        tags: [String] = [],
        controlPlaneRevision: UInt64 = 0,
        ownerAccountID: UUID? = nil,
        interactionMode: InteractionMode? = nil,
        modeProfileID: String? = nil,
        parentConversationID: UUID? = nil,
        lineageKind: ConversationLineageKind? = nil,
        origin: ConversationOrigin? = nil,
        catalogSection: ConversationCatalogSection? = nil
    ) {
        self.id = id
        self.modelName = modelName
        self.topic = topic
        self.description = description
        self.messageCount = messageCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lifecycle = lifecycle
        self.tags = tags
        self.controlPlaneRevision = controlPlaneRevision
        self.ownerAccountID = ownerAccountID
        self.interactionMode = interactionMode
        self.modeProfileID = modeProfileID
        self.parentConversationID = parentConversationID
        self.lineageKind = lineageKind
        self.origin = origin
        self.catalogSection = catalogSection
    }

    private enum CodingKeys: String, CodingKey {
        case id, modelName, topic, description, messageCount, createdAt, updatedAt, lifecycle, tags, controlPlaneRevision, ownerAccountID
        case interactionMode, modeProfileID, parentConversationID, lineageKind, origin, catalogSection
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        modelName = try c.decode(String.self, forKey: .modelName)
        topic = try c.decodeIfPresent(String.self, forKey: .topic)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        messageCount = try c.decode(Int.self, forKey: .messageCount)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        lifecycle = try c.decodeIfPresent(ConversationLifecycleState.self, forKey: .lifecycle)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        controlPlaneRevision = try c.decodeIfPresent(UInt64.self, forKey: .controlPlaneRevision) ?? 0
        ownerAccountID = try c.decodeIfPresent(UUID.self, forKey: .ownerAccountID)
        interactionMode = try c.decodeIfPresent(InteractionMode.self, forKey: .interactionMode)
        modeProfileID = try c.decodeIfPresent(String.self, forKey: .modeProfileID)
        parentConversationID = try c.decodeIfPresent(UUID.self, forKey: .parentConversationID)
        lineageKind = try c.decodeIfPresent(ConversationLineageKind.self, forKey: .lineageKind)
        origin = try c.decodeIfPresent(ConversationOrigin.self, forKey: .origin)
        catalogSection = try c.decodeIfPresent(ConversationCatalogSection.self, forKey: .catalogSection)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(modelName, forKey: .modelName)
        try c.encodeIfPresent(topic, forKey: .topic)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(messageCount, forKey: .messageCount)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(lifecycle, forKey: .lifecycle)
        if !tags.isEmpty {
            try c.encode(tags, forKey: .tags)
        }
        try c.encode(controlPlaneRevision, forKey: .controlPlaneRevision)
        try c.encodeIfPresent(ownerAccountID, forKey: .ownerAccountID)
        try c.encodeIfPresent(interactionMode, forKey: .interactionMode)
        try c.encodeIfPresent(modeProfileID, forKey: .modeProfileID)
        try c.encodeIfPresent(parentConversationID, forKey: .parentConversationID)
        try c.encodeIfPresent(lineageKind, forKey: .lineageKind)
        try c.encodeIfPresent(origin, forKey: .origin)
        try c.encodeIfPresent(catalogSection, forKey: .catalogSection)
    }
}

/// Protocol for providing conversation data to the tool provider.
/// Allows the provider to work with any runtime session data implementation.
public protocol ConversationsDataProviding: Sendable {
    func listConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata]
    func getConversation(id: UUID) async -> ModelConversation?
    /// Selects the conversation by ID. If message is provided, appends it and sends to the LLM.
    /// - Returns: The LLM response text if message was sent, nil otherwise.
    func switchConversation(id: UUID, message: String?) async throws -> String?
}

/// Tool provider that exposes local functions for listing and retrieving conversations.
/// Use when the agent needs to browse or inspect conversation history.
public struct ConversationsToolProvider: ToolProvider, ToolDescriptorHinting {

    public static let listConversationsToolName = "list_conversations"
    public static let getConversationToolName = "get_conversation"
    public static let switchConversationToolName = "switch_conversation"

    private static let getConversationDefaultLimit = 25
    private static let getConversationMaxMessageLimit = 25

    private let dataProvider: ConversationsDataProviding
    private let logger: Logger?

    public var name: String { "Conversations" }
    public var descriptorHintsByToolName: [String: ToolDescriptorHints] {
        [
            Self.listConversationsToolName: ToolDescriptorHints(effectClass: .readOnly, parallelHint: .parallelizable),
            Self.getConversationToolName: ToolDescriptorHints(effectClass: .readOnly, parallelHint: .parallelizable),
            Self.switchConversationToolName: ToolDescriptorHints(effectClass: .mutating, parallelHint: .serialOnly),
        ]
    }

    public init(dataProvider: ConversationsDataProviding, logger: Logger? = nil) {
        self.dataProvider = dataProvider
        self.logger = logger ?? SwiftAgentKitLogging.logger(
            for: .custom(subsystem: "SwiftAgentHarness", component: "ConversationsToolProvider")
        )
    }

    public func availableTools() async -> [ToolDefinition] {
        let isSubAgent = ConversationScope.current?.isSubAgent == true
        var tools: [ToolDefinition] = [
            ToolDefinition(
                name: Self.listConversationsToolName,
                description: "List user-facing conversations. Returns metadata only (id, model, topic, description, message count, dates) - does not include message content.",
                parameters: [],
                type: .function
            ),
            ToolDefinition(
                name: Self.getConversationToolName,
                description: "Get a single conversation by ID with a page of messages (max 25 per call). Use the id from list_conversations. Optional start_index (0-based, default 0) and limit (default 25, max 25) paginate through message history; the response always includes totalMessageCount for the full thread.",
                parameters: [
                    .init(name: "id", description: "The conversation UUID (from list_conversations)", type: "string", required: true),
                    .init(
                        name: "start_index",
                        description: "0-based index of the first message to return (default 0).",
                        type: "integer",
                        required: false
                    ),
                    .init(
                        name: "limit",
                        description: "Maximum number of messages to return (default 25; maximum 25).",
                        type: "integer",
                        required: false
                    ),
                ],
                type: .function
            ),
        ]
        if !isSubAgent {
            tools.append(
                ToolDefinition(
                    name: Self.switchConversationToolName,
                    description: "Switch to a conversation by ID, making it the current conversation. If message is provided, appends it to the thread and sends it to the LLM (returns immediately without waiting for the response). Use to change context or continue a different conversation.",
                    parameters: [
                        .init(name: "id", description: "The conversation UUID to switch to", type: "string", required: true),
                        .init(name: "message", description: "Optional message to append and send to the LLM. If omitted, only switches the current conversation.", type: "string", required: false)
                    ],
                    type: .function
                )
            )
        }
        return tools
    }

    public func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
        guard [Self.listConversationsToolName, Self.getConversationToolName, Self.switchConversationToolName].contains(toolCall.name) else {
            throw Error.unknownTool(toolCall.name)
        }

        switch toolCall.name {
        case Self.listConversationsToolName:
            return await executeListConversations(toolCall)
        case Self.getConversationToolName:
            return try await executeGetConversation(toolCall)
        case Self.switchConversationToolName:
            return try await executeSwitchConversation(toolCall)
        default:
            throw Error.unknownTool(toolCall.name)
        }
    }

    private func executeListConversations(_ toolCall: ToolCall) async -> ToolResult {
        let metadata = await dataProvider.listConversationMetadata(visibility: .primaryOnly)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]

        do {
            let data = try encoder.encode(metadata)
            guard let content = String(data: data, encoding: .utf8) else {
                return ToolResult(
                    success: false,
                    content: "",
                    metadata: .object(["source": .string("conversations_tool")]),
                    toolCallId: toolCall.id,
                    error: "Failed to encode conversation list"
                )
            }

            logger?.info(
                "list_conversations executed",
                metadata: SwiftAgentKitLogging.metadata(
                    ("count", .stringConvertible(metadata.count)),
                    ("toolCallId", .string(toolCall.id ?? "nil"))
                )
            )

            return ToolResult(
                success: true,
                content: content,
                metadata: .object([
                    "source": .string("conversations_tool"),
                    "action": .string("list"),
                    "count": .integer(metadata.count)
                ]),
                toolCallId: toolCall.id
            )
        } catch {
            logger?.error("Failed to encode conversation list: \(error)")
            return ToolResult(
                success: false,
                content: "",
                metadata: .object(["source": .string("conversations_tool")]),
                toolCallId: toolCall.id,
                error: "\(error)"
            )
        }
    }

    private func executeGetConversation(_ toolCall: ToolCall) async throws -> ToolResult {
        guard let idString = extractString(from: toolCall.arguments, key: "id") else {
            throw Error.missingParameter("id")
        }
        guard let uuid = UUID(uuidString: idString) else {
            return ToolResult(
                success: false,
                content: "",
                metadata: .object(["source": .string("conversations_tool")]),
                toolCallId: toolCall.id,
                error: "Invalid conversation ID: '\(idString)'"
            )
        }

        guard let conversation = await dataProvider.getConversation(id: uuid) else {
            return ToolResult(
                success: false,
                content: "",
                metadata: .object(["source": .string("conversations_tool")]),
                toolCallId: toolCall.id,
                error: "Conversation not found: \(uuid.uuidString)"
            )
        }

        struct ConversationResponse: Codable {
            let id: String
            let modelName: String
            let topic: String?
            let description: String?
            let createdAt: String
            let updatedAt: String
            let totalMessageCount: Int
            let messages: [MessageResponse]

            struct MessageResponse: Codable {
                let role: String
                let content: String
                let timestamp: String?
            }
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        let total = conversation.messages.count
        let rawStart = extractOptionalInt(from: toolCall.arguments, key: "start_index") ?? 0
        let startIndex = max(0, rawStart)
        let start = min(startIndex, total)
        let effectiveLimit: Int
        if let rawLimit = extractOptionalInt(from: toolCall.arguments, key: "limit") {
            effectiveLimit = min(max(0, rawLimit), Self.getConversationMaxMessageLimit)
        } else {
            effectiveLimit = Self.getConversationDefaultLimit
        }
        let end = min(start + effectiveLimit, total)
        let pageMessages = conversation.messages[start..<end]

        let messageResponses = pageMessages.map { msg in
            ConversationResponse.MessageResponse(
                role: msg.role.rawValue,
                content: msg.content,
                timestamp: isoFormatter.string(from: msg.timestamp)
            )
        }

        let response = ConversationResponse(
            id: conversation.id.uuidString,
            modelName: conversation.modelName,
            topic: conversation.topic,
            description: conversation.description,
            createdAt: isoFormatter.string(from: conversation.createdAt),
            updatedAt: isoFormatter.string(from: conversation.updatedAt),
            totalMessageCount: total,
            messages: messageResponses
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]

        do {
            let data = try encoder.encode(response)
            guard let content = String(data: data, encoding: .utf8) else {
                return ToolResult(
                    success: false,
                    content: "",
                    metadata: .object(["source": .string("conversations_tool")]),
                    toolCallId: toolCall.id,
                    error: "Failed to encode conversation"
                )
            }

            logger?.info(
                "get_conversation executed",
                metadata: SwiftAgentKitLogging.metadata(
                    ("conversationId", .string(uuid.uuidString)),
                    ("messageCount", .stringConvertible(total)),
                    ("startIndex", .stringConvertible(start)),
                    ("returnedCount", .stringConvertible(messageResponses.count)),
                    ("toolCallId", .string(toolCall.id ?? "nil"))
                )
            )

            return ToolResult(
                success: true,
                content: content,
                metadata: .object([
                    "source": .string("conversations_tool"),
                    "action": .string("get"),
                    "conversationId": .string(uuid.uuidString),
                    "messageCount": .integer(total),
                    "startIndex": .integer(start),
                    "returnedCount": .integer(messageResponses.count),
                ]),
                toolCallId: toolCall.id
            )
        } catch {
            logger?.error("Failed to encode conversation: \(error)")
            return ToolResult(
                success: false,
                content: "",
                metadata: .object(["source": .string("conversations_tool")]),
                toolCallId: toolCall.id,
                error: "\(error)"
            )
        }
    }

    private func executeSwitchConversation(_ toolCall: ToolCall) async throws -> ToolResult {
        guard let idString = extractString(from: toolCall.arguments, key: "id") else {
            throw Error.missingParameter("id")
        }
        guard let uuid = UUID(uuidString: idString) else {
            return ToolResult(
                success: false,
                content: "",
                metadata: .object(["source": .string("conversations_tool")]),
                toolCallId: toolCall.id,
                error: "Invalid conversation ID: '\(idString)'"
            )
        }

        let message = extractString(from: toolCall.arguments, key: "message")

        do {
            _ = try await dataProvider.switchConversation(id: uuid, message: message)

            logger?.info(
                "switch_conversation executed",
                metadata: SwiftAgentKitLogging.metadata(
                    ("conversationId", .string(uuid.uuidString)),
                    ("hadMessage", .stringConvertible(message != nil)),
                    ("toolCallId", .string(toolCall.id ?? "nil"))
                )
            )

            let content: String
            var metadata: [String: EasyJSON.JSON] = [
                "source": .string("conversations_tool"),
                "action": .string("switch"),
                "conversationId": .string(uuid.uuidString),
            ]
            if message != nil {
                content = "Switched to conversation \(uuid.uuidString) and sent message."
                metadata["messageSent"] = .boolean(true)
            } else {
                content = "Switched to conversation \(uuid.uuidString)."
                metadata["messageSent"] = .boolean(false)
            }

            return ToolResult(
                success: true,
                content: content,
                metadata: .object(metadata),
                toolCallId: toolCall.id
            )
        } catch {
            logger?.error("switch_conversation failed: \(error)")
            return ToolResult(
                success: false,
                content: "",
                metadata: .object(["source": .string("conversations_tool")]),
                toolCallId: toolCall.id,
                error: "\(error)"
            )
        }
    }

    private func extractString(from arguments: JSON, key: String) -> String? {
        guard case .object(let dict) = arguments,
              let value = dict[key] else {
            return nil
        }
        if case .string(let s) = value { return s }
        return nil
    }

    private func extractOptionalInt(from arguments: JSON, key: String) -> Int? {
        guard case .object(let dict) = arguments,
              let value = dict[key] else {
            return nil
        }
        switch value {
        case .integer(let i):
            return i
        case .double(let d):
            return Int(d.rounded(.towardZero))
        case .string(let s):
            return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }
}

extension ConversationsToolProvider {
    enum Error: Swift.Error, Sendable {
        case unknownTool(String)
        case missingParameter(String)
    }
}

