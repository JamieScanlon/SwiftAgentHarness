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
            content = trimToLineLimit(
                content,
                maxLines: configuration.maxLines,
                stage: stage,
                constantMarker: stagePolicy.truncationMarker
            )
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
        let images = working.images
        if !images.isEmpty {
            let imageParts = formatImageParts(
                images,
                stage: stage,
                configuration: configuration,
                spillContext: spillContext,
                geometryBound: ToolRegistryResultFormattingPolicy.hasGeometryBoundImages(entry: entry, toolName: toolName)
            )
            let unchanged = content == working.content && !metadataChanged
                && imageParts == images.map { ToolResultContentPart.image($0) }
            guard !unchanged else { return working }
            return working.replacingParts([.text(content)] + imageParts, metadata: metadata)
        }
        guard content != working.content || metadataChanged else { return working }
        return ToolResult(
            success: working.success,
            content: content,
            metadata: metadata,
            toolCallId: working.toolCallId,
            error: working.error
        )
    }

    /// Image parts follow the same policy as inline data URLs: kept for vision models (rescaled when over the
    /// caps), replaced by a marker otherwise and always at compaction. Geometry-bound images are never rescaled;
    /// over the caps they become a marker, because a resized screenshot would misplace every click.
    private static func formatImageParts(
        _ images: [ToolResultImage],
        stage: ToolResultFormattingStage,
        configuration: ToolResultFormattingConfiguration,
        spillContext: ToolResultFormattingSpillContext?,
        geometryBound: Bool
    ) -> [ToolResultContentPart] {
        var policy = inlineImagePolicy(stage: stage, configuration: configuration, spillContext: spillContext)
        if geometryBound, let modelEdge = spillContext?.modelMaxImageEdgePx, modelEdge > 0 {
            // Sized to the bound model at capture, so the model's cap is the one that applies.
            policy.maxPixelDimension = modelEdge
        }
        let processor = spillContext?.imageProcessor ?? DefaultImageProcessor()
        return images.map { image in
            guard configuration.sanitizeInlineImagePayloads else { return .image(image) }
            if policy.mode == .strip {
                return .text("\(policy.placeholder): \(image.mediaType)")
            }
            guard let data = image.data else { return .image(image) }
            let longEdge = [image.width, image.height].compactMap { $0 }.max()
                ?? ToolResultInlineImageSanitizer.imageMaxPixelDimension(data: data)
                ?? 0
            let overDimension = policy.maxPixelDimension > 0 && longEdge > policy.maxPixelDimension
            let overBytes = policy.maxBytes > 0 && data.count > policy.maxBytes
            guard overDimension || overBytes else { return .image(image) }
            if geometryBound {
                spillContext?.logger?.warning(
                    "[ToolResultImage] geometry-bound image over caps longEdge=\(longEdge) bytes=\(data.count); replaced with marker"
                )
                return .text("\(policy.placeholder): screenshot exceeds the image size cap; observe again with a smaller image limit")
            }
            var processed = data
            if overDimension {
                guard let scaled = processor.scaleImage(processed, maxPixelDimension: policy.maxPixelDimension) else {
                    return .text("\(policy.placeholder): image exceeds dimension cap")
                }
                processed = scaled
            }
            if policy.maxBytes > 0, processed.count > policy.maxBytes {
                guard let scaled = processor.scaleImageToFileSize(processed, maxFileSize: policy.maxBytes),
                      scaled.count <= policy.maxBytes else {
                    return .text("\(policy.placeholder): image exceeds byte cap")
                }
                processed = scaled
            }
            return .image(ToolResultImage(
                data: processed,
                mediaType: ToolResultInlineImageSanitizer.inferMime(from: processed) ?? image.mediaType
            ))
        }
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
        var maxPixelDimension = configuration.maxInlineImagePixelDimension
        if let modelEdge = spillContext?.modelMaxImageEdgePx, modelEdge > 0 {
            maxPixelDimension = maxPixelDimension > 0 ? min(maxPixelDimension, modelEdge) : modelEdge
        }
        return ToolResultInlineImageSanitizer.Policy(
            mode: mode,
            maxPixelDimension: maxPixelDimension,
            maxBytes: configuration.maxInlineImageBytes,
            placeholder: placeholder
        )
    }

    private static func trimToLineLimit(
        _ content: String,
        maxLines: Int,
        stage: ToolResultFormattingStage,
        constantMarker: String
    ) -> String {
        guard maxLines > 0 else { return content }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return content }
        let kept = lines.prefix(maxLines).joined(separator: "\n")
        switch stage {
        case .compaction:
            return "\(kept)\n\(constantMarker)"
        case .runtime, .persistence:
            let dropped = lines.count - maxLines
            return "\(kept)\n[tool result truncated: \(dropped) additional line(s) omitted]"
        }
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
        switch stage {
        case .compaction:
            return .object([
                "status": .string("metadata_truncated"),
                "placeholder": .string(placeholder),
            ])
        case .runtime, .persistence:
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
    }

    private static func jsonEqual(lhs: JSON, rhs: JSON) -> Bool {
        guard let left = try? JSONEncoder().encode(lhs),
              let right = try? JSONEncoder().encode(rhs) else {
            return false
        }
        return left == right
    }
}
