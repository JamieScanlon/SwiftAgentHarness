import Foundation

/// Loads attachment bytes and filesystem paths for CE materialization at assemble time.
public struct AttachmentBlobReading: Sendable {
    public var loadBytes: @Sendable (String, UUID) throws -> Data?
    public var blobPath: @Sendable (String) throws -> URL?

    public init(
        loadBytes: @escaping @Sendable (String, UUID) throws -> Data?,
        blobPath: @escaping @Sendable (String) throws -> URL?
    ) {
        self.loadBytes = loadBytes
        self.blobPath = blobPath
    }

    static func harness(
        _ harness: any HarnessSessionPersistence,
        conversationID: UUID
    ) -> AttachmentBlobReading {
        AttachmentBlobReading(
            loadBytes: { blobId, convID in
                try harness.openReferencedDurableBlob(blobId: blobId, conversationID: convID)
            },
            blobPath: { blobId in
                try harness.blobPath(blobId: blobId)
            }
        )
    }
}
