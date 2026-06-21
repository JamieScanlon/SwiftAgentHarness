import Foundation

/// Integration seam: optional reads of persisted harness checkpoints for context assembly or diagnostics.
enum HarnessCheckpointContextHooks {
    /// Latest persisted system-prompt assembly fingerprint, when valid for the given journal frontier.
    static func latestSystemPromptAssemblyFingerprint(
        events: [CachedConversationEvent],
        frontierEventID: Int?
    ) -> String? {
        guard let pair = SuiteCheckpointSupport.latestValidSystemPromptAssembly(
            events: events,
            frontierEventID: frontierEventID
        ) else { return nil }
        return pair.wire.assemblyFingerprint
    }
}
