import Foundation

actor SubAgentCompletionService {
    private let completionAnnounceStore = CompletionAnnounceStateStore()
    private let maxRetryAttempts: Int
    private var conversationIDByCompletionHandleID: [String: UUID] = [:]
    private var conversationIDBySessionHandleID: [String: UUID] = [:]

    init(maxRetryAttempts: Int = 3) {
        self.maxRetryAttempts = maxRetryAttempts
    }

    var completionAnnounceMaxRetryAttempts: Int { maxRetryAttempts }

    func hasDelivered(delegateHandleID: String, toolCallID: String) async -> Bool {
        await completionAnnounceStore.hasDelivered(delegateHandleID: delegateHandleID, toolCallID: toolCallID)
    }

    func markDelivered(_ announce: CompletionAnnouncePayload) async {
        await completionAnnounceStore.markDelivered(announce)
    }

    func markPending(_ announce: CompletionAnnouncePayload) async {
        await completionAnnounceStore.markPending(announce)
    }

    func clearPending(announceID: UUID) async {
        await completionAnnounceStore.clearPending(announceID: announceID)
    }

    func pendingAnnouncements() async -> [CompletionAnnouncePayload] {
        await completionAnnounceStore.pendingAnnouncements()
    }

    func registerHandleOwnership(
        conversationID: UUID,
        sessionHandleID: String,
        completionHandleID: String?
    ) {
        conversationIDBySessionHandleID[sessionHandleID] = conversationID
        if let completionHandleID, !completionHandleID.isEmpty {
            conversationIDByCompletionHandleID[completionHandleID] = conversationID
        }
    }

    func resolveConversationIDForHandle(handleID: String, fallbackSessionHandleID: String?) -> UUID? {
        if let mapped = conversationIDByCompletionHandleID[handleID] {
            return mapped
        }
        if let fallbackSessionHandleID,
           let mapped = conversationIDBySessionHandleID[fallbackSessionHandleID] {
            return mapped
        }
        return nil
    }

    @discardableResult
    func recordRetry(for announceID: UUID) async -> Int {
        await completionAnnounceStore.recordRetry(for: announceID)
    }
}
