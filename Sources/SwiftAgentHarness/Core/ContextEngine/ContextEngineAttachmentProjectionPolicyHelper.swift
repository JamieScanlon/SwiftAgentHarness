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
               isLikelyDocumentLikeContent(copy.content),
               !DocumentHygieneReceiptEnvelope.isReceiptEnvelope(
                   copy.content,
                   marker: policy.documentPlaceholder
               ) {
                copy.content = DocumentHygieneReceiptEnvelope.make(
                    originalContent: copy.content,
                    messageID: copy.id,
                    marker: policy.documentPlaceholder,
                    previewMaxBytes: policy.documentPreviewMaxBytes
                )
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
        return content.split(separator: "\n").count >= 40
    }

    static func resolveAttachmentProjection(
        catalog: [ConversationAttachmentDescriptor],
        modelSupportsVision: Bool?,
        policy: ContextEngineAttachmentProjectionPolicyInput?
    ) -> ContextEngineAttachmentProjectionArtifact? {
        resolveAttachmentProjectionArtifact(
            catalog: catalog,
            modelSupportsVision: modelSupportsVision,
            policy: policy,
            blobReader: nil,
            conversationID: UUID(),
            messages: [],
            priorAttachmentProjection: nil,
            pendingCacheBreakEvents: [],
            events: [],
            frontierEventID: nil
        )
    }

    static func resolveAttachmentProjectionArtifact(
        catalog: [ConversationAttachmentDescriptor],
        modelSupportsVision: Bool?,
        policy: ContextEngineAttachmentProjectionPolicyInput?,
        blobReader: AttachmentBlobReading?,
        conversationID: UUID,
        messages: [Message] = [],
        priorAttachmentProjection: ContextEngineAttachmentProjectionArtifact? = nil,
        pendingCacheBreakEvents: Set<CacheBreakEventReason> = [],
        events: [CachedConversationEvent] = [],
        frontierEventID: Int? = nil
    ) -> ContextEngineAttachmentProjectionArtifact? {
        guard let policy, policy.enabled, !catalog.isEmpty else { return nil }
        let supportsVision = modelSupportsVision ?? false
        let accessIndex = AttachmentAccessIndexBuilder.build(messages: messages, catalog: catalog)
        let naturalDecisions = catalog.map {
            AttachmentRecencyProjectionPolicy.naturalDecision(
                for: $0,
                modelSupportsVision: supportsVision,
                policy: policy
            )
        }
        var targetDecisions = AttachmentRecencyProjectionPolicy.applyRecencyDemotion(
            decisions: naturalDecisions,
            catalog: catalog,
            accessIndex: accessIndex,
            recencyPolicy: policy.recencyPolicy
        )
        targetDecisions = AttachmentRecencyProjectionPolicy.applyPerKindInlineCaps(
            decisions: targetDecisions,
            catalog: catalog,
            accessIndex: accessIndex,
            recencyPolicy: policy.recencyPolicy
        )
        let coordinated = AttachmentRungCoordinator.coordinate(
            catalog: catalog,
            targetDecisions: targetDecisions,
            priorDecisions: priorAttachmentProjection?.decisions,
            naturalDecisions: naturalDecisions,
            accessIndex: accessIndex,
            pendingBreakEvents: pendingCacheBreakEvents,
            recencyPolicy: policy.recencyPolicy
        )
        let effectiveDecisions = coordinated.effective
        guard !effectiveDecisions.isEmpty else { return nil }
        let materializerConfiguration = AttachmentRepresentationMaterializerConfiguration(
            inlineByteLimit: policy.inlineByteLimit
        )
        let digestCache = AttachmentDigestCacheResolver.resolve(
            catalog: catalog,
            decisions: effectiveDecisions,
            configuration: materializerConfiguration,
            modelSupportsVision: supportsVision,
            blobReader: blobReader,
            conversationID: conversationID,
            events: events,
            frontierEventID: frontierEventID
        )
        let materializedBlocks = AttachmentRepresentationMaterializer.materialize(
            decisions: effectiveDecisions,
            catalog: catalog,
            modelSupportsVision: supportsVision,
            blobReader: blobReader,
            conversationID: conversationID,
            configuration: materializerConfiguration,
            digestPreviewByAttachmentID: digestCache.digestPreviewByAttachmentID
        )
        let projectionFingerprint = fingerprint(
            policy: policy,
            modelSupportsVision: supportsVision,
            effectiveDecisions: effectiveDecisions,
            targetDecisions: coordinated.target,
            materializedBlocks: materializedBlocks,
            accessWatermarkTurnIndex: accessIndex.currentTurnIndex
        )
        return ContextEngineAttachmentProjectionArtifact(
            projectionFingerprint: projectionFingerprint,
            decisions: effectiveDecisions,
            targetDecisions: coordinated.target,
            materializedBlocks: materializedBlocks,
            accessWatermarkTurnIndex: accessIndex.currentTurnIndex,
            newDigestCheckpoints: digestCache.newDigestCheckpoints
        )
    }

    private static func fingerprint(
        policy: ContextEngineAttachmentProjectionPolicyInput,
        modelSupportsVision: Bool,
        effectiveDecisions: [ConversationAttachmentProjectionDecision],
        targetDecisions: [ConversationAttachmentProjectionDecision],
        materializedBlocks: [AttachmentMaterializedBlock],
        accessWatermarkTurnIndex: Int
    ) -> String {
        let effectiveCanonical = effectiveDecisions.map {
            "\($0.attachmentID.uuidString)|\($0.disposition.rawValue)|\($0.reason)"
        }.sorted().joined(separator: ";")
        let targetCanonical = targetDecisions.map {
            "\($0.attachmentID.uuidString)|\($0.disposition.rawValue)|\($0.reason)"
        }.sorted().joined(separator: ";")
        let materializedCanonical = materializedBlocks.map {
            "\($0.attachmentID.uuidString)|\(sha256Hex($0.body))"
        }.sorted().joined(separator: ";")
        let recency = policy.recencyPolicy
        let recencyCanonical = [
            recency.enabled ? "1" : "0",
            String(recency.hotAccessTurns),
            String(recency.demoteInlineAfterTurns),
            String(recency.demoteDigestAfterTurns),
            String(recency.hysteresisTurnMargin),
            String(recency.maxInlineImages),
            String(recency.promoteHotSetOnCompaction),
        ].joined(separator: "|")
        let fingerprintSource = [
            String(policy.inlineByteLimit),
            String(policy.summarizeByteLimit),
            String(policy.imageInlineByteLimit),
            String(policy.imageMaxPixelDimension),
            modelSupportsVision ? "1" : "0",
            recencyCanonical,
            String(accessWatermarkTurnIndex),
            effectiveCanonical,
            targetCanonical,
            materializedCanonical,
        ].joined(separator: "||")
        return sha256Hex(fingerprintSource)
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
