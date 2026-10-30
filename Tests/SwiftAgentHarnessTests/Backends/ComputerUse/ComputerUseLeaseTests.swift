import Foundation
import Synchronization
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use grants and app policy")
struct ComputerUseGrantTests {
    @Test("Password managers are blocked by default and allowed only by explicit operator override")
    func passwordManagersBlocked() {
        let request = [ComputerUseGrant.app(bundleID: "com.1password.1password", tier: .full)]
        let review = ComputerUseGrantReviewer().review(request)
        #expect(review.grantable.isEmpty)
        #expect(review.blocked.map(\.grant) == request)

        let overridden = ComputerUseGrantReviewer(
            overrides: ComputerUseOperatorOverrides(allowBlockedBundleIDs: ["com.1password.1password"])
        ).review(request)
        #expect(overridden.grantable.map(\.grant) == request)
    }

    @Test("Finance apps are blocked by category")
    func financeCategoryBlocked() {
        let ruling = ComputerUseAppPolicy.default.ruling(for: AppIdentity(bundleID: "com.example.trader", category: "public.app-category.finance"))
        #expect(ruling.blockedReason != nil)
    }

    @Test("Terminals and IDEs are capped at click and carry a blast-radius warning")
    func terminalsCapped() throws {
        let review = ComputerUseGrantReviewer().review([
            .app(bundleID: "com.apple.Terminal", tier: .full),
            .app(bundleID: "com.jetbrains.intellij", tier: .full),
        ])
        #expect(review.grantable.map(\.grant) == [
            .app(bundleID: "com.apple.Terminal", tier: .click),
            .app(bundleID: "com.jetbrains.intellij", tier: .click),
        ])
        #expect(review.grantable.allSatisfy { $0.requestedTier == .full && $0.capReason != nil && $0.warning != nil })
    }

    @Test("Finder and System Settings are grantable but warn about their real blast radius")
    func broadAppsWarn() {
        let review = ComputerUseGrantReviewer().review([
            .app(bundleID: "com.apple.finder", tier: .full),
            .app(bundleID: "com.apple.systempreferences", tier: .click),
        ])
        #expect(review.grantable.map(\.grant.tier) == [.full, .click])
        #expect(review.grantable.allSatisfy { $0.warning != nil && $0.capReason == nil })
    }

    @Test("Browsers are capped at view; their pages are reached through domain grants")
    func browsersCappedAtView() {
        let review = ComputerUseGrantReviewer().review([
            .app(bundleID: "com.google.Chrome", tier: .full),
            .domain("https://Docs.Example.com/", tier: .full),
        ])
        #expect(review.grantable.map(\.grant) == [
            .app(bundleID: "com.google.Chrome", tier: .view),
            .domain("docs.example.com", tier: .full),
        ])
    }

    @Test("Domain grants match the domain and its subdomains, never a suffix collision")
    func domainMatching() {
        let grants = ComputerUseGrantSet([.domain("example.com", tier: .click)])
        #expect(grants.tier(forURL: "https://example.com/a") == .click)
        #expect(grants.tier(forURL: "https://mail.example.com/") == .click)
        #expect(grants.tier(forURL: "https://notexample.com/") == nil)
        #expect(grants.tier(forURL: "https://example.com.evil.net/") == nil)
        #expect(grants.tier(forURL: "not a url") == nil)
    }

    @Test("App grants report tier and flags by bundle id")
    func appLookup() {
        let grants = ComputerUseGrantSet([.app(bundleID: "com.apple.TextEdit", tier: .full, flags: [.clipboardWrite])])
        #expect(grants.tier(forApp: "com.apple.TextEdit") == .full)
        #expect(grants.flags(forApp: "com.apple.TextEdit") == [.clipboardWrite])
        #expect(grants.tier(forApp: "com.apple.Notes") == nil)
    }
}

@Suite("Computer use lease lock")
struct DisplayTargetLeaseLockTests {
    @Test("A second live holder gets target-busy naming the current holder")
    func busy() async throws {
        let lock = DisplayTargetLeaseLock()
        try await lock.acquire(leaseID: UUID(), holder: .init(id: "agent-a"))
        await #expect(throws: DisplayTargetError.targetBusy(holder: "agent-a")) {
            try await lock.acquire(leaseID: UUID(), holder: .init(id: "agent-b"))
        }
    }

    @Test("A crashed holder does not block the target forever")
    func deadHolderReclaimed() async throws {
        let lock = DisplayTargetLeaseLock()
        try await lock.acquire(leaseID: UUID(), holder: .init(id: "agent-a", isAlive: { false }))
        let second = UUID()
        try await lock.acquire(leaseID: second, holder: .init(id: "agent-b"))
        #expect(await lock.holds(leaseID: second))
        #expect(await lock.holderID == "agent-b")
    }

    @Test("Release frees the target and is idempotent")
    func release() async throws {
        let lock = DisplayTargetLeaseLock()
        let first = UUID()
        try await lock.acquire(leaseID: first, holder: .init(id: "agent-a"))
        #expect(await lock.release(leaseID: first))
        #expect(await !lock.release(leaseID: first))
        try await lock.acquire(leaseID: UUID(), holder: .init(id: "agent-b"))
    }
}

