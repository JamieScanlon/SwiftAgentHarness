import Foundation
import SwiftAgentKit

actor CompletionAnnounceStateStore {
    private var deliveredCorrelationKeys: Set<String> = []
    private var inProgressCorrelationKeys: Set<String> = []
    private var retryCountByAnnounceID: [UUID: Int] = [:]
    private var pendingByAnnounceID: [UUID: CompletionAnnouncePayload] = [:]
    /// Retained only when an announcement's content failed to reach the transcript. Without it a
    /// retry can re-publish the lifecycle event but has no payload to re-append.
    private var pendingNotificationByAnnounceID: [UUID: Message] = [:]

    func correlationKey(delegateHandleID: String, toolCallID: String) -> String {
        "\(delegateHandleID)|\(toolCallID)"
    }

    func tryBeginDelivery(delegateHandleID: String, toolCallID: String) -> Bool {
        let key = correlationKey(delegateHandleID: delegateHandleID, toolCallID: toolCallID)
        if deliveredCorrelationKeys.contains(key) || inProgressCorrelationKeys.contains(key) {
            return false
        }
        inProgressCorrelationKeys.insert(key)
        return true
    }

    func markDelivered(_ announce: CompletionAnnouncePayload) {
        let key = correlationKey(delegateHandleID: announce.delegateHandleID, toolCallID: announce.toolCallID)
        deliveredCorrelationKeys.insert(key)
        inProgressCorrelationKeys.remove(key)
        pendingByAnnounceID.removeValue(forKey: announce.announceID)
        pendingNotificationByAnnounceID.removeValue(forKey: announce.announceID)
        retryCountByAnnounceID.removeValue(forKey: announce.announceID)
    }

    func hasDelivered(delegateHandleID: String, toolCallID: String) -> Bool {
        deliveredCorrelationKeys.contains(correlationKey(delegateHandleID: delegateHandleID, toolCallID: toolCallID))
    }

    func markPending(_ announce: CompletionAnnouncePayload, notification: Message? = nil) {
        inProgressCorrelationKeys.remove(
            correlationKey(delegateHandleID: announce.delegateHandleID, toolCallID: announce.toolCallID)
        )
        pendingByAnnounceID[announce.announceID] = announce
        if let notification {
            pendingNotificationByAnnounceID[announce.announceID] = notification
        }
    }

    func pendingNotification(announceID: UUID) -> Message? {
        pendingNotificationByAnnounceID[announceID]
    }

    /// Seeds the counter from a persisted announce row so a restart resumes an announcement's
    /// retry budget instead of handing it a fresh one.
    func restoreRetryCount(_ count: Int, for announceID: UUID) {
        guard count > 0 else { return }
        retryCountByAnnounceID[announceID] = max(retryCountByAnnounceID[announceID] ?? 0, count)
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
        pendingNotificationByAnnounceID.removeValue(forKey: announceID)
        retryCountByAnnounceID.removeValue(forKey: announceID)
    }
}
