import EasyJSON
import Foundation
import Logging
import SwiftAgentKit

enum ToolResultSpillEnvelope {
    static let marker = "[tool result spilled]"

    static func isSpillEnvelope(_ content: String) -> Bool {
        content.contains(marker)
    }

    static func make(
        preview: String,
        spillPath: String,
        originalByteCount: Int,
        toolCallId: String
    ) -> String {
        """
        \(marker)
        preview:
        \(preview)
        full_output_path: \(spillPath)
        original_byte_count: \(originalByteCount)
        tool_call_id: \(toolCallId)
        Use read_file with offset/limit to read more.
        """
    }

    static func previewPrefix(for content: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        let data = Data(content.utf8)
        guard data.count > maxBytes else { return content }
        var cutoff = maxBytes
        while cutoff > 0 {
            let prefix = data.prefix(cutoff)
            if let decoded = String(data: prefix, encoding: .utf8) {
                return decoded
            }
            cutoff -= 1
        }
        return ""
    }

    static func spillMetadata(
        spillPath: String,
        originalByteCount: Int
    ) -> JSON {
        .object([
            "spilled": .boolean(true),
            "spillPath": .string(spillPath),
            "originalByteCount": .string(String(originalByteCount)),
        ])
    }

    static func mergeMetadata(base: JSON, spill: JSON) -> JSON {
        guard case .object(var object) = base else {
            return spill
        }
        guard case .object(let spillObject) = spill else {
            return base
        }
        for (key, value) in spillObject {
            object[key] = value
        }
        return .object(object)
    }
}

struct ToolResultFormattingSpillContext: Sendable {
    let conversationID: UUID
    let toolName: String
    let entry: ToolRegistryEntry?
    let spillWriter: any ToolResultSpillWriting
    let logger: Logger?
    let modelSupportsVision: Bool
    let imageProcessor: ImageProcessing

    init(
        conversationID: UUID,
        toolName: String,
        entry: ToolRegistryEntry?,
        spillWriter: any ToolResultSpillWriting,
        logger: Logger? = nil,
        modelSupportsVision: Bool = false,
        imageProcessor: ImageProcessing = DefaultImageProcessor()
    ) {
        self.conversationID = conversationID
        self.toolName = toolName
        self.entry = entry
        self.spillWriter = spillWriter
        self.logger = logger
        self.modelSupportsVision = modelSupportsVision
        self.imageProcessor = imageProcessor
    }
}

protocol ToolResultSpillWriting: Sendable {
    func putIfNeeded(
        conversationID: UUID,
        toolCallId: String,
        content: String
    ) throws -> ToolResultSpillWriteResult?
}

struct HarnessSessionPersistenceSpillWriter: ToolResultSpillWriting {
    let persistence: any HarnessSessionPersistence

    func putIfNeeded(
        conversationID: UUID,
        toolCallId: String,
        content: String
    ) throws -> ToolResultSpillWriteResult? {
        try persistence.putToolResultSpillIfNeeded(
            conversationID: conversationID,
            toolCallId: toolCallId,
            content: content
        )
    }
}

enum ToolResultSpillFormatter {
    struct ApplyResult: Sendable {
        let result: ToolResult
        let spilled: Bool
    }

    static func applyIfNeeded(
        result: ToolResult,
        stage: ToolResultFormattingStage,
        configuration: ToolResultFormattingConfiguration,
        spillContext: ToolResultFormattingSpillContext?
    ) -> ApplyResult {
        guard configuration.enabled else {
            return ApplyResult(result: result, spilled: false)
        }
        if stage == .persistence, ToolResultSpillEnvelope.isSpillEnvelope(result.content) {
            return ApplyResult(result: result, spilled: true)
        }
        guard stage == .runtime else {
            return ApplyResult(result: result, spilled: false)
        }
        guard configuration.spillEnabled, let spillContext else {
            return ApplyResult(result: result, spilled: false)
        }
        guard let toolCallId = result.toolCallId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !toolCallId.isEmpty else {
            return ApplyResult(result: result, spilled: false)
        }
        let threshold = ToolRegistrySpillPolicy.effectiveMaxResultSizeBeforeSpill(
            entry: spillContext.entry,
            configuration: configuration
        )
        let byteCount = Data(result.content.utf8).count
        guard byteCount > threshold else {
            return ApplyResult(result: result, spilled: false)
        }
        do {
            guard let writeResult = try spillContext.spillWriter.putIfNeeded(
                conversationID: spillContext.conversationID,
                toolCallId: toolCallId,
                content: result.content
            ) else {
                spillContext.logger?.warning(
                    "[ToolResultSpill] spill store unavailable for \(spillContext.toolName); falling back to truncation"
                )
                return ApplyResult(result: result, spilled: false)
            }
            let preview = ToolResultSpillEnvelope.previewPrefix(
                for: result.content,
                maxBytes: configuration.spillPreviewMaxBytes
            )
            let envelope = ToolResultSpillEnvelope.make(
                preview: preview,
                spillPath: writeResult.fileURL.path,
                originalByteCount: writeResult.byteCount,
                toolCallId: toolCallId
            )
            let metadata = ToolResultSpillEnvelope.mergeMetadata(
                base: result.metadata,
                spill: ToolResultSpillEnvelope.spillMetadata(
                    spillPath: writeResult.fileURL.path,
                    originalByteCount: writeResult.byteCount
                )
            )
            let spilledResult = ToolResult(
                success: result.success,
                content: envelope,
                metadata: metadata,
                toolCallId: result.toolCallId,
                error: result.error
            )
            return ApplyResult(result: spilledResult, spilled: true)
        } catch {
            spillContext.logger?.warning(
                "[ToolResultSpill] spill failed for \(spillContext.toolName): \(error); falling back to truncation"
            )
            return ApplyResult(result: result, spilled: false)
        }
    }
}
