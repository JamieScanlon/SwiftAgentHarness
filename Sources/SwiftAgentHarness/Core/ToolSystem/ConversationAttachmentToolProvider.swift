import EasyJSON
import Foundation
import Logging
import SwiftAgentKit

public struct ConversationAttachmentToolProvider: ToolProvider, ToolDescriptorHinting {
    public static let readAttachmentToolName = "read_attachment"

    private let resolveConversation: @Sendable () async -> ModelConversation?
    private let readAttachmentBytes: @Sendable (UUID, UUID) async throws -> (ConversationAttachmentDescriptor, Data)
    private let logger: Logger?

    public var name: String { "ConversationAttachments" }

    public var descriptorHintsByToolName: [String: ToolDescriptorHints] {
        [
            Self.readAttachmentToolName: ToolDescriptorHints(effectClass: .readOnly, parallelHint: .parallelizable),
        ]
    }

    public init(
        resolveConversation: @escaping @Sendable () async -> ModelConversation?,
        readAttachmentBytes: @escaping @Sendable (UUID, UUID) async throws -> (ConversationAttachmentDescriptor, Data),
        logger: Logger? = nil
    ) {
        self.resolveConversation = resolveConversation
        self.readAttachmentBytes = readAttachmentBytes
        self.logger = logger ?? SwiftAgentKitLogging.logger(
            for: .custom(subsystem: "SwiftAgentHarness", component: "ConversationAttachmentToolProvider")
        )
    }

    public func availableTools() async -> [ToolDefinition] {
        [
            ToolDefinition(
                name: Self.readAttachmentToolName,
                description: """
                Read a conversation attachment by attachment_id from the attachments catalog. Returns at most 256KB \
                of text per call; use offset (1-based line) and limit (max lines) for larger text attachments. Use \
                when a reference or digest block lists an attachment_id you need to promote into context.
                """,
                parameters: [
                    .init(
                        name: "attachment_id",
                        description: "Attachment UUID from the attachments catalog or projection block",
                        type: "string",
                        required: true
                    ),
                    .init(
                        name: "offset",
                        description: "Optional 1-based line number to start reading from",
                        type: "integer",
                        required: false
                    ),
                    .init(
                        name: "limit",
                        description: "Optional maximum number of lines to return",
                        type: "integer",
                        required: false
                    ),
                ],
                type: .function
            ),
        ]
    }

    public func policyTags(for definition: ToolDefinition) async -> [ToolPolicyTag] {
        guard definition.name == Self.readAttachmentToolName else { return [] }
        return [ToolRegistryResultFormattingPolicy.exactContentObservationPolicyTag()]
    }

    public func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
        guard toolCall.name == Self.readAttachmentToolName else {
            return failure(toolCall, "Unknown tool: \(toolCall.name)")
        }
        guard let conversation = await resolveConversation() else {
            return failure(toolCall, "No active conversation")
        }
        guard let attachmentIDRaw = stringArgument(toolCall.arguments, key: "attachment_id"),
              let attachmentID = UUID(uuidString: attachmentIDRaw) else {
            return failure(toolCall, "attachment_id must be a valid UUID string")
        }
        let offsetLine = intArgument(toolCall.arguments, key: "offset")
        let limitLines = intArgument(toolCall.arguments, key: "limit")
        do {
            let (descriptor, bytes) = try await readAttachmentBytes(attachmentID, conversation.id)
            let body = try formatAttachmentBody(
                descriptor: descriptor,
                bytes: bytes,
                offsetLine: offsetLine,
                limitLines: limitLines
            )
            let wrapped = AttachmentProvenancePolicy.wrapIfRequired(descriptor: descriptor, content: body)
            return ToolResult(success: true, content: wrapped, toolCallId: toolCall.id)
        } catch let window as AttachmentReadWindowRequired {
            return failure(toolCall, window.guidance)
        } catch {
            logger?.warning("[ConversationAttachmentToolProvider] read_attachment failed: \(error)")
            return failure(toolCall, (error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    private func formatAttachmentBody(
        descriptor: ConversationAttachmentDescriptor,
        bytes: Data,
        offsetLine: Int?,
        limitLines: Int?
    ) throws -> String {
        if isTextLike(descriptor: descriptor, bytes: bytes),
           let text = String(data: bytes, encoding: .utf8) {
            if ReadFileWindowing.requiresWindowing(content: text, offsetLine: offsetLine, limitLines: limitLines) {
                throw AttachmentReadWindowRequired(guidance: ReadFileWindowing.exceedsCapGuidance)
            }
            return ReadFileWindowing.sliceLines(content: text, offsetLine: offsetLine, limitLines: limitLines)
        }
        var lines = ["binary attachment"]
        lines.append("name: \(descriptor.name)")
        if let mimeType = descriptor.mimeType, !mimeType.isEmpty {
            lines.append("mime_type: \(mimeType)")
        }
        lines.append("original_byte_count: \(bytes.count)")
        lines.append("Content is binary; text decoding is not available for this attachment.")
        return lines.joined(separator: "\n")
    }

    private func isTextLike(descriptor: ConversationAttachmentDescriptor, bytes: Data) -> Bool {
        if let mimeType = descriptor.mimeType {
            let lowered = mimeType.lowercased()
            if lowered.hasPrefix("text/") || lowered == "application/json" || lowered == "application/xml" {
                return String(data: bytes, encoding: .utf8) != nil
            }
        }
        let ext = (descriptor.name as NSString).pathExtension.lowercased()
        if ["txt", "md", "json", "csv", "swift", "py", "js", "ts", "yaml", "yml", "xml", "html", "htm", "log"]
            .contains(ext) {
            return String(data: bytes, encoding: .utf8) != nil
        }
        if bytes.count <= 64_000, !bytes.contains(0), String(data: bytes, encoding: .utf8) != nil {
            return true
        }
        return false
    }

    private func stringArgument(_ arguments: JSON, key: String) -> String? {
        guard case .object(let fields) = arguments,
              case .string(let value)? = fields[key] else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func intArgument(_ arguments: JSON, key: String) -> Int? {
        guard case .object(let fields) = arguments, let value = fields[key] else { return nil }
        switch value {
        case .integer(let intValue):
            return intValue
        case .double(let doubleValue):
            return Int(doubleValue)
        case .string(let text):
            return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private func failure(_ toolCall: ToolCall, _ message: String) -> ToolResult {
        ToolResult(success: false, content: message, toolCallId: toolCall.id, error: message)
    }
}

private struct AttachmentReadWindowRequired: Error {
    let guidance: String
}
