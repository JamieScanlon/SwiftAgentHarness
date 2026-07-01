import EasyJSON
import Foundation
import Logging
import SwiftAgentKit

/// Core-owned output verb. The model emits portable presentations; surfaces deliver via outbound adapters.
public struct MessageToolProvider: ToolProvider, ToolDescriptorHinting {
    public static let toolName = MessageToolArgumentsParser.toolName

    private let deliveryRegistry: MessageOutputDeliveryRegistry
    private let resolveConversationID: @Sendable () async -> UUID?
    private let resolveDeliveryMetadata: @Sendable () async -> MessageOutputDeliveryMetadata
    private let logger: Logger?

    public var name: String { "MessageOutput" }

    public var descriptorHintsByToolName: [String: ToolDescriptorHints] {
        [
            Self.toolName: ToolDescriptorHints(effectClass: .readOnly, parallelHint: .serialOnly),
        ]
    }

    public init(
        deliveryRegistry: MessageOutputDeliveryRegistry = .shared,
        resolveConversationID: @escaping @Sendable () async -> UUID?,
        resolveDeliveryMetadata: @escaping @Sendable () async -> MessageOutputDeliveryMetadata,
        logger: Logger? = nil
    ) {
        self.deliveryRegistry = deliveryRegistry
        self.resolveConversationID = resolveConversationID
        self.resolveDeliveryMetadata = resolveDeliveryMetadata
        self.logger = logger ?? SwiftAgentKitLogging.logger(
            for: .custom(subsystem: "SwiftAgentHarness", component: "MessageToolProvider")
        )
    }

    public func availableTools() async -> [ToolDefinition] {
        [
            ToolDefinition(
                name: Self.toolName,
                description: """
                Emit structured or native user-visible output. Use for buttons, selects, titled/toned blocks, \
                or explicit delivery actions (media). Ordinary prose should be written directly as assistant text.
                """,
                parameters: [
                    .init(name: "title", description: "Optional headline.", type: "string", required: false),
                    .init(
                        name: "tone",
                        description: "Optional tone: info, success, warning, error.",
                        type: "string",
                        required: false
                    ),
                    .init(
                        name: "blocks",
                        description: """
                        JSON array of blocks: text, context, divider, buttons, select. Example: \
                        [{"type":"text","text":"Hello"}]
                        """,
                        type: "string",
                        required: true
                    ),
                    .init(name: "action", description: "Optional delivery action key for channel media params.", type: "string", required: false),
                ],
                type: .function
            ),
        ]
    }

    public func rawSchema(for definition: ToolDefinition) async -> JSON? {
        guard definition.name == Self.toolName else { return nil }
        let base: JSON = .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object(["type": .string("string")]),
                "tone": .object(["type": .string("string")]),
                "blocks": .object([
                    "type": .string("string"),
                    "description": .string("JSON-encoded MessageBlock array"),
                ]),
                "action": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("blocks")]),
        ])
        return MessageToolSchemaRegistry.mergedRawSchema(base: base)
    }

    public func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
        guard toolCall.name == Self.toolName else {
            throw MessageToolError.unknownTool(toolCall.name)
        }
        let presentation = try parsePresentation(from: toolCall.arguments)
        if let conversationID = await resolveConversationID() {
            var metadata = await resolveDeliveryMetadata()
            metadata.toolCallID = toolCall.id
            await deliveryRegistry.deliver(
                presentation: presentation,
                conversationID: conversationID,
                metadata: metadata
            )
        }
        let visible = presentation.textFallback()
        logger?.info(
            "message tool delivered",
            metadata: SwiftAgentKitLogging.metadata(
                ("toolCallId", .string(toolCall.id ?? "nil")),
                ("blockCount", .stringConvertible(presentation.blocks.count))
            )
        )
        return ToolResult(
            success: true,
            content: visible.isEmpty ? "Message delivered." : visible,
            metadata: .object([
                "source": .string("message_tool"),
                "delivered": .boolean(true),
            ]),
            toolCallId: toolCall.id
        )
    }

    private func parsePresentation(from arguments: JSON) throws -> MessagePresentation {
        guard case .object(let dict) = arguments else {
            throw MessageToolError.invalidArguments("expected object")
        }
        let title = stringValue(dict["title"])
        let tone = dict["tone"].flatMap { value -> MessageTone? in
            guard case .string(let raw) = value else { return nil }
            return MessageTone(rawValue: raw)
        }
        guard let blocksRaw = stringValue(dict["blocks"]), !blocksRaw.isEmpty else {
            throw MessageToolError.missingParameter("blocks")
        }
        guard let blocksData = blocksRaw.data(using: .utf8),
              let blocks = try? JSONDecoder().decode([MessageBlock].self, from: blocksData) else {
            throw MessageToolError.invalidArguments("blocks must be JSON array of MessageBlock")
        }
        return MessagePresentation(title: title, tone: tone, blocks: blocks)
    }

    private func stringValue(_ json: JSON?) -> String? {
        guard let json, case .string(let value) = json else { return nil }
        return value
    }
}

enum MessageToolError: Error, Sendable {
    case unknownTool(String)
    case missingParameter(String)
    case invalidArguments(String)
}
