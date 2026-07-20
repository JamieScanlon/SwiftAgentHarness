import Foundation

enum ConversationAttachmentBlobAccessError: Error, Equatable, Sendable {
    case attachmentNotFoundInConversation(attachmentID: UUID)
    case missingBlobReference(attachmentID: UUID, attachmentName: String)
}

enum ConversationAttachmentBlobAccess {
    static func resolve(
        attachmentID: UUID,
        catalog: [ConversationAttachmentDescriptor]
    ) throws -> ConversationAttachmentDescriptor {
        guard let descriptor = catalog.first(where: { $0.id == attachmentID }) else {
            throw ConversationAttachmentBlobAccessError.attachmentNotFoundInConversation(attachmentID: attachmentID)
        }
        return descriptor
    }

    static func loadBytes(
        descriptor: ConversationAttachmentDescriptor,
        conversationID: UUID,
        harness: any HarnessSessionPersistence
    ) throws -> Data {
        guard let blobId = descriptor.blobId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !blobId.isEmpty else {
            throw ConversationAttachmentBlobAccessError.missingBlobReference(
                attachmentID: descriptor.id,
                attachmentName: descriptor.name
            )
        }
        return try harness.openReferencedDurableBlob(blobId: blobId, conversationID: conversationID)
    }
}

extension ConversationAttachmentBlobAccessError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .attachmentNotFoundInConversation(let attachmentID):
            return "attachment not found in this conversation: \(attachmentID.uuidString)"
        case .missingBlobReference(let attachmentID, let attachmentName):
            return "attachment \(attachmentName) (\(attachmentID.uuidString)) has no blob reference"
        }
    }
}
