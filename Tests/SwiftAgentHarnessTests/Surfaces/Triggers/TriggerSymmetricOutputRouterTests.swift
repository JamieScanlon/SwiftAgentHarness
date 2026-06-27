import Foundation
import Logging
import os
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("TriggerSymmetricOutputRouter")
struct TriggerSymmetricOutputRouterTests {
    @Test("channel completion sends through listener")
    func channelDelivery() async throws {
        let dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("sym-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let dispatch = TriggerDispatchService(
            activationPolicy: TriggerActivationPolicy(
                idempotency: TriggerIdempotencyGate(dedupe: AlwaysPassIdempotency()),
                rateLimit: TriggerRateLimitGate(maxPerWindow: 100),
                costCeiling: TriggerCostCeilingGate(maxPerWindow: 100),
                auditLog: TriggerAuditLog(logger: Logger(label: "test"))
            ),
            sessionRouter: TriggerSessionRouter(sessionIndex: TriggerSessionIndex(createConversation: { _ in UUID() })),
            promptBuilder: TriggerPromptBuilder(),
            runtime: NoopTriggerRuntime()
        )
        let registry = ChannelListenerRegistry.load(
            dataDirectory: dataDir,
            ingress: ChannelIngressAdapter(dispatch: dispatch),
            dedupe: ReplayHarnessDedupe(),
            logger: Logger(label: "test"),
            enabled: false,
            configURL: nil
        )
        let router = TriggerSymmetricOutputRouter(
            channelRegistry: registry,
            auditLog: TriggerAuditLog(logger: Logger(label: "test"))
        )
        let trigger = HarnessTrigger(
            id: "ch-1",
            source: .channel,
            sourceMetadata: [
                "channel": ChannelId.slack.rawValue,
                "chatId": "C1",
                "threadId": "T1",
            ],
            payload: "hi",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty,
            routingMode: .delegated
        )
        try await router.deliverCompletion(
            trigger: trigger,
            result: TriggerCompletionResult(
                status: .completed,
                text: "done",
                childSessionID: UUID()
            )
        )
    }

    @Test("webhook completion posts outbound payload")
    func webhookDelivery() async throws {
        let posted: OSAllocatedUnfairLock<WebhookOutboundPayload?> = OSAllocatedUnfairLock(initialState: nil)
        let router = TriggerSymmetricOutputRouter(
            channelRegistry: ChannelListenerRegistry.load(
                dataDirectory: FileManager.default.temporaryDirectory,
                ingress: ChannelIngressAdapter(dispatch: makeNoopDispatch()),
                dedupe: ReplayHarnessDedupe(),
                logger: Logger(label: "test"),
                enabled: false,
                configURL: nil
            ),
            auditLog: TriggerAuditLog(logger: Logger(label: "test")),
            webhookPost: { _, payload in
                posted.withLock { $0 = payload }
                return 200
            }
        )
        let trigger = HarnessTrigger(
            id: "wh-1",
            source: .webhook,
            sourceMetadata: [
                "routeName": "alerts",
                "deliveryWebhookURL": "https://example.com/out",
            ],
            payload: "evt",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty,
            routingMode: .delegated
        )
        try await router.deliverCompletion(
            trigger: trigger,
            result: TriggerCompletionResult(status: .completed, text: "ok", childSessionID: UUID())
        )
        #expect(posted.withLock { $0?.text } == "ok")
        #expect(posted.withLock { $0?.routeName } == "alerts")
    }

    @Test("NO_REPLY suppresses egress")
    func noReplySuppresses() async throws {
        let posted = FlagBox()
        let router = TriggerSymmetricOutputRouter(
            channelRegistry: ChannelListenerRegistry.load(
                dataDirectory: FileManager.default.temporaryDirectory,
                ingress: ChannelIngressAdapter(dispatch: makeNoopDispatch()),
                dedupe: ReplayHarnessDedupe(),
                logger: Logger(label: "test"),
                enabled: false,
                configURL: nil
            ),
            auditLog: TriggerAuditLog(logger: Logger(label: "test")),
            webhookPost: { _, _ in
                posted.set(true)
                return 200
            }
        )
        let trigger = HarnessTrigger(
            id: "wh-2",
            source: .webhook,
            sourceMetadata: ["deliveryWebhookURL": "https://example.com/out"],
            payload: "evt",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty,
            routingMode: .delegated
        )
        try await router.deliverCompletion(
            trigger: trigger,
            result: TriggerCompletionResult(status: .completed, text: "no_reply", childSessionID: UUID())
        )
        #expect(posted.read() == false)
    }

    private func makeNoopDispatch() -> TriggerDispatchService {
        TriggerDispatchService(
            activationPolicy: TriggerActivationPolicy(
                idempotency: TriggerIdempotencyGate(dedupe: AlwaysPassIdempotency()),
                rateLimit: TriggerRateLimitGate(maxPerWindow: 100),
                costCeiling: TriggerCostCeilingGate(maxPerWindow: 100),
                auditLog: TriggerAuditLog(logger: Logger(label: "test"))
            ),
            sessionRouter: TriggerSessionRouter(sessionIndex: TriggerSessionIndex(createConversation: { _ in UUID() })),
            promptBuilder: TriggerPromptBuilder(),
            runtime: NoopTriggerRuntime()
        )
    }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
    func read() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private struct NoopTriggerRuntime: TriggerRuntimeDispatching {
    func dispatchTriggerMessage(
        conversationID: UUID,
        text: String,
        systemReminder: String?,
        inputTrustRaw: String?,
        enableTools: Bool,
        enableAgents: Bool,
        originSurface: String?,
        originSenderID: String?
    ) async throws {}
}
