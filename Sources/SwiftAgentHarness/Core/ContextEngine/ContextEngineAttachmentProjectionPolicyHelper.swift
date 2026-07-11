import CryptoKit
import Foundation
import SwiftAgentKit

enum ContextEngineAttachmentProjectionPolicyHelper {
    static func applyingDeterministicHygiene(
        messages: [Message],
        policy: ContextCompactionAttachmentDocumentHygienePolicy?
    ) -> [Message] {
        guard let policy, policy.enabled else { return messages }
        return messages.map { message in
            var copy = message
            if policy.documentCharacterThreshold > 0,
               copy.content.count > policy.documentCharacterThreshold,
               isLikelyDocumentLikeContent(copy.content) {
                copy.content = policy.documentPlaceholder
            }
            if policy.maxImagesPerMessage >= 0, copy.images.count > policy.maxImagesPerMessage {
                copy.images = Array(copy.images.prefix(policy.maxImagesPerMessage))
                if !policy.imagePlaceholder.isEmpty, !copy.content.contains(policy.imagePlaceholder) {
                    copy.content = copy.content.isEmpty
                        ? policy.imagePlaceholder
                        : "\(copy.content)\n\n\(policy.imagePlaceholder)"
                }
            }
            return copy
        }
    }

    static func isLikelyDocumentLikeContent(_ content: String) -> Bool {
        let lowered = content.lowercased()
        if lowered.contains("<document>") || lowered.contains("attachment:") {
            return true
        }
        if lowered.contains("```") {
            return true
        }
        return content.split(separator: "\n").count >= 40
    }

    static func resolveAttachmentProjection(
        catalog: [ConversationAttachmentDescriptor],
        modelSupportsVision: Bool?,
        policy: ContextEngineAttachmentProjectionPolicyInput?
    ) -> ContextEngineAttachmentProjectionArtifact? {
        guard let policy, policy.enabled, !catalog.isEmpty else { return nil }
        let decisions = catalog.map { descriptor in
            decision(
                for: descriptor,
                modelSupportsVision: modelSupportsVision ?? false,
                policy: policy
            )
        }
        guard !decisions.isEmpty else { return nil }
        let canonical = decisions.map {
            "\($0.attachmentID.uuidString)|\($0.disposition.rawValue)|\($0.reason)"
        }.sorted().joined(separator: ";")
        let fingerprintSource = "\(policy.inlineByteLimit)|\(policy.summarizeByteLimit)|\(modelSupportsVision == true ? 1 : 0)|\(canonical)"
        let projectionFingerprint = SHA256.hash(data: Data(fingerprintSource.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return ContextEngineAttachmentProjectionArtifact(
            projectionFingerprint: projectionFingerprint,
            decisions: decisions,
            materializedBlocks: []
        )
    }

    static func resolveAttachmentProjectionArtifact(
        catalog: [ConversationAttachmentDescriptor],
        modelSupportsVision: Bool?,
        policy: ContextEngineAttachmentProjectionPolicyInput?,
        blobReader: AttachmentBlobReading?,
        conversationID: UUID
    ) -> ContextEngineAttachmentProjectionArtifact? {
        guard let policy, policy.enabled, !catalog.isEmpty else { return nil }
        let decisions = catalog.map { descriptor in
            decision(
                for: descriptor,
                modelSupportsVision: modelSupportsVision ?? false,
                policy: policy
            )
        }
        guard !decisions.isEmpty else { return nil }
        let materializedBlocks = AttachmentRepresentationMaterializer.materialize(
            decisions: decisions,
            catalog: catalog,
            modelSupportsVision: modelSupportsVision ?? false,
            blobReader: blobReader,
            conversationID: conversationID,
            configuration: AttachmentRepresentationMaterializerConfiguration(
                inlineByteLimit: policy.inlineByteLimit
            )
        )
        let canonical = decisions.map {
            "\($0.attachmentID.uuidString)|\($0.disposition.rawValue)|\($0.reason)"
        }.sorted().joined(separator: ";")
        let materializedCanonical = materializedBlocks.map {
            "\($0.attachmentID.uuidString)|\(sha256Hex($0.body))"
        }.sorted().joined(separator: ";")
        let fingerprintSource = "\(policy.inlineByteLimit)|\(policy.summarizeByteLimit)|\(modelSupportsVision == true ? 1 : 0)|\(canonical)|\(materializedCanonical)"
        let projectionFingerprint = sha256Hex(fingerprintSource)
        return ContextEngineAttachmentProjectionArtifact(
            projectionFingerprint: projectionFingerprint,
            decisions: decisions,
            materializedBlocks: materializedBlocks
        )
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func decision(
        for descriptor: ConversationAttachmentDescriptor,
        modelSupportsVision: Bool,
        policy: ContextEngineAttachmentProjectionPolicyInput
    ) -> ConversationAttachmentProjectionDecision {
        let normalizedKind = descriptor.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let byteSize = descriptor.byteSize ?? 0
        let isImage = normalizedKind == "image" || (descriptor.mimeType?.lowercased().hasPrefix("image/") == true)
        let disposition: ConversationAttachmentProjectionDisposition
        let reason: String
        if isImage && !modelSupportsVision {
            disposition = .summarize
            reason = "vision_unsupported"
        } else if byteSize > 0, byteSize <= policy.inlineByteLimit {
            disposition = .inline
            reason = "within_inline_budget"
        } else if byteSize == 0 || byteSize <= policy.summarizeByteLimit {
            disposition = .summarize
            reason = byteSize == 0 ? "unknown_size" : "within_summary_budget"
        } else {
            disposition = .searchOnly
            reason = "over_budget"
        }
        return ConversationAttachmentProjectionDecision(
            attachmentID: descriptor.id,
            attachmentName: descriptor.name,
            attachmentKind: descriptor.kind,
            disposition: disposition,
            reason: reason
        )
    }
}
