import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("SubAgent completion service")
struct SubAgentCompletionServiceTests {
    @Test("registerHandleOwnership resolves completion and session handles")
    func registerHandleOwnershipResolves() async {
        let service = SubAgentCompletionService()
        let conversationID = UUID()
        await service.registerHandleOwnership(
            conversationID: conversationID,
            sessionHandleID: "session-1",
            completionHandleID: "completion-1"
        )

        let byCompletion = await service.resolveConversationIDForHandle(
            handleID: "completion-1",
            fallbackSessionHandleID: nil
        )
        let bySession = await service.resolveConversationIDForHandle(
            handleID: "unknown",
            fallbackSessionHandleID: "session-1"
        )
        #expect(byCompletion == conversationID)
        #expect(bySession == conversationID)
    }

    @Test("A pending announcement retains the payload that failed, and drops it once resolved")
    func pendingRetainsUndeliveredPayload() async {
        let service = SubAgentCompletionService()
        let announce = CompletionAnnouncePayload(
            delegateHandleID: "handle-1",
            toolCallID: "call-1",
            conversationID: UUID(),
            lifecycleID: "handle-1",
            status: .done,
            completedAt: Date(),
            source: "test"
        )
        let notification = Message(
            id: UUID(),
            role: .user,
            content: "<task-notification>…</task-notification>",
            timestamp: Date()
        )

        // Without the retained payload a retry can only re-publish the lifecycle event, which can
        // never recover a result whose content is the thing that failed to land.
        await service.markPending(announce, notification: notification)
        #expect(await service.pendingNotification(announceID: announce.announceID)?.id == notification.id)

        await service.markDelivered(announce)
        #expect(await service.pendingNotification(announceID: announce.announceID) == nil)
    }

    @Test("A pending announcement whose content landed retains no payload")
    func pendingWithoutPayloadRetainsNothing() async {
        let service = SubAgentCompletionService()
        let announce = CompletionAnnouncePayload(
            delegateHandleID: "handle-2",
            toolCallID: "call-2",
            conversationID: UUID(),
            lifecycleID: "handle-2",
            status: .done,
            completedAt: Date(),
            source: "test"
        )
        // Only the unresolved half is retained, so a large delegate report is not held for a retry
        // that has nothing left to deliver.
        await service.markPending(announce)
        #expect(await service.pendingNotification(announceID: announce.announceID) == nil)
        #expect(await service.pendingAnnouncements().count == 1)
    }

