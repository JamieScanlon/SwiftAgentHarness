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

    @Test("threaded routing nil after admission audits unauthorized and warns")
    func unauthorizedRoutingAfterAdmissionAuditsAndWarns() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dispatch-audit-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let auditURL = dir.appendingPathComponent("trigger_audit.jsonl")
        let box = LogCaptureBox()
        let logger = Logger(label: "dispatch-unauthorized-test") { _ in LogCaptureHandler(box: box) }
        let runtime = StubRuntime()
        let targetID = UUID()
        let dispatch = makeDispatch(
            runtime: runtime,
            createConversation: { _ in UUID() },
            auditURL: auditURL,
            threadedTargetValidator: { _, _ in false },
            logger: logger
        )
        let trigger = HarnessTrigger(
            id: "dispatch-unauthorized-1",
            source: .cron,
            sourceMetadata: [
                "conversationID": targetID.uuidString,
                "cronJobId": "job-unauthorized",
            ],
            payload: "do work",
            initiator: TriggerInitiator(kind: .user),
            trust: .userDeferred,
            routingMode: .threaded
        )
        let result = try await dispatch.ingest(trigger)
        #expect(result.decision == .unauthorized)
        #expect(result.sessionID == nil)
        #expect(runtime.lastConversationID == nil)

        let lines = try String(contentsOf: auditURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try lines.map { try decoder.decode(TriggerAuditEntry.self, from: Data($0.utf8)) }
        #expect(entries.map(\.decision) == [.admitted, .unauthorized])
        #expect(entries.allSatisfy { $0.triggerID == "dispatch-unauthorized-1" })
        #expect(box.warnings.contains { $0.contains("trigger_threaded_route_nil_conversation") })
    }

    private func makeDispatch(
        runtime: StubRuntime,
        createConversation: @escaping @Sendable (String?) async throws -> UUID,
        auditURL: URL? = nil,
        threadedTargetValidator: (@Sendable (UUID, HarnessTrigger) async -> Bool)? = nil,
        logger: Logger = Logger(label: "test")
    ) -> TriggerDispatchService {
        let audit = TriggerAuditLog(logger: logger, jsonlURL: auditURL)
        let policy = TriggerActivationPolicy(
            idempotency: TriggerIdempotencyGate(dedupe: AdmitDedupe()),
            rateLimit: TriggerRateLimitGate(maxPerWindow: 100),
            initiatorBurst: TriggerInitiatorBurstGate(maxPerWindow: 100),
            auditLog: audit
        )
        let router = TriggerSessionRouter(
            sessionIndex: TriggerSessionIndex(createConversation: createConversation),
            threadedTargetValidator: threadedTargetValidator ?? { _, _ in true }
        )
        return TriggerDispatchService(
            activationPolicy: policy,
            sessionRouter: router,
            promptBuilder: TriggerPromptBuilder(),
            runtime: runtime,
            logger: logger
        )
    }
}