@Suite("Display target registry leasing")
struct DisplayTargetRegistryTests {
    private func request(
        target: DisplayTargetID,
        grants: [ComputerUseGrant] = [.app(bundleID: "com.apple.TextEdit", tier: .full)],
        operatorInitiated: Bool = true,
        userPresent: Bool = true,
        maxDuration: Duration = .seconds(3600)
    ) -> LeaseRequest {
        LeaseRequest(
            target: target,
            agentID: "agent",
            grants: grants,
            budgets: ComputerUseBudgets(steps: 50, maxDuration: maxDuration),
            delivery: .backgroundOnly,
            operatorInitiated: operatorInitiated,
            userPresent: userPresent
        )
    }

    @Test("The host desktop requires an operator-initiated session with the user present")
    func hostRequiresPresentOperator() async throws {
        let host = FakeDisplayTarget(manifest: FakeDisplayTarget.hostManifest)
        let registry = DisplayTargetRegistry(targets: [host])
        for (operatorInitiated, userPresent) in [(false, true), (true, false), (false, false)] {
            await #expect(throws: ComputerUseLeaseDenial.hostTargetRequiresPresentOperator) {
                _ = try await registry.lease(
                    self.request(target: host.manifest.id, operatorInitiated: operatorInitiated, userPresent: userPresent),
                    approve: { $0.review.grantable.map(\.grant) }
                )
            }
        }
        let granted = try await registry.lease(request(target: host.manifest.id), approve: { $0.review.grantable.map(\.grant) })
        #expect(granted.lease.target == host.manifest.id)
    }

    @Test("Headless sessions may lease isolated targets, with a short absolute expiry")
    func headlessIsolatedTarget() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let vm = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest, now: { now })
        let registry = DisplayTargetRegistry(targets: [vm], unattendedMaxDuration: .seconds(20 * 60), now: { now })
        let granted = try await registry.lease(
            request(target: vm.manifest.id, operatorInitiated: false, userPresent: false),
            approve: { $0.review.grantable.map(\.grant) }
        )
        #expect(granted.lease.budgets.grantExpiry == .seconds(20 * 60))
        #expect(granted.lease.endsAt == now.addingTimeInterval(20 * 60))
    }

    @Test("The grant dialog learns which conversation asked, for which target and task")
    func approverContext() async throws {
        let vm = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest)
        let registry = DisplayTargetRegistry(targets: [vm])
        let conversationID = UUID()
        var leaseRequest = request(target: vm.manifest.id)
        leaseRequest.conversationID = conversationID
        let seen = Mutex<ComputerUseGrantRequest?>(nil)
        _ = try await registry.lease(leaseRequest, purpose: "Bold the title.") { request in
            seen.withLock { $0 = request }
            return request.review.grantable.map(\.grant)
        }
        let request = try #require(seen.withLock { $0 })
        #expect(request.conversationID == conversationID)
        #expect(request.lease.agentID == "agent")
        #expect(request.target == FakeDisplayTarget.vmManifest)
        #expect(request.purpose == "Bold the title.")
        #expect(request.review.grantable.map(\.grant) == leaseRequest.grants)
    }

    @Test("An approver cannot raise a grant above its cap or add grants that were not requested")
    func approverClamped() async throws {
        let host = FakeDisplayTarget(manifest: FakeDisplayTarget.hostManifest)
        let registry = DisplayTargetRegistry(targets: [host])
        let granted = try await registry.lease(
            request(target: host.manifest.id, grants: [.app(bundleID: "com.apple.Terminal", tier: .full)]),
            approve: { _ in [.app(bundleID: "com.apple.Terminal", tier: .full), .app(bundleID: "com.apple.finder", tier: .full)] }
        )
        #expect(granted.lease.grants == [.app(bundleID: "com.apple.Terminal", tier: .click)])
    }

    @Test("Declining every grant, missing permissions, and unknown targets are typed denials")
    func denials() async throws {
        let host = FakeDisplayTarget(manifest: FakeDisplayTarget.hostManifest, permissions: [.screenCapture: .granted, .accessibility: .denied])
        let registry = DisplayTargetRegistry(targets: [host])
        await #expect(throws: ComputerUseLeaseDenial.permissionsMissing([.accessibility, .postEvents])) {
            _ = try await registry.lease(self.request(target: host.manifest.id), approve: { $0.review.grantable.map(\.grant) })
        }
        await #expect(throws: ComputerUseLeaseDenial.unknownTarget("nope")) {
            _ = try await registry.lease(self.request(target: "nope"), approve: { $0.review.grantable.map(\.grant) })
        }

        let vm = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest)
        let vmRegistry = DisplayTargetRegistry(targets: [vm])
        await #expect(throws: ComputerUseLeaseDenial.grantsDeclined) {
            _ = try await vmRegistry.lease(self.request(target: vm.manifest.id), approve: { _ in nil })
        }
        await #expect(throws: ComputerUseLeaseDenial.grantsDeclined) {
            _ = try await vmRegistry.lease(self.request(target: vm.manifest.id), approve: { _ in [] })
        }
    }

    @Test("A second lease on a held target is target-busy")
    func busyTarget() async throws {
        let vm = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest)
        let registry = DisplayTargetRegistry(targets: [vm])
        _ = try await registry.lease(request(target: vm.manifest.id), approve: { $0.review.grantable.map(\.grant) })
        await #expect(throws: ComputerUseLeaseDenial.targetBusy(holder: "agent")) {
            _ = try await registry.lease(self.request(target: vm.manifest.id), approve: { $0.review.grantable.map(\.grant) })
        }
    }
}
