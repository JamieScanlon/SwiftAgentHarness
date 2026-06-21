//
//  Small façade for communication-layer glue: map lagging / snapshot paths to harness transcript sequence
//  without importing persistence into topic hubs.
//

import Foundation

enum TranscriptReplayCoordinator {
    static func latestTranscriptSequenceIfAvailable(
        persistence: any SessionBackend,
        conversationID: UUID
    ) -> Int? {
        try? persistence.latestTranscriptSequence(conversationID: conversationID)
    }
}
