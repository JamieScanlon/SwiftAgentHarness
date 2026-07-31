import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("TriggerDispatchService")
struct TriggerDispatchServiceTests {
    final class StubRuntime: TriggerRuntimeDispatching, @unchecked Sendable {
        var lastConversationID: UUID?
        var lastText: String?
        var lastSystemReminder: String?
        var lastTrust: String?
        var lastResolvedTrustClass: TrustPolicyClass?

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
    ) async throws {
            lastConversationID = conversationID
            lastText = text
            lastSystemReminder = systemReminder
            lastTrust = inputTrustRaw
            lastResolvedTrustClass = resolvedInputTrustClass
        }
    }

    actor AdmitDedupe: TriggerDedupeChecking {
        func dedupePeek(key: String) async throws -> Bool { false }
        func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool { true }
    }

    @Test("dispatch admits and calls runtime")
    func dispatchAdmits() async throws {
        let conversationID = UUID()
        let runtime = StubRuntime()
        let dispatch = makeDispatch(runtime: runtime, createConversation: { _ in conversationID })
        let trigger = HarnessTrigger(
            id: "dispatch-1",
            source: .cron,
            payload: "do work",
            initiator: TriggerInitiator(kind: .user),
            trust: .userDeferred
        )
        let result = try await dispatch.ingest(trigger)
        #expect(result.decision == .admitted)
        #expect(result.sessionID == conversationID)
        #expect(runtime.lastConversationID == conversationID)
        #expect(runtime.lastText?.contains("do work") == true)
        #expect(runtime.lastText?.contains("[trigger-context]") != true)
        #expect(runtime.lastSystemReminder?.contains("[trigger-context]") == true)
        #expect(runtime.lastTrust == CommEnvelopeOriginTrust.userDeferred.rawValue)
        #expect(runtime.lastResolvedTrustClass == .lowTrust)
    }

    private func makeDispatch(runtime: StubRuntime, createConversation: @escaping @Sendable (String?) async throws -> UUID) -> TriggerDispatchService {
        let audit = TriggerAuditLog(logger: Logger(label: "test"))
        let policy = TriggerActivationPolicy(
            idempotency: TriggerIdempotencyGate(dedupe: AdmitDedupe()),
            rateLimit: TriggerRateLimitGate(maxPerWindow: 100),
            costCeiling: TriggerCostCeilingGate(maxPerWindow: 100),
            auditLog: audit
        )
        let router = TriggerSessionRouter(sessionIndex: TriggerSessionIndex(createConversation: createConversation))
        return TriggerDispatchService(
            activationPolicy: policy,
            sessionRouter: router,
            promptBuilder: TriggerPromptBuilder(),
            runtime: runtime
        )
    }
}
