import EasyJSON
import Foundation
import SwiftAgentKit

enum ToolResultFormattingStage: Sendable {
    case runtime
    case persistence
    case compaction
}

enum ToolResultFormattingStack {
    struct StagePolicy: Sendable {
        let maxCharacters: Int
        let maxBytes: Int
        let maxMetadataBytes: Int
        let imagePayloadPlaceholder: String
        let metadataPlaceholder: String
        let truncationMarker: String
    }

    static func apply(
        result: ToolResult,
        stage: ToolResultFormattingStage,
        configuration: ToolResultFormattingConfiguration,
        spillContext: ToolResultFormattingSpillContext? = nil
    ) -> ToolResult {
        guard configuration.enabled else { return result }
        let spillOutcome = ToolResultSpillFormatter.applyIfNeeded(
            result: result,
            stage: stage,
            configuration: configuration,
            spillContext: spillContext
        )
        let working = spillOutcome.result
        let entry = spillContext?.entry
        let toolName = spillContext?.toolName ?? entry?.name ?? ""
        let skipLossyTrim = spillOutcome.spilled
            || ToolResultSpillEnvelope.isSpillEnvelope(working.content)
            || ToolRegistryResultFormattingPolicy.skipsLossyContentTrim(
                entry: entry,
                toolName: toolName,
                stage: stage
            )
        let skipMetadataTrim = ToolRegistryResultFormattingPolicy.skipsMetadataTrim(
            entry: entry,
            toolName: toolName,
            stage: stage
        )
        let stagePolicy = stagePolicy(for: stage, configuration: configuration)
        var content = working.content
        var metadata = working.metadata
        if configuration.sanitizeInlineImagePayloads {
            let imagePolicy = inlineImagePolicy(
                stage: stage,
                configuration: configuration,
                spillContext: spillContext
            )
            content = ToolResultInlineImageSanitizer.sanitizeString(
                content,
                policy: imagePolicy,
                processor: spillContext?.imageProcessor ?? DefaultImageProcessor(),
                logger: spillContext?.logger
            )
            metadata = ToolResultInlineImageSanitizer.sanitizeJSON(
                metadata,
                policy: imagePolicy,
                processor: spillContext?.imageProcessor ?? DefaultImageProcessor(),
                logger: spillContext?.logger
            )
        }
        if !skipLossyTrim {
            content = trimToLineLimit(content, maxLines: configuration.maxLines)
            content = trimToCharacterLimit(
                content,
                maxCharacters: stagePolicy.maxCharacters,
                marker: stagePolicy.truncationMarker
            )
            content = trimToByteLimit(
                content,
                maxBytes: stagePolicy.maxBytes,
                marker: stagePolicy.truncationMarker
            )
        }
        if !skipMetadataTrim {
            metadata = trimMetadataToByteLimit(
                metadata,
                maxBytes: stagePolicy.maxMetadataBytes,
                placeholder: stagePolicy.metadataPlaceholder,
                stage: stage
            )
        }
        let metadataChanged = !jsonEqual(lhs: metadata, rhs: working.metadata)
        guard content != working.content || metadataChanged else { return working }
        return ToolResult(
            success: working.success,
            content: content,
            metadata: metadata,
            toolCallId: working.toolCallId,
            error: working.error
        )
    }

    static func stagePolicy(
        for stage: ToolResultFormattingStage,
        configuration: ToolResultFormattingConfiguration
    ) -> StagePolicy {
        switch stage {
        case .runtime:
            return StagePolicy(
                maxCharacters: configuration.runtimeMaxCharacters,
                maxBytes: configuration.runtimeMaxBytes,
                maxMetadataBytes: configuration.runtimeMetadataMaxBytes,
                imagePayloadPlaceholder: configuration.imagePayloadPlaceholder,
                metadataPlaceholder: configuration.metadataPlaceholder,
                truncationMarker: configuration.truncationMarker
            )
        case .persistence:
            return StagePolicy(
                maxCharacters: configuration.persistenceMaxCharacters,
                maxBytes: configuration.persistenceMaxBytes,
                maxMetadataBytes: configuration.persistenceMetadataMaxBytes,
                imagePayloadPlaceholder: configuration.imagePayloadPlaceholder,
                metadataPlaceholder: configuration.metadataPlaceholder,
                truncationMarker: configuration.truncationMarker
            )
        case .compaction:
            return StagePolicy(
                maxCharacters: configuration.compactionMaxCharacters,
                maxBytes: configuration.compactionMaxBytes,
                maxMetadataBytes: configuration.compactionMetadataMaxBytes,
                imagePayloadPlaceholder: configuration.compactionImagePayloadPlaceholder,
                metadataPlaceholder: configuration.compactionMetadataPlaceholder,
                truncationMarker: configuration.compactionTruncationMarker
            )
        }
    }

