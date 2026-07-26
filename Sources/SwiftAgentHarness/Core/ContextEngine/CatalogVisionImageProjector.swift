import Foundation
import Logging
import SwiftAgentKit

enum CatalogVisionImageProjector {
    struct SanitizationPolicy: Sendable {
        let maxPixelDimension: Int
        let maxBytes: Int

        static let `default` = SanitizationPolicy(
            maxPixelDimension: 1_200,
            maxBytes: 5_000_000
        )

        init(maxPixelDimension: Int, maxBytes: Int) {
            self.maxPixelDimension = max(0, maxPixelDimension)
            self.maxBytes = max(0, maxBytes)
        }

        init(from policy: ContextEngineAttachmentProjectionPolicyInput) {
            self.init(
                maxPixelDimension: policy.imageMaxPixelDimension,
                maxBytes: Int(clamping: policy.imageInlineByteLimit)
            )
        }
    }

    static func apply(
        messages: [Message],
        catalog: [ConversationAttachmentDescriptor],
        effectiveDecisions: [ConversationAttachmentProjectionDecision],
        blobReader: AttachmentBlobReading?,
        conversationID: UUID,
        modelSupportsVision: Bool,
        sanitizationPolicy: SanitizationPolicy = .default,
        imageProcessor: ImageProcessing = DefaultImageProcessor(),
        logger: Logger? = nil
    ) -> [Message] {
        guard !catalog.isEmpty else { return messages }
        let catalogByID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        let catalogByBlobID = Dictionary(
            uniqueKeysWithValues: catalog.compactMap { descriptor -> (String, ConversationAttachmentDescriptor)? in
                guard let blobId = descriptor.blobId?.lowercased() else { return nil }
                return (blobId, descriptor)
            }
        )
        let dispositionByAttachmentID = Dictionary(
            uniqueKeysWithValues: effectiveDecisions.map { ($0.attachmentID, $0.disposition) }
        )
        let dispositionByName = Dictionary(
            uniqueKeysWithValues: effectiveDecisions.map { ($0.attachmentName, $0.disposition) }
        )
        let reasonByAttachmentID = Dictionary(
            uniqueKeysWithValues: effectiveDecisions.map { ($0.attachmentID, $0.reason) }
        )
        return messages.map { message in
            projectMessage(
                message,
                catalogByID: catalogByID,
                catalogByBlobID: catalogByBlobID,
                dispositionByAttachmentID: dispositionByAttachmentID,
                dispositionByName: dispositionByName,
                reasonByAttachmentID: reasonByAttachmentID,
                blobReader: blobReader,
                conversationID: conversationID,
                modelSupportsVision: modelSupportsVision,
                sanitizationPolicy: sanitizationPolicy,
                imageProcessor: imageProcessor,
                logger: logger
            )
        }
    }

    private static func projectMessage(
        _ message: Message,
        catalogByID: [UUID: ConversationAttachmentDescriptor],
        catalogByBlobID: [String: ConversationAttachmentDescriptor],
        dispositionByAttachmentID: [UUID: ConversationAttachmentProjectionDisposition],
        dispositionByName: [String: ConversationAttachmentProjectionDisposition],
        reasonByAttachmentID: [UUID: String],
        blobReader: AttachmentBlobReading?,
        conversationID: UUID,
        modelSupportsVision: Bool,
        sanitizationPolicy: SanitizationPolicy,
        imageProcessor: ImageProcessing,
        logger: Logger?
    ) -> Message {
        guard !message.images.isEmpty else { return message }
        var copy = message
        var projectedImages: [Message.Image] = []
        projectedImages.reserveCapacity(message.images.count)
        for image in message.images {
            guard let descriptor = resolveDescriptor(
                for: image,
                catalogByID: catalogByID,
                catalogByBlobID: catalogByBlobID
            ) else {
                logger?.debug(
                    "[CatalogVisionImageProjector] dropping image name=\(image.name) reason=catalog_unresolved"
                )
                continue
            }
            let disposition = dispositionByAttachmentID[descriptor.id]
                ?? dispositionByName[descriptor.name]
                ?? dispositionByName[image.name]
                ?? .inline
            let decisionReason = reasonByAttachmentID[descriptor.id] ?? "unspecified"
            guard disposition == .inline, modelSupportsVision else {
                let reason: String
                if !modelSupportsVision {
                    reason = "vision_unsupported"
                } else {
                    reason = "disposition=\(disposition.rawValue)|\(decisionReason)"
                }
                logger?.debug(
                    "[CatalogVisionImageProjector] dropping image name=\(descriptor.name) reason=\(reason)"
                )
                continue
            }
            var projected = image
            projected.name = descriptor.name
            if projected.imageData == nil, let blobId = descriptor.blobId, let blobReader {
                if let data = try? blobReader.loadBytes(blobId, conversationID) {
                    projected.imageData = data
                    if projected.thumbData == nil {
                        projected.thumbData = data
                    }
                }
            }
            guard let rawData = projected.imageData else {
                if SessionBlobImageRef.parsePath(projected.path) != nil {
                    projectedImages.append(projected)
                } else {
                    logger?.debug(
                        "[CatalogVisionImageProjector] dropping image name=\(descriptor.name) reason=missing_bytes"
                    )
                }
                continue
            }
            guard let sanitized = AttachmentVisionImageSanitizer.sanitize(
                rawData,
                maxPixelDimension: sanitizationPolicy.maxPixelDimension,
                maxBytes: sanitizationPolicy.maxBytes,
                processor: imageProcessor
            ) else {
                logger?.debug(
                    "[CatalogVisionImageProjector] dropping image name=\(descriptor.name) reason=sanitize_failed bytes=\(rawData.count)"
                )
                continue
            }
            projected.imageData = sanitized
            if projected.thumbData == nil || projected.thumbData == rawData {
                projected.thumbData = sanitized
            }
            projectedImages.append(projected)
        }
        copy.images = projectedImages
        return copy
    }

    private static func resolveDescriptor(
        for image: Message.Image,
        catalogByID: [UUID: ConversationAttachmentDescriptor],
        catalogByBlobID: [String: ConversationAttachmentDescriptor]
    ) -> ConversationAttachmentDescriptor? {
        if let blobId = SessionBlobImageRef.parsePath(image.path)?.lowercased(),
           let descriptor = catalogByBlobID[blobId] {
            return descriptor
        }
        if let byName = catalogByID.values.first(where: { $0.name == image.name }) {
            return byName
        }
        return nil
    }
}
