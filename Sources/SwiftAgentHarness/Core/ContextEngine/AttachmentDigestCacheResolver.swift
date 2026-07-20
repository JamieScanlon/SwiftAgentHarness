import Foundation
import SwiftAgentKit

struct AttachmentDigestCacheResolution: Sendable, Equatable {
    var digestPreviewByAttachmentID: [UUID: String]
    var newDigestCheckpoints: [AttachmentDigestCheckpointWire]
}

enum AttachmentDigestCacheResolver {
    static func resolve(
        catalog: [ConversationAttachmentDescriptor],
        decisions: [ConversationAttachmentProjectionDecision],
        configuration: AttachmentRepresentationMaterializerConfiguration,
        modelSupportsVision: Bool,
        blobReader: AttachmentBlobReading?,
        conversationID: UUID,
        events: [CachedConversationEvent],
        frontierEventID: Int?
    ) -> AttachmentDigestCacheResolution {
        let configFingerprint = AttachmentDigestCheckpointPolicy.configFingerprint(
            configuration: configuration,
            modelSupportsVision: modelSupportsVision
        )
        let catalogByID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        var hits: [UUID: String] = [:]
        var misses: [AttachmentDigestCheckpointWire] = []

        for decision in decisions where decision.disposition == .summarize {
            guard let descriptor = catalogByID[decision.attachmentID] else { continue }
            guard let contentHash = normalizedContentHash(descriptor.blobId) else { continue }

            if let cached = SuiteCheckpointSupport.latestValidAttachmentDigest(
                events: events,
                frontierEventID: frontierEventID,
                attachmentID: descriptor.id,
                contentHash: contentHash,
                configFingerprint: configFingerprint
            ) {
                hits[descriptor.id] = cached.wire.digestBody
                continue
            }

            guard let bytes = loadBytes(
                descriptor: descriptor,
                blobReader: blobReader,
                conversationID: conversationID
            ) else {
                continue
            }

            let digestBody = AttachmentDigestProducer.produce(
                descriptor: descriptor,
                bytes: bytes,
                modelSupportsVision: modelSupportsVision,
                configuration: configuration
            )
            hits[descriptor.id] = digestBody
            misses.append(
                AttachmentDigestCheckpointWire(
                    schemaVersion: AttachmentDigestCheckpointWire.currentSchemaVersion,
                    basedOnEventID: frontierEventID ?? 0,
                    attachmentID: descriptor.id,
                    contentHash: contentHash,
                    configFingerprint: configFingerprint,
                    digestBody: digestBody,
                    createdAt: Date()
                )
            )
        }

        return AttachmentDigestCacheResolution(
            digestPreviewByAttachmentID: hits,
            newDigestCheckpoints: misses
        )
    }

    private static func normalizedContentHash(_ blobId: String?) -> String? {
        let trimmed = blobId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func loadBytes(
        descriptor: ConversationAttachmentDescriptor,
        blobReader: AttachmentBlobReading?,
        conversationID: UUID
    ) -> Data? {
        guard let blobId = normalizedContentHash(descriptor.blobId),
              let blobReader else {
            return nil
        }
        do {
            return try blobReader.loadBytes(blobId, conversationID)
        } catch {
            return nil
        }
    }
}