    @Test("Delivery is only claimed when both channels carried the announcement")
    func deliveryStateRequiresContentAndRuntime() {
        #expect(
            SubAgentCompletionRuntimeService.resolvedDeliveryState(
                runtimePublished: true,
                contentDelivered: true
            ) == "delivered"
        )
        // The failure that hid a dropped background result for two runs: the lifecycle event
        // published, so it recorded `delivered` while the payload never reached the transcript.
        // A false `delivered` is consulted by `hasPersistedCompletionAnnounceMarker`, which would
        // then suppress re-delivery permanently.
        #expect(
            SubAgentCompletionRuntimeService.resolvedDeliveryState(
                runtimePublished: true,
                contentDelivered: false
            ) == "pending"
        )
        #expect(
            SubAgentCompletionRuntimeService.resolvedDeliveryState(
                runtimePublished: false,
                contentDelivered: true
            ) == "pending"
        )
        #expect(
            SubAgentCompletionRuntimeService.resolvedDeliveryState(
                runtimePublished: false,
                contentDelivered: false
            ) == "pending"
        )
    }

    @Test("delivery state transitions keep dedupe semantics")
    func deliveryStateTransitions() async {
        let service = SubAgentCompletionService()
        let payload = CompletionAnnouncePayload(
            delegateHandleID: "delegate-1",
            toolCallID: "tool-call-1",
            conversationID: UUID(),
            lifecycleID: "lifecycle-1",
            status: .done,
            completedAt: Date(),
            source: "test"
        )
        #expect(await service.hasDelivered(delegateHandleID: payload.delegateHandleID, toolCallID: payload.toolCallID) == false)
        await service.markPending(payload)
        #expect(await service.hasDelivered(delegateHandleID: payload.delegateHandleID, toolCallID: payload.toolCallID) == false)
        await service.markDelivered(payload)
        #expect(await service.hasDelivered(delegateHandleID: payload.delegateHandleID, toolCallID: payload.toolCallID) == true)
    }

    @Test("tryBeginDelivery allows only one concurrent reservation per correlation key")
    func tryBeginDeliveryConcurrentReservation() async {
        let service = SubAgentCompletionService()
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            group.addTask {
                await service.tryBeginDelivery(delegateHandleID: "handle-a", toolCallID: "tool-a")
            }
            group.addTask {
                await service.tryBeginDelivery(delegateHandleID: "handle-a", toolCallID: "tool-a")
            }
            var collected: [Bool] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
        #expect(results.filter { $0 }.count == 1)
        #expect(results.filter { !$0 }.count == 1)
    }

    @Test("tryBeginDelivery can re-acquire after markPending")
    func tryBeginDeliveryAfterMarkPending() async {
        let service = SubAgentCompletionService()
        let payload = CompletionAnnouncePayload(
            delegateHandleID: "delegate-retry",
            toolCallID: "tool-retry",
            conversationID: UUID(),
            lifecycleID: "lifecycle-retry",
            status: .done,
            completedAt: Date(),
            source: "test"
        )
        #expect(await service.tryBeginDelivery(
            delegateHandleID: payload.delegateHandleID,
            toolCallID: payload.toolCallID
        ) == true)
        await service.markPending(payload)
        #expect(await service.tryBeginDelivery(
            delegateHandleID: payload.delegateHandleID,
            toolCallID: payload.toolCallID
        ) == true)
    }

    @Test("tryBeginDelivery rejects after markDelivered")
    func tryBeginDeliveryAfterMarkDelivered() async {
        let service = SubAgentCompletionService()
        let payload = CompletionAnnouncePayload(
            delegateHandleID: "delegate-delivered",
            toolCallID: "tool-delivered",
            conversationID: UUID(),
            lifecycleID: "lifecycle-delivered",
            status: .done,
            completedAt: Date(),
            source: "test"
        )
        #expect(await service.tryBeginDelivery(
            delegateHandleID: payload.delegateHandleID,
            toolCallID: payload.toolCallID
        ) == true)
        await service.markDelivered(payload)
        #expect(await service.tryBeginDelivery(
            delegateHandleID: payload.delegateHandleID,
            toolCallID: payload.toolCallID
        ) == false)
    }

    @Test("A retained payload round-trips through the event log")
    func retainedPayloadRoundTrips() {
        let notification = Message(
            id: UUID(),
            role: .assistant,
            content: "<task-notification>delegate_explore finished</task-notification>",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            toolCallId: "call-round-trip"
        )
        let stored = CompletionAnnounceNotificationPayload(message: notification)
        let encoded = ConversationEventCodec.encode(
            CompletionAnnounceEventPayload(
                announce: Self.announce(handle: "handle-round-trip", call: "call-round-trip"),
                runtimePublished: true,
                subagentPublished: false,
                retryCount: 1,
                deliveryState: "pending",
                pendingNotification: stored,
                createdAt: Date()
            )
        )
        let decoded = ConversationEventCodec.decode(CompletionAnnounceEventPayload.self, from: encoded)
        let recovered = decoded?.pendingNotification?.message
        // The whole point of persisting it: what comes back is what a retry re-appends.
        #expect(recovered?.id == notification.id)
        #expect(recovered?.role == notification.role)
        #expect(recovered?.content == notification.content)
        #expect(recovered?.toolCallId == notification.toolCallId)
    }

    @Test("An announce row written before the retained payload existed still decodes")
    func announceRowWithoutRetainedPayloadDecodes() {
        let encoded = ConversationEventCodec.encode(
            CompletionAnnounceEventPayload(
                announce: Self.announce(handle: "handle-legacy", call: "call-legacy"),
                runtimePublished: false,
                subagentPublished: false,
                retryCount: 1,
                deliveryState: "pending",
                createdAt: Date()
            )
        )
        // Encoding omits the absent field, so this is byte-for-byte the shape of a row written
        // before it existed. Those rows must still reconcile, just without a payload to recover.
        #expect(encoded.contains("pendingNotification") == false)
        let decoded = ConversationEventCodec.decode(CompletionAnnounceEventPayload.self, from: encoded)
        #expect(decoded != nil)
        #expect(decoded?.pendingNotification == nil)
    }

    @Test("A payload that cannot be represented losslessly is not persisted")
    func lossyPayloadIsRefused() {
        let withImage = Message(
            id: UUID(),
            role: .assistant,
            content: "has an attachment",
            timestamp: Date(),
            images: [Message.Image(name: "chart.png")]
        )
        let withToolCalls = Message(
            id: UUID(),
            role: .assistant,
            content: "",
            timestamp: Date(),
            toolCalls: [ToolCall(name: "delegate_explore", arguments: .object([:]), id: "call-lossy")]
        )
        // Writing a partial copy would be worse than keeping the pre-existing in-memory-only
        // behaviour, because the retry would then re-append something that is not the result.
        #expect(CompletionAnnounceNotificationPayload(message: withImage) == nil)
        #expect(CompletionAnnounceNotificationPayload(message: withToolCalls) == nil)
    }

    @Test("Only the unresolved half is persisted")
    func onlyUnresolvedPayloadIsPersisted() {
        let notification = Message(
            id: UUID(),
            role: .user,
            content: "<task-notification>…</task-notification>",
            timestamp: Date()
        )
        #expect(
            SubAgentCompletionRuntimeService.persistablePendingNotification(
                notification,
                contentDelivered: true
            ) == nil
        )
        #expect(
            SubAgentCompletionRuntimeService.persistablePendingNotification(
                nil,
                contentDelivered: false
            ) == nil
        )
        #expect(
            SubAgentCompletionRuntimeService.persistablePendingNotification(
                notification,
                contentDelivered: false
            )?.messageID == notification.id
        )
    }

    @Test("A restored retry budget resumes rather than restarting")
    func restoredRetryBudgetResumes() async {
        let service = SubAgentCompletionService()
        let announceID = UUID()
        // Without this, a restart hands an announcement a fresh budget of attempts even though the
        // persisted row already counted them.
        await service.restoreRetryCount(2, for: announceID)
        #expect(await service.recordRetry(for: announceID) == 3)
        // A stale lower count must not walk the counter backwards.
        await service.restoreRetryCount(1, for: announceID)
        #expect(await service.recordRetry(for: announceID) == 4)
    }

    private static func announce(handle: String, call: String) -> CompletionAnnouncePayload {
        CompletionAnnouncePayload(
            delegateHandleID: handle,
            toolCallID: call,
            conversationID: UUID(),
            lifecycleID: handle,
            status: .done,
            completedAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: "test"
        )
    }
}
