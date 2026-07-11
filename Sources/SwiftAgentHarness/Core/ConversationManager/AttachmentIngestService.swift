import Foundation
import SwiftAgentKit

struct AttachmentIngestRef: Sendable, Equatable {
    let attachmentId: UUID
    let blobId: String
    let name: String
    let kind: String
    let mimeType: String?
    let trust: String?
}

struct AttachmentIngestResult: Sendable, Equatable {
    let refOnlyImages: [Message.Image]
    let ingestRefs: [AttachmentIngestRef]
}

enum AttachmentIngestService {
    static func ingestImages(
        conversationID: UUID,
        images: [Message.Image],
        harness: any HarnessSessionPersistence,
        conversationManager: ConversationManager,
        attachmentTrustRaw: String?,
        addedBy: ConversationAttachmentAddedBy
    ) throws -> AttachmentIngestResult {
        guard !images.isEmpty else {
            return AttachmentIngestResult(refOnlyImages: [], ingestRefs: [])
        }
        var refOnlyImages: [Message.Image] = []
        var ingestRefs: [AttachmentIngestRef] = []
        refOnlyImages.reserveCapacity(images.count)
        ingestRefs.reserveCapacity(images.count)

        let normalizedTrust = AttachmentInputTrustCodec.sanitizedInputTrustRaw(attachmentTrustRaw)
            ?? AttachmentProvenancePolicy.defaultTrustRaw(for: addedBy)

        for image in images {
            guard let resolved = try? resolveBlob(
                for: image,
                harness: harness,
                trust: normalizedTrust
            ) else {
                continue
            }
            let attachmentId = try resolveAttachmentID(
                conversationID: conversationID,
                blobId: resolved.blobId,
                name: resolved.name,
                conversationManager: conversationManager,
                harness: harness,
                attachmentTrustRaw: normalizedTrust,
                addedBy: addedBy,
                filePath: resolved.blobPath
            )
            let ingestRef = AttachmentIngestRef(
                attachmentId: attachmentId,
                blobId: resolved.blobId,
                name: resolved.name,
                kind: "image",
                mimeType: resolved.mimeType,
                trust: normalizedTrust
            )
            ingestRefs.append(ingestRef)
            refOnlyImages.append(
                Message.Image(
                    name: resolved.name,
                    path: resolved.blobPath
                )
            )
        }
        return AttachmentIngestResult(refOnlyImages: refOnlyImages, ingestRefs: ingestRefs)
    }

    private struct ResolvedBlob: Sendable {
        let blobId: String
        let blobPath: String
        let name: String
        let mimeType: String?
    }

    private static func resolveBlob(
        for image: Message.Image,
        harness: any HarnessSessionPersistence,
        trust: String
    ) throws -> ResolvedBlob {
        if let blobId = SessionBlobImageRef.parsePath(image.path) {
            let promoted = try promoteIfNeeded(blobId: blobId, harness: harness)
            let stat = try? harness.statBlob(blobId: promoted.id)
            let name = sanitizedName(image.name, fallback: stat?.originalName ?? promoted.id)
            return ResolvedBlob(
                blobId: promoted.id,
                blobPath: SessionBlobImageRef.path(for: promoted.id),
                name: name,
                mimeType: stat?.mimeType
            )
        }
        if let data = image.imageData ?? image.thumbData {
            let ref = try harness.putBlob(
                data: data,
                durability: .durable,
                originalName: sanitizedName(image.name, fallback: "attachment"),
                mimeType: nil,
                trust: trust,
                ttlSeconds: nil,
                lane: .inbound
            )
            return ResolvedBlob(
                blobId: ref.id,
                blobPath: SessionBlobImageRef.path(for: ref.id),
                name: sanitizedName(image.name, fallback: ref.originalName ?? ref.id),
                mimeType: ref.mimeType
            )
        }
        throw SessionPersistenceError.transcriptPayloadInvalid(
            reason: "attachment ingest requires blob:// path or image bytes"
        )
    }

    private static func promoteIfNeeded(
        blobId: String,
        harness: any HarnessSessionPersistence
    ) throws -> SessionBlobRef {
        let stat = try harness.statBlob(blobId: blobId)
        if stat.durability == .durable {
            return stat
        }
        return try harness.promoteBlob(blobId: blobId)
    }

    private static func resolveAttachmentID(
        conversationID: UUID,
        blobId: String,
        name: String,
        conversationManager: ConversationManager,
        harness: any HarnessSessionPersistence,
        attachmentTrustRaw: String,
        addedBy: ConversationAttachmentAddedBy,
        filePath: String
    ) throws -> UUID {
        if let existing = conversationManager.catalogAttachmentID(forBlobId: blobId, conversationID: conversationID) {
            return existing
        }
        let resourceID = UUID()
        let resource = CachedResource(
            id: resourceID,
            name: name,
            resourceDescription: nil,
            fileType: "image",
            filePath: filePath,
            thumbnailPath: nil
        )
        try conversationManager.mergeAttachmentsCatalog(
            conversationID: conversationID,
            resources: [resource],
            attachmentTrustRaw: attachmentTrustRaw,
            harness: harness
        )
        return conversationManager.catalogAttachmentID(forBlobId: blobId, conversationID: conversationID) ?? resourceID
    }

    private static func sanitizedName(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return fallback }
        return AttachmentProvenancePolicy.sanitizedAttachmentName(trimmed)
    }
}
