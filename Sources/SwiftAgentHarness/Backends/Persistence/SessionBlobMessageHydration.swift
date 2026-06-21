//
//  Resolve `blob://` image refs into in-memory bytes for UI and LLM wire encoding.
//

import Foundation
import SwiftAgentKit

enum SessionBlobMessageHydration {
    static let unavailableMarkerPrefix = "[attachment unavailable:"

    static func hydrateBlobImages(
        in messages: [Message],
        harness: (any HarnessSessionPersistence)?,
        conversationID: UUID? = nil
    ) -> [Message] {
        guard let harness else { return messages }
        return messages.map { hydrateBlobImages(in: $0, harness: harness, conversationID: conversationID) }
    }

    static func hydrateBlobImages(
        in message: Message,
        harness: any HarnessSessionPersistence,
        conversationID: UUID? = nil
    ) -> Message {
        guard !message.images.isEmpty else { return message }
        var copy = message
        var placeholders: [String] = []
        var hydratedImages: [Message.Image] = []
        for image in message.images {
            if image.imageData != nil {
                hydratedImages.append(image)
                continue
            }
            guard let blobId = SessionBlobImageRef.parsePath(image.path) else {
                hydratedImages.append(image)
                continue
            }
            if let data = try? harness.getBlob(blobId: blobId) {
                var hydrated = image
                hydrated.imageData = data
                if hydrated.thumbData == nil {
                    hydrated.thumbData = data
                }
                hydratedImages.append(hydrated)
            } else {
                placeholders.append(unavailableMarker(name: image.name))
            }
        }
        copy.images = hydratedImages
        if !placeholders.isEmpty {
            let suffix = placeholders.joined(separator: "\n")
            copy.content = copy.content.isEmpty ? suffix : copy.content + "\n" + suffix
        }
        return copy
    }

    static func unavailableMarker(name: String) -> String {
        "\(unavailableMarkerPrefix) \(name)]"
    }
}
