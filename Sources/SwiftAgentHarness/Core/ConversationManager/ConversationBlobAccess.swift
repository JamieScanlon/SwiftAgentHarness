import Foundation
import SwiftAgentKit

/// A blob a conversation references, as a surface fetches it.
public struct ConversationBlob: Sendable, Equatable {
    public var data: Data
    public var mediaType: String
    /// The blob id, which is the SHA-256 of the bytes.
    public var contentHash: String

    public init(data: Data, mediaType: String, contentHash: String) {
        self.data = data
        self.mediaType = mediaType
        self.contentHash = contentHash
    }
}

/// Which blobs a conversation references. A surface may fetch only those, so blob ids can't be probed across
/// conversations.
enum ConversationBlobAccess {
    /// The normalized id for a bare id or a `blob://` ref, or `nil` when it isn't a blob id at all.
    static func normalizedID(_ raw: String) -> String? {
        let id = SessionBlobImageRef.parsePath(raw) ?? SessionBlobStore.normalizeBlobId(raw)
        return SessionBlobStore.isValidBlobId(id) ? id : nil
    }

    static func references(_ blobID: String, attachments: [ConversationAttachmentDescriptor], messages: [Message]) -> Bool {
        attachments.contains { $0.blobId.flatMap(normalizedID) == blobID }
            || messages.contains { $0.images.contains { SessionBlobImageRef.parsePath($0.path) == blobID } }
    }

    static func load(_ blobID: String, from harness: any HarnessSessionPersistence) -> ConversationBlob? {
        guard let data = try? harness.getBlob(blobId: blobID) else { return nil }
        let mediaType = (try? harness.statBlob(blobId: blobID))?.mimeType ?? SessionBlobMIME.sniff(data: data, hint: nil)
        return ConversationBlob(data: data, mediaType: mediaType, contentHash: blobID)
    }
}
