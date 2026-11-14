import Foundation
import SwiftAgentKit

/// Stores a tool message's inline images as session blobs so the transcript records a `blob://` ref instead of
/// dropping the image. The in-memory message keeps its bytes; reloads hydrate them from the blob.
enum ToolMessageImageOffload {
    static func offload(_ message: Message, harness: any HarnessSessionPersistence) -> Message {
        offload(message, harness: harness, ephemeralUntil: nil).message
    }

    /// With `ephemeralUntil`, images go to the ephemeral lane expiring then instead of the durable lane, and the
    /// stored blob ids are returned so their owner can move the expiry later.
    static func offload(
        _ message: Message,
        harness: any HarnessSessionPersistence,
        ephemeralUntil expiresAt: Date?,
        now: Date = Date()
    ) -> (message: Message, blobIDs: [String]) {
        guard message.role == .tool, message.images.contains(where: needsOffload) else { return (message, []) }
        var copy = message
        var blobIDs: [String] = []
        copy.images = message.images.map { image in
            guard needsOffload(image), let data = image.imageData else { return image }
            let ttlSeconds = expiresAt.map { max(1, Int($0.timeIntervalSince(now).rounded(.up))) }
            guard let ref = try? harness.putBlob(
                data: data,
                durability: ttlSeconds == nil ? .durable : .ephemeral,
                originalName: image.name,
                mimeType: image.mediaType,
                trust: "unknown-party",
                ttlSeconds: ttlSeconds,
                lane: .outbound
            ) else { return image }
            blobIDs.append(ref.id)
            var stored = image
            stored.path = SessionBlobImageRef.path(for: ref.id)
            if stored.mediaType == nil { stored.mediaType = ref.mimeType }
            return stored
        }
        return (copy, blobIDs)
    }

    private static func needsOffload(_ image: Message.Image) -> Bool {
        image.imageData != nil && image.path == nil
    }
}
