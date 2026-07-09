import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private struct MockFormattingImageProcessor: ImageProcessing {
    func generateThumbnail(from data: Data, maxPixelSize: Int) -> Data? { nil }
    func scaleImage(_ data: Data, maxPixelDimension: Int) -> Data? { data }
    func scaleImageToFileSize(_ data: Data, maxFileSize: Int) -> Data? {
        data.count <= maxFileSize ? data : nil
    }
}

private struct NoOpToolResultSpillWriter: ToolResultSpillWriting {
    func putIfNeeded(
        conversationID: UUID,
        toolCallId: String,
        content: String
    ) throws -> ToolResultSpillWriteResult? {
        nil
    }
}

@Suite("Tool result formatting stack")
struct ToolResultFormattingStackTests {
    @Test("runtime stage trims content and line count")
    func runtimeStageTrims() {
        let result = ToolResult(
            success: true,
            content: "a\nb\nc\nd\ne",
            metadata: .object([:]),
            toolCallId: "call-1"
        )
        let config = ToolResultFormattingConfiguration(
            enabled: true,
            runtimeMaxCharacters: 7,
            persistenceMaxCharacters: 100,
            compactionMaxCharacters: 100,
            maxLines: 3,
            sanitizeInlineImagePayloads: false
        )
        let output = ToolResultFormattingStack.apply(result: result, stage: .runtime, configuration: config)
        #expect(output.content.contains("[tool result truncated"))
    }

    @Test("inline image payloads are stripped for text-only models")
    func inlineImageSanitization() {
        let payload = "prefix data:image/png;base64,AAAAAABBBBBCCCCCC suffix"
        let result = ToolResult(
            success: true,
            content: payload,
            metadata: .object([:]),
            toolCallId: "call-2"
        )
        let spillContext = ToolResultFormattingSpillContext(
            conversationID: UUID(),
            toolName: "screenshot",
            entry: nil,
            spillWriter: NoOpToolResultSpillWriter(),
            modelSupportsVision: false
        )
        let output = ToolResultFormattingStack.apply(
            result: result,
            stage: .persistence,
            configuration: .default,
            spillContext: spillContext
        )
        #expect(output.content.contains("[inline image payload omitted]"))
        #expect(!output.content.contains("data:image/png;base64"))
    }

    @Test("inline image payloads are sanitized for vision models at runtime")
    func visionModelPreservesSanitizedImage() {
        let tinyPNG =
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let payload = "prefix data:image/jpeg;base64,\(tinyPNG) suffix"
        let result = ToolResult(
            success: true,
            content: payload,
            metadata: .object([:]),
            toolCallId: "call-vision"
        )
        let spillContext = ToolResultFormattingSpillContext(
            conversationID: UUID(),
            toolName: "screenshot",
            entry: nil,
            spillWriter: NoOpToolResultSpillWriter(),
            modelSupportsVision: true,
            imageProcessor: MockFormattingImageProcessor()
        )
        let output = ToolResultFormattingStack.apply(
            result: result,
            stage: .runtime,
            configuration: .default,
            spillContext: spillContext
        )
        #expect(output.content.contains("data:image/png;base64,"))
        #expect(!output.content.contains("[inline image payload omitted]"))
    }

    @Test("compaction stage strips images even for vision models")
    func compactionStripsVisionImages() {
        let tinyPNG =
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let payload = "prefix data:image/png;base64,\(tinyPNG) suffix"
        let result = ToolResult(
            success: true,
            content: payload,
            metadata: .object([:]),
            toolCallId: "call-3"
        )
        let config = ToolResultFormattingConfiguration(
            sanitizeInlineImagePayloads: true,
            compactionImagePayloadPlaceholder: "[old image payload replaced for compaction]"
        )
        let spillContext = ToolResultFormattingSpillContext(
            conversationID: UUID(),
            toolName: "screenshot",
            entry: nil,
            spillWriter: NoOpToolResultSpillWriter(),
            modelSupportsVision: true,
            imageProcessor: MockFormattingImageProcessor()
        )
        let output = ToolResultFormattingStack.apply(
            result: result,
            stage: .compaction,
            configuration: config,
            spillContext: spillContext
        )
        #expect(output.content.contains("[old image payload replaced for compaction]"))
        #expect(!output.content.contains("data:image/png;base64"))
    }

