import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ApprovalCoordinator lifecycle")
struct ApprovalCoordinatorTests {
    @Test("register dedupes pending and resolved ids")
    func registerDedupes() async {
        let coordinator = ApprovalCoordinator()
        #expect(await coordinator.register(id: "a", timeoutMs: 60_000, timeoutResolution: .deny, timeoutSource: "t"))
        // Second register while pending is rejected.
        #expect(await coordinator.register(id: "a", timeoutMs: 60_000, timeoutResolution: .deny, timeoutSource: "t") == false)
        _ = await coordinator.resolve(id: "a", decision: .allowOnce, source: "user")
        // Register after resolution is also rejected.
        #expect(await coordinator.register(id: "a", timeoutMs: 60_000, timeoutResolution: .deny, timeoutSource: "t") == false)
    }

    @Test("resolve returns nil for unknown id and wakes waiters once pending")
    func resolveWakesWaiters() async {
        let coordinator = ApprovalCoordinator()
        #expect(await coordinator.resolve(id: "missing", decision: .deny, source: "x") == nil)
        _ = await coordinator.register(id: "b", timeoutMs: 60_000, timeoutResolution: .deny, timeoutSource: "t")
        async let waited = coordinator.waitForResolution(id: "b")
        try? await Task.sleep(nanoseconds: 5_000_000)
        let resolved = await coordinator.resolve(id: "b", decision: .allowAlways, source: "user")
        #expect(resolved?.decision == .allowAlways)
        let waitedOutcome = try? await waited
        #expect(waitedOutcome?.decision == .allowAlways)
        #expect(waitedOutcome?.source == "user")
    }

    @Test("expiry resolves per the declared timeout behavior")
    func expiryHonorsBehavior() async {
        let coordinator = ApprovalCoordinator()
        _ = await coordinator.register(
            id: "deny-on-timeout",
            timeoutMs: 5,
            timeoutResolution: .deny,
            timeoutSource: "runtime.approvalTimeout",
            timeoutReason: "approval_timeout_autoDeny"
        )
        let outcome = try? await coordinator.waitForResolution(id: "deny-on-timeout")
        #expect(outcome?.decision == .deny)
        #expect(outcome?.reason == "approval_timeout_autoDeny")

        let allowCoordinator = ApprovalCoordinator()
        _ = await allowCoordinator.register(
            id: "allow-on-timeout",
            timeoutMs: 5,
            timeoutResolution: .allow,
            timeoutSource: "runtime.approvalTimeout"
        )
        let allowOutcome = try? await allowCoordinator.waitForResolution(id: "allow-on-timeout")
        #expect(allowOutcome?.decision == .allowOnce)
    }

    @Test("consumeExpired returns and resolves only past-due pendings")
    func consumeExpired() async {
        let coordinator = ApprovalCoordinator()
        let past = Date().addingTimeInterval(-10)
        _ = await coordinator.register(
            id: "old",
            requestedAt: past,
            timeoutMs: 1000,
            timeoutResolution: .deny,
            timeoutSource: "runtime.approvalTimeout"
        )
        _ = await coordinator.register(
            id: "fresh",
            timeoutMs: 60_000,
            timeoutResolution: .deny,
            timeoutSource: "runtime.approvalTimeout"
        )
        let expired = await coordinator.consumeExpired()
        #expect(expired.map(\.id) == ["old"])
        #expect(await coordinator.isPending(id: "fresh"))
        #expect(await coordinator.isPending(id: "old") == false)
    }

    @Test("exec-style wait returns nil on timeout without persisting")
    func execStyleTimeout() async {
        let coordinator = ApprovalCoordinator()
        _ = await coordinator.register(id: "c", timeoutMs: 60_000, timeoutResolution: .deny, timeoutSource: "t")
        let outcome = await coordinator.waitForResolution(id: "c", timeoutSeconds: 0.02)
        #expect(outcome == nil)
        #expect(await coordinator.resolution(id: "c") == nil)
    }

    @Test("disabled timeout tool-style wait returns only after resolve")
    func disabledTimeoutWaitsForResolve() async throws {
        let coordinator = ApprovalCoordinator()
        _ = await coordinator.register(id: "no-timeout", timeoutMs: nil, timeoutResolution: .deny, timeoutSource: "t")
        let task = Task { try await coordinator.waitForResolution(id: "no-timeout") }
        // Give the wait ample time to (incorrectly) self-resolve if a timeout leaked.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await coordinator.isPending(id: "no-timeout"))
        let resolved = await coordinator.resolve(id: "no-timeout", decision: .allowOnce, source: "user")
        #expect(resolved?.decision == .allowOnce)
        let outcome = try await task.value
        #expect(outcome.decision == .allowOnce)
    }

    @Test("consumeExpired ignores pendings with no expiry")
    func consumeExpiredIgnoresDisabledTimeout() async {
        let coordinator = ApprovalCoordinator()
        let past = Date().addingTimeInterval(-10)
        _ = await coordinator.register(
            id: "no-expiry",
            requestedAt: past,
            timeoutMs: nil,
            timeoutResolution: .deny,
            timeoutSource: "t"
        )
        let expired = await coordinator.consumeExpired()
        #expect(expired.isEmpty)
        #expect(await coordinator.isPending(id: "no-expiry"))
    }

    @Test("indefinite exec-style wait returns only after resolve")
    func execStyleIndefiniteWaitsForResolve() async {
        let coordinator = ApprovalCoordinator()
        _ = await coordinator.register(id: "ind", timeoutMs: 60_000, timeoutResolution: .deny, timeoutSource: "t")
        async let waited = coordinator.waitForResolution(id: "ind", timeoutSeconds: nil)
        // Give the wait ample time to (incorrectly) self-resolve if a timeout leaked.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await coordinator.isPending(id: "ind"))
        let resolved = await coordinator.resolve(id: "ind", decision: .allowOnce, source: "user")
        #expect(resolved?.decision == .allowOnce)
        let outcome = await waited
        #expect(outcome?.decision == .allowOnce)
    }

    @Test("cancelling an indefinite exec-style wait resolves the waiter to nil")
    func execStyleIndefiniteCancelDrainsWaiter() async {
        let coordinator = ApprovalCoordinator()
        _ = await coordinator.register(id: "cancel", timeoutMs: 60_000, timeoutResolution: .deny, timeoutSource: "t")
        let task = Task { await coordinator.waitForResolution(id: "cancel", timeoutSeconds: nil) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        let outcome = await task.value
        #expect(outcome == nil)
        // The waiter was drained without persisting a resolution.
        #expect(await coordinator.resolution(id: "cancel") == nil)
    }

    @Test("reroute notices aggregate and drain by id")
    func rerouteNotices() async {
        let coordinator = ApprovalCoordinator()
        await coordinator.recordRerouteNotice(ApprovalRerouteNotice(approvalID: "r", deliveredTo: "DMs"))
        await coordinator.recordRerouteNotice(ApprovalRerouteNotice(approvalID: "r", deliveredTo: "owner"))
        let drained = await coordinator.takeRerouteNotices(id: "r")
        #expect(drained.count == 2)
        #expect(await coordinator.takeRerouteNotices(id: "r").isEmpty)
    }
}
