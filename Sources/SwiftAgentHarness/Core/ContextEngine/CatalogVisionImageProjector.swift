import Foundation
import SwiftAgentKit

enum CatalogVisionImageProjector {
    static func apply(
        messages: [Message],
        catalog: [ConversationAttachmentDescriptor],
        effectiveDecisions: [ConversationAttachmentProjectionDecision],
        blobReader: AttachmentBlobReading?,
        conversationID: UUID,
        modelSupportsVision: Bool
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
        return messages.map { message in
            projectMessage(
                message,
                catalogByID: catalogByID,
                catalogByBlobID: catalogByBlobID,
                dispositionByAttachmentID: dispositionByAttachmentID,
                dispositionByName: dispositionByName,
                blobReader: blobReader,
                conversationID: conversationID,
                modelSupportsVision: modelSupportsVision
            )
        }
    }

    private static func projectMessage(
        _ message: Message,
        catalogByID: [UUID: ConversationAttachmentDescriptor],
        catalogByBlobID: [String: ConversationAttachmentDescriptor],
        dispositionByAttachmentID: [UUID: ConversationAttachmentProjectionDisposition],
        dispositionByName: [String: ConversationAttachmentProjectionDisposition],
        blobReader: AttachmentBlobReading?,
        conversationID: UUID,
        modelSupportsVision: Bool
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
                continue
            }
            let disposition = dispositionByAttachmentID[descriptor.id]
                ?? dispositionByName[descriptor.name]
                ?? dispositionByName[image.name]
                ?? .inline
            guard disposition == .inline, modelSupportsVision else {
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
            if projected.imageData != nil || SessionBlobImageRef.parsePath(projected.path) != nil {
                projectedImages.append(projected)
            }
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
