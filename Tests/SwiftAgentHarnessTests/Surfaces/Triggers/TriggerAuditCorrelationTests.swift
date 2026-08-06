import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("TriggerAuditCorrelation")
struct TriggerAuditCorrelationTests {
    actor MemoryDedupe: TriggerDedupeChecking {
        private var seen: Set<String> = []
        func dedupePeek(key: String) async throws -> Bool { seen.contains(key) }
        func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool {
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    @Test("admitted and rate-limited legs share correlationId in audit jsonl")
    func sharedCorrelationInAudit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audit-corr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let auditURL = dir.appendingPathComponent("trigger_audit.jsonl")
        let auditLog = TriggerAuditLog(logger: Logger(label: "test"), jsonlURL: auditURL)
        let policy = TriggerActivationPolicy(
            idempotency: TriggerIdempotencyGate(dedupe: MemoryDedupe()),
            rateLimit: TriggerRateLimitGate(windowSeconds: 60, maxPerWindow: 1),
            initiatorBurst: TriggerInitiatorBurstGate(maxPerWindow: 100),
            auditLog: auditLog,
            rateLimitKey: { _ in "same-route" }
        )
        let correlation = TriggerCorrelation.root(triggerID: "workflow-root")
        let first = HarnessTrigger(
            id: "leg-1",
            source: .webhook,
            payload: "one",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty,
            correlation: correlation
        )
        let second = HarnessTrigger(
            id: "leg-2",
            source: .webhook,
            payload: "two",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty,
            correlation: correlation
        )
        let firstDecision = try await policy.evaluate(first)
        let secondDecision = try await policy.evaluate(second)
        #expect(firstDecision == .admitted)
        #expect(secondDecision == .rateLimited)
        let lines = try String(contentsOf: auditURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try lines.map { try decoder.decode(TriggerAuditEntry.self, from: Data($0.utf8)) }
        #expect(entries.allSatisfy { $0.correlationId == "workflow-root" })
        #expect(entries.allSatisfy { $0.rootId == "workflow-root" })
        #expect(entries.map(\.decision).contains(.admitted))
        #expect(entries.map(\.decision).contains(.rateLimited))
    }
}
