import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("TriggerWorkflowIntegration")
struct TriggerWorkflowIntegrationTests {
    final class CaptureRuntime: TriggerRuntimeDispatching, @unchecked Sendable {
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

    actor LocalDedupe: TriggerDedupeChecking {
        private var keys: Set<String> = []
        func dedupePeek(key: String) async throws -> Bool { keys.contains(key) }
        func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool {
            if keys.contains(key) { return false }
            keys.insert(key)
            return true
        }
    }

    @Test("webhook schedule follow-up fire links parent trigger id")
    func webhookScheduleFollowUpChain() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let auditURL = tmp.appendingPathComponent("trigger_audit.jsonl")
        let auditLog = TriggerAuditLog(logger: Logger(label: "test"), jsonlURL: auditURL)
        let snapshotStore = TriggerSnapshotStore(dataDirectory: tmp)
        let dispatch = TriggerDispatchService(
            activationPolicy: TriggerActivationPolicy(
                idempotency: TriggerIdempotencyGate(dedupe: LocalDedupe()),
                rateLimit: TriggerRateLimitGate(maxPerWindow: 100),
                costCeiling: TriggerCostCeilingGate(maxPerWindow: 100),
                auditLog: auditLog
            ),
            sessionRouter: TriggerSessionRouter(sessionIndex: TriggerSessionIndex(createConversation: { _ in UUID() })),
            promptBuilder: TriggerPromptBuilder(),
            runtime: CaptureRuntime(),
            snapshotStore: snapshotStore
        )
        let webhookTrigger = HarnessTrigger(
            id: "delivery-webhook-1",
            source: .webhook,
            payload: "start workflow",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty,
            correlation: .root(triggerID: "delivery-webhook-1")
        )
        _ = try await dispatch.ingest(webhookTrigger)
        let taskStore = ScheduledTaskStore(fileURL: tmp.appendingPathComponent("tasks.json"))
        let scheduler = TriggerSchedulerService(
            store: taskStore,
            dispatch: dispatch,
            lockURL: tmp.appendingPathComponent("lock.json"),
            logger: Logger(label: "test")
        )
        let savedTask = try TriggerRegistrationTestSupport.service(store: taskStore).registerSchedule(
            ScheduleRegistrationSpec(
                schedule: ScheduledTaskSchedule(kind: .at, at: "2030-01-01T00:00:00Z"),
                payloadKind: .agentTurn,
                payloadText: "follow up later",
                recurring: false,
                correlation: .child(parent: webhookTrigger, followUpKind: "scheduled")
            ),
            authority: .localFileDrop()
        )
        let fireResult = try await scheduler.fireNow(id: savedTask.id)
        #expect(fireResult.decision == .admitted)
        let auditLines = try String(contentsOf: auditURL, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.isEmpty }
        #expect(auditLines.count >= 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try auditLines.map { try decoder.decode(TriggerAuditEntry.self, from: Data($0.utf8)) }
        let followUpEntries = entries.filter { $0.parentTriggerId == "delivery-webhook-1" }
        #expect(followUpEntries.count >= 1)
        #expect(followUpEntries.allSatisfy { $0.correlationId == "delivery-webhook-1" })
        let snapshotFiles = try FileManager.default.contentsOfDirectory(at: tmp.appendingPathComponent("trigger_snapshots"), includingPropertiesForKeys: nil)
        let followUpSnapshots = snapshotFiles.filter { $0.lastPathComponent.hasPrefix(savedTask.id) }
        #expect(followUpSnapshots.count == 1)
        let snapshotData = try Data(contentsOf: followUpSnapshots[0])
        let snapshotTrigger = try JSONDecoder().decode(HarnessTrigger.self, from: snapshotData)
        #expect(snapshotTrigger.correlation?.parentTriggerId == "delivery-webhook-1")
    }
}
