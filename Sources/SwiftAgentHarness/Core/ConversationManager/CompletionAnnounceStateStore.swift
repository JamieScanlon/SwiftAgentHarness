import Foundation

actor CompletionAnnounceStateStore {
    private var deliveredCorrelationKeys: Set<String> = []
    private var retryCountByAnnounceID: [UUID: Int] = [:]
    private var pendingByAnnounceID: [UUID: CompletionAnnouncePayload] = [:]

    func correlationKey(delegateHandleID: String, toolCallID: String) -> String {
        "\(delegateHandleID)|\(toolCallID)"
    }

    func markDelivered(_ announce: CompletionAnnouncePayload) {
        deliveredCorrelationKeys.insert(correlationKey(delegateHandleID: announce.delegateHandleID, toolCallID: announce.toolCallID))
        pendingByAnnounceID.removeValue(forKey: announce.announceID)
        retryCountByAnnounceID.removeValue(forKey: announce.announceID)
    }

    func hasDelivered(delegateHandleID: String, toolCallID: String) -> Bool {
        deliveredCorrelationKeys.contains(correlationKey(delegateHandleID: delegateHandleID, toolCallID: toolCallID))
    }

    func markPending(_ announce: CompletionAnnouncePayload) {
        pendingByAnnounceID[announce.announceID] = announce
    }

    func recordRetry(for announceID: UUID) -> Int {
        let next = (retryCountByAnnounceID[announceID] ?? 0) + 1
        retryCountByAnnounceID[announceID] = next
        return next
    }

    func pendingAnnouncements() -> [CompletionAnnouncePayload] {
        pendingByAnnounceID.values.sorted { $0.completedAt < $1.completedAt }
    }

    func clearPending(announceID: UUID) {
        pendingByAnnounceID.removeValue(forKey: announceID)
        retryCountByAnnounceID.removeValue(forKey: announceID)
    }
}