    static func compactionConfiguration(
        base: ToolResultFormattingConfiguration,
        compactionMaxCharactersOverride: Int,
        compactionImagePlaceholderOverride: String?,
        compactionTruncationMarkerOverride: String?
    ) -> ToolResultFormattingConfiguration {
        ToolResultFormattingConfiguration(
            enabled: base.enabled,
            spillEnabled: base.spillEnabled,
            spillPreviewMaxBytes: base.spillPreviewMaxBytes,
            defaultMaxResultSizeBeforeSpill: base.defaultMaxResultSizeBeforeSpill,
            runtimeMaxCharacters: base.runtimeMaxCharacters,
            persistenceMaxCharacters: base.persistenceMaxCharacters,
            compactionMaxCharacters: max(0, compactionMaxCharactersOverride),
            runtimeMaxBytes: base.runtimeMaxBytes,
            persistenceMaxBytes: base.persistenceMaxBytes,
            compactionMaxBytes: base.compactionMaxBytes,
            runtimeMetadataMaxBytes: base.runtimeMetadataMaxBytes,
            persistenceMetadataMaxBytes: base.persistenceMetadataMaxBytes,
            compactionMetadataMaxBytes: base.compactionMetadataMaxBytes,
            maxLines: base.maxLines,
            sanitizeInlineImagePayloads: base.sanitizeInlineImagePayloads,
            maxInlineImagePixelDimension: base.maxInlineImagePixelDimension,
            maxInlineImageBytes: base.maxInlineImageBytes,
            imagePayloadPlaceholder: base.imagePayloadPlaceholder,
            compactionImagePayloadPlaceholder: compactionImagePlaceholderOverride ?? base.compactionImagePayloadPlaceholder,
            metadataPlaceholder: base.metadataPlaceholder,
            compactionMetadataPlaceholder: base.compactionMetadataPlaceholder,
            truncationMarker: base.truncationMarker,
            compactionTruncationMarker: compactionTruncationMarkerOverride ?? base.compactionTruncationMarker
        )
    }

    private static func inlineImagePolicy(
        stage: ToolResultFormattingStage,
        configuration: ToolResultFormattingConfiguration,
        spillContext: ToolResultFormattingSpillContext?
    ) -> ToolResultInlineImageSanitizer.Policy {
        let placeholder: String
        switch stage {
        case .runtime, .persistence:
            placeholder = configuration.imagePayloadPlaceholder
        case .compaction:
            placeholder = configuration.compactionImagePayloadPlaceholder
        }
        let mode: ToolResultInlineImageSanitizer.Mode
        switch stage {
        case .compaction:
            mode = .strip
        case .runtime, .persistence:
            mode = spillContext?.modelSupportsVision == true ? .sanitize : .strip
        }
        return ToolResultInlineImageSanitizer.Policy(
            mode: mode,
            maxPixelDimension: configuration.maxInlineImagePixelDimension,
            maxBytes: configuration.maxInlineImageBytes,
            placeholder: placeholder
        )
    }

    private static func trimToLineLimit(_ content: String, maxLines: Int) -> String {
        guard maxLines > 0 else { return content }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return content }
        let kept = lines.prefix(maxLines).joined(separator: "\n")
        let dropped = lines.count - maxLines
        return "\(kept)\n[tool result truncated: \(dropped) additional line(s) omitted]"
    }

    private static func trimToCharacterLimit(_ content: String, maxCharacters: Int, marker: String) -> String {
        guard maxCharacters > 0, content.count > maxCharacters else { return content }
        let end = content.index(content.startIndex, offsetBy: maxCharacters)
        return "\(content[..<end])\(marker)"
    }

    private static func trimToByteLimit(_ content: String, maxBytes: Int, marker: String) -> String {
        guard maxBytes > 0 else { return content }
        let data = Data(content.utf8)
        guard data.count > maxBytes else { return content }
        var cutoff = maxBytes
        while cutoff > 0 {
            let prefix = data.prefix(cutoff)
            if let decoded = String(data: prefix, encoding: .utf8) {
                return "\(decoded)\(marker)"
            }
            cutoff -= 1
        }
        return marker
    }

    private static func trimMetadataToByteLimit(
        _ metadata: JSON,
        maxBytes: Int,
        placeholder: String,
        stage: ToolResultFormattingStage
    ) -> JSON {
        guard maxBytes > 0 else { return metadata }
        guard let encoded = try? JSONEncoder().encode(metadata), encoded.count > maxBytes else {
            return metadata
        }
        let stageName: String
        switch stage {
        case .runtime:
            stageName = "runtime"
        case .persistence:
            stageName = "persistence"
        case .compaction:
            stageName = "compaction"
        }
        return .object([
            "status": .string("metadata_truncated"),
            "stage": .string(stageName),
            "originalByteCount": .string(String(encoded.count)),
            "placeholder": .string(placeholder),
        ])
    }

    private static func jsonEqual(lhs: JSON, rhs: JSON) -> Bool {
        guard let left = try? JSONEncoder().encode(lhs),
              let right = try? JSONEncoder().encode(rhs) else {
            return false
        }
        return left == right
    }
}
