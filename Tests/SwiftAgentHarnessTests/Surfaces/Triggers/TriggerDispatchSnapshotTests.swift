import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("TriggerDispatchSnapshot")
struct TriggerDispatchSnapshotTests {
    final class CaptureRuntime: TriggerRuntimeDispatching, @unchecked Sendable {
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

    @Test("admitted trigger is saved to snapshot store")
    func snapshotOnAdmit() async throws {
        let dir = try makeTempDir()
        let store = TriggerSnapshotStore(dataDirectory: dir)
        let dispatch = TriggerDispatchService(
            activationPolicy: TriggerActivationPolicy(
                idempotency: TriggerIdempotencyGate(dedupe: AdmitAllDedupe()),
                rateLimit: TriggerRateLimitGate(maxPerWindow: 100),
                costCeiling: TriggerCostCeilingGate(maxPerWindow: 100),
                auditLog: TriggerAuditLog(logger: Logger(label: "test"))
            ),
            sessionRouter: TriggerSessionRouter(sessionIndex: TriggerSessionIndex(createConversation: { _ in UUID() })),
            promptBuilder: TriggerPromptBuilder(),
            runtime: CaptureRuntime(),
            snapshotStore: store
        )
        let trigger = HarnessTrigger(
            id: "save-me",
            source: .webhook,
            payload: "payload",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty
        )
        let result = try await dispatch.ingest(trigger)
        #expect(result.decision == .admitted)
        let expected = trigger.withRootCorrelation()
        let loaded = try store.load(triggerID: "save-me")
        #expect(loaded == expected)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

struct AdmitAllDedupe: TriggerDedupeChecking {
    func dedupePeek(key: String) async throws -> Bool { false }
    func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool { true }
}
