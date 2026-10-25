import Foundation
import SwiftAgentKit

/// Stores a tool message's inline images as session blobs so the transcript records a `blob://` ref instead of
/// dropping the image. The in-memory message keeps its bytes; reloads hydrate them from the blob.
enum ToolMessageImageOffload {
    static func offload(_ message: Message, harness: any HarnessSessionPersistence) -> Message {
        guard message.role == .tool, message.images.contains(where: needsOffload) else { return message }
        var copy = message
        copy.images = message.images.map { image in
            guard needsOffload(image), let data = image.imageData else { return image }
            guard let ref = try? harness.putBlob(
                data: data,
                durability: .durable,
                originalName: image.name,
                mimeType: image.mediaType,
                trust: "unknown-party",
                ttlSeconds: nil,
                lane: .outbound
            ) else { return image }
            var stored = image
            stored.path = SessionBlobImageRef.path(for: ref.id)
            if stored.mediaType == nil { stored.mediaType = ref.mimeType }
            return stored
        }
        return copy
    }

    private static func needsOffload(_ image: Message.Image) -> Bool {
        image.imageData != nil && image.path == nil
    }
}