    @Test("byte limit truncation is deterministic")
    func byteLimitTruncation() {
        let content = String(repeating: "abcdef", count: 100)
        let result = ToolResult(
            success: true,
            content: content,
            metadata: .object([:]),
            toolCallId: "call-4"
        )
        let config = ToolResultFormattingConfiguration(
            runtimeMaxCharacters: 10_000,
            runtimeMaxBytes: 80,
            truncationMarker: "[tool result truncated]"
        )
        let output = ToolResultFormattingStack.apply(
            result: result,
            stage: .runtime,
            configuration: config
        )
        #expect(output.content.contains("[tool result truncated]"))
        #expect(output.content.utf8.count <= 120)
    }

    @Test("metadata payloads are byte-capped by stage policy")
    func metadataByteLimitShaping() {
        let oversizedMetadata: JSON = .object([
            "payload": .string(String(repeating: "m", count: 4_000)),
        ])
        let result = ToolResult(
            success: true,
            content: "ok",
            metadata: oversizedMetadata,
            toolCallId: "call-5"
        )
        let config = ToolResultFormattingConfiguration(
            runtimeMetadataMaxBytes: 120,
            metadataPlaceholder: "[meta omitted]"
        )
        let output = ToolResultFormattingStack.apply(
            result: result,
            stage: .runtime,
            configuration: config
        )
        guard case .object(let object) = output.metadata else {
            Issue.record("Expected object metadata after shaping")
            return
        }
        if case .string(let status) = object["status"] {
            #expect(status == "metadata_truncated")
        } else {
            Issue.record("Expected metadata truncation status string")
        }
        if case .string(let stage) = object["stage"] {
            #expect(stage == "runtime")
        } else {
            Issue.record("Expected stage string")
        }
        if case .string(let placeholder) = object["placeholder"] {
            #expect(placeholder == "[meta omitted]")
        } else {
            Issue.record("Expected placeholder string")
        }
    }

    @Test("metadata image payloads are sanitized deterministically")
    func metadataImageSanitization() {
        let metadata: JSON = .object([
            "image": .string("data:image/png;base64,AAAAABBBBB"),
        ])
        let result = ToolResult(
            success: true,
            content: "done",
            metadata: metadata,
            toolCallId: "call-6"
        )
        let output = ToolResultFormattingStack.apply(
            result: result,
            stage: .persistence,
            configuration: .default
        )
        guard case .object(let object) = output.metadata else {
            Issue.record("Expected object metadata")
            return
        }
        if case .string(let image) = object["image"] {
            #expect(image == "[inline image payload omitted]")
        } else {
            Issue.record("Expected sanitized image string")
        }
    }

    @Test("compaction helper preserves base settings and explicit overrides")
    func compactionConfigurationOverrideHelper() {
        let base = ToolResultFormattingConfiguration(
            runtimeMaxCharacters: 101,
            persistenceMaxCharacters: 202,
            compactionMaxCharacters: 303,
            compactionImagePayloadPlaceholder: "[base image]",
            compactionTruncationMarker: "[base truncation]"
        )
        let derived = ToolResultFormattingStack.compactionConfiguration(
            base: base,
            compactionMaxCharactersOverride: 150,
            compactionImagePlaceholderOverride: "[override image]",
            compactionTruncationMarkerOverride: "[override truncation]"
        )
        #expect(derived.runtimeMaxCharacters == 101)
        #expect(derived.persistenceMaxCharacters == 202)
        #expect(derived.compactionMaxCharacters == 150)
        #expect(derived.compactionImagePayloadPlaceholder == "[override image]")
        #expect(derived.compactionTruncationMarker == "[override truncation]")
    }
}
