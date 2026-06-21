//
//  Streaming generation lifecycle fields peeled from ``HarnessRuntimeSession`` (migration Slice C).
//

import Foundation

/// In-flight streaming orchestration task bookkeeping for ``HarnessRuntimeSession``.
struct ChatRuntimeLifecycle {
    var generationTask: Task<Void, Error>?
    /// Monotonic token so an older streaming task does not clear ``generationTask`` after a newer send supersedes it.
    var streamingGenerationSequence: UInt64 = 0
    /// Identifies the active streaming orchestration run for persistence / ``ModelConversation/currentRunID``.
    var currentStreamingRunID: UUID?
    /// Conversation id for the in-flight ``generationTask`` (send / revert / split path); cleared when the task completes.
    var activeStreamingConversationID: UUID?
    /// Anchor user message for the active run so cancellation can strip any partial assistant/tool tail durably.
    var activeAnchorUserMessageID: UUID?
    /// True after the first streamed fragment is observed for the active run.
    var isContentStreamingActive: Bool = false
}
