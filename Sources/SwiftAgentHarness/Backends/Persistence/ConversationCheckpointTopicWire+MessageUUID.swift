
import Foundation

extension ConversationCheckpointTopicEventWire {
    init(
        variant: Variant,
        conversationID: UUID,
        harnessCheckpointKind: String?,
        compactionCheckpointKind: String?,
        coveredRawMessageIDs messageIDs: [UUID]?,
        basedOnTailMessageID messageID: UUID?,
        invalidatedCheckpointKinds: [String]?
    ) {
        self.init(
            variant: variant,
            conversationID: conversationID,
            harnessCheckpointKind: harnessCheckpointKind,
            compactionCheckpointKind: compactionCheckpointKind,
            coveredRawMessageIDs: messageIDs.map(SessionEntryID.fromMessageUUIDs),
            basedOnTailMessageID: messageID.map(SessionEntryID.fromMessageUUID),
            invalidatedCheckpointKinds: invalidatedCheckpointKinds,
            summary: nil,
            firstKeptEntryID: nil,
            tokensBefore: nil,
            details: nil
        )
    }
}
