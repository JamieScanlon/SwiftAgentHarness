import Foundation
import Logging
import os
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("TriggerDelegatedCompletionHandoff")
struct TriggerDelegatedCompletionHandoffTests {
    @Test("delivers registered run once")
    func idempotentDelivery() async throws {
        let registry = TriggerDelegatedRunRegistry()
        let deliveryCount = DeliveryCounter()
        let router = TriggerSymmetricOutputRouter(
            channelRegistry: ChannelListenerRegistry.load(
                dataDirectory: FileManager.default.temporaryDirectory,
                ingress: ChannelIngressAdapter(dispatch: makeDispatch()),
                dedupe: ReplayHarnessDedupe(),
                logger: Logger(label: "test"),
                enabled: false,
                configURL: nil
            ),
            auditLog: TriggerAuditLog(logger: Logger(label: "test")),
            webhookPost: { _, _ in
                deliveryCount.increment()
                return 200
            }
        )
        let handoff = TriggerDelegatedCompletionHandoff(
            runRegistry: registry,
            outputRouter: router,
            resolveParentConversation: { _ in nil },
            lastAssistantText: { _ in nil }
        )
        let child = UUID()
        let trigger = HarnessTrigger(
            id: "wh-1",
            source: .webhook,
            sourceMetadata: ["deliveryWebhookURL": "https://example.com/out"],
            payload: "evt",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty,
            routingMode: .delegated
        )
        await registry.register(
            TriggerDelegatedRunRecord(
                trigger: trigger,
                parentConversationID: UUID(),
                childConversationID: child,
                sessionKey: "webhook:delegated:x"
            )
        )
        let event = makeCompletionEvent(childID: child, content: "result", success: true)
        #expect(await handoff.handle(event) == true)
        #expect(await handoff.handle(event) == true)
        #expect(deliveryCount.value == 1)
    }

    @Test("failed completion uses runtime status not model text")
    func failedStatus() async throws {
        let registry = TriggerDelegatedRunRegistry()
        let statusBox = StatusBox()
        let router = TriggerSymmetricOutputRouter(
            channelRegistry: ChannelListenerRegistry.load(
                dataDirectory: FileManager.default.temporaryDirectory,
                ingress: ChannelIngressAdapter(dispatch: makeDispatch()),
                dedupe: ReplayHarnessDedupe(),
                logger: Logger(label: "test"),
                enabled: false,
                configURL: nil
            ),
            auditLog: TriggerAuditLog(logger: Logger(label: "test")),
            webhookPost: { _, payload in
                statusBox.set(payload.status)
                return 500
            }
        )
        let handoff = TriggerDelegatedCompletionHandoff(
            runRegistry: registry,
            outputRouter: router,
            resolveParentConversation: { _ in nil },
            lastAssistantText: { _ in "Done!" }
        )
        let child = UUID()
        let trigger = HarnessTrigger(
            id: "wh-2",
            source: .webhook,
            sourceMetadata: ["deliveryWebhookURL": "https://example.com/out"],
            payload: "evt",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty,
            routingMode: .delegated
        )
        await registry.register(
            TriggerDelegatedRunRecord(
                trigger: trigger,
                parentConversationID: UUID(),
                childConversationID: child,
                sessionKey: "k"
            )
        )
        let event = makeCompletionEvent(childID: child, content: "Done!", success: false)
        #expect(await handoff.handle(event) == true)
        #expect(statusBox.read() == .failed)
    }

    private func makeDispatch() -> TriggerDispatchService {
        TriggerDispatchService(
            activationPolicy: TriggerActivationPolicy(
                idempotency: TriggerIdempotencyGate(dedupe: AlwaysPassIdempotency()),
                rateLimit: TriggerRateLimitGate(maxPerWindow: 100),
                initiatorBurst: TriggerInitiatorBurstGate(maxPerWindow: 100),
                auditLog: TriggerAuditLog(logger: Logger(label: "test"))
            ),
            sessionRouter: TriggerSessionRouter(sessionIndex: TriggerSessionIndex(createConversation: { _ in UUID() })),
            promptBuilder: TriggerPromptBuilder(),
            runtime: NoopRuntime()
        )
    }

    private func makeCompletionEvent(childID: UUID, content: String, success: Bool) -> SubAgentPendingCompletionEvent {
        let toolCallID = UUID().uuidString
        let completion = PendingToolCompletion(
            handleID: "handle-\(childID.uuidString)",
            toolCallID: toolCallID,
            result: ToolResult(
                success: success,
                content: content,
                toolCallId: toolCallID,
                error: success ? nil : "failed"
            ),
            completedAt: Date()
        )
        return SubAgentPendingCompletionEvent(
            conversationID: childID,
            completion: completion,
            toolMessage: Message(id: UUID(), role: .tool, content: content, timestamp: Date(), toolCallId: completion.toolCallID),
            launchHandleID: completion.handleID
        )
    }
}

private final class DeliveryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value = 0
    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TriggerCompletionStatus?
    func set(_ status: TriggerCompletionStatus) {
        lock.lock()
        stored = status
        lock.unlock()
    }
    func read() -> TriggerCompletionStatus? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private struct NoopRuntime: TriggerRuntimeDispatching {
    func dispatchTriggerMessage(
        conversationID: UUID,
        text: String,
        systemReminder: String?,
        inputTrustRaw: String?,
        resolvedInputTrustClass: TrustPolicyClass?,
        enableTools: Bool,
        enableAgents: Bool,
        originSurface: String?,
        originSenderID: String?,
        originSenderIsOwner: Bool?
    ) async throws {}
}
