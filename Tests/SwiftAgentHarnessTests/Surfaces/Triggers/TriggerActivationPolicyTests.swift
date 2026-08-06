import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("TriggerActivationPolicy")
struct TriggerActivationPolicyTests {
    actor MemoryDedupe: TriggerDedupeChecking {
        private var seen: Set<String> = []
        func dedupePeek(key: String) async throws -> Bool {
            seen.contains(key)
        }
        func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool {
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    @Test("admits first trigger")
    func admitsFirst() async throws {
        let policy = makePolicy()
        let trigger = sampleTrigger(id: "a")
        let decision = try await policy.evaluate(trigger)
        #expect(decision == .admitted)
    }

    @Test("dedup hit on repeat id")
    func dedupHit() async throws {
        let policy = makePolicy()
        let trigger = sampleTrigger(id: "dup")
        _ = try await policy.evaluate(trigger)
        let decision = try await policy.evaluate(trigger)
        #expect(decision == .dedupHit)
    }

    @Test("unauthorized when route disabled")
    func unauthorized() async throws {
        let policy = TriggerActivationPolicy(
            idempotency: TriggerIdempotencyGate(dedupe: MemoryDedupe()),
            rateLimit: TriggerRateLimitGate(),
            initiatorBurst: TriggerInitiatorBurstGate(),
            auditLog: TriggerAuditLog(logger: Logger(label: "test")),
            authorize: { _ in TriggerAuthorizationContext(routeEnabled: false, sourceAllowed: true) }
        )
        let decision = try await policy.evaluate(sampleTrigger(id: "x"))
        #expect(decision == .unauthorized)
    }

    private func makePolicy() -> TriggerActivationPolicy {
        TriggerActivationPolicy(
            idempotency: TriggerIdempotencyGate(dedupe: MemoryDedupe()),
            rateLimit: TriggerRateLimitGate(maxPerWindow: 100),
            initiatorBurst: TriggerInitiatorBurstGate(maxPerWindow: 100),
            auditLog: TriggerAuditLog(logger: Logger(label: "test"))
        )
    }

    private func sampleTrigger(id: String) -> HarnessTrigger {
        HarnessTrigger(
            id: id,
            source: .webhook,
            payload: "hello",
            initiator: TriggerInitiator(kind: .external, id: "test"),
            trust: .knownParty
        )
    }
}
