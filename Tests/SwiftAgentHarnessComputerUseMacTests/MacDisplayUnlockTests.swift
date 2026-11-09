#if os(macOS)
import Foundation
import Testing
import SwiftAgentHarness
@testable import SwiftAgentHarnessComputerUseMac

@Suite("macOS host display target: waiting for an unlock, and locking again after")
struct MacDisplayUnlockTests {
    private func target(
        _ power: FakeDisplayPower,
        unlockTimeout: Duration = .zero,
        relocksOnRelease: Bool = false,
        wakesDisplay: Bool = true
    ) -> MacHostDisplayTarget {
        var configuration = MacHostDisplayTarget.Configuration(
            excludedBundleIDs: [],
            permissionProbe: FakePermissionProbe(granted: [.screenCapture, .accessibility, .postEvents]),
            eventPoster: RecordingEventPoster(),
            displayPower: power,
            wakeTimeout: .milliseconds(100)
        )
        configuration.wakesDisplay = wakesDisplay
        configuration.unlockTimeout = unlockTimeout
        configuration.relocksOnRelease = relocksOnRelease
        return MacHostDisplayTarget(configuration: configuration)
    }

    private func request(targetLocked: Bool = false) -> LeaseRequest {
        var request = LeaseRequest(
            target: MacHostDisplayTarget.defaultID,
            agentID: "agent",
            grants: [.app(bundleID: "com.apple.TextEdit", tier: .full)],
            budgets: ComputerUseBudgets(steps: 10, maxDuration: .seconds(60)),
            initiator: .operator,
            userPresent: true
        )
        request.targetLocked = targetLocked
        return request
    }

    @Test("By default a lease doesn't wait for an unlock, and release leaves the display alone")
    func defaults() {
        let configuration = MacHostDisplayTarget.Configuration()
        #expect(configuration.unlockTimeout == .zero)
        #expect(configuration.relocksOnRelease == false)
    }

    @Test("The target says whether the Mac is locked")
    func reportsLock() async {
        let power = FakeDisplayPower(locked: true)
        let target = target(power)
        #expect(await target.isLocked())
        power.setLocked(false)
        #expect(await target.isLocked() == false)
    }

    @Test("A lease waits for an unlock the user has started, holding the display awake meanwhile")
    func waitsForUnlock() async throws {
        let power = FakeDisplayPower(locked: true)
        let target = target(power, unlockTimeout: .seconds(5))
        let unlocking = Task {
            try await Task.sleep(for: .milliseconds(150))
            #expect(power.held.count == 2, "the display stays awake while the user unlocks it")
            power.setLocked(false)
        }
        let lease = try await target.lease(request(targetLocked: true))
        try await unlocking.value
        await target.release(lease, reason: .completed)
    }

    @Test("A lease whose unlock doesn't come in time is refused as locked, keeping no lock or assertion")
    func unlockTimesOut() async throws {
        let power = FakeDisplayPower(locked: true)
        let target = target(power, unlockTimeout: .milliseconds(150))
        let start = ContinuousClock.now
        await #expect(throws: DisplayTargetError.targetUnavailable(MacHostDisplayTarget.lockedReason)) {
            _ = try await target.lease(request(targetLocked: true))
        }
        #expect(ContinuousClock.now - start >= .milliseconds(150))
        #expect(power.held.isEmpty)
        power.setLocked(false)
        let other = try await target.lease(request())
        await target.release(other, reason: .completed)
    }

    @Test("A Mac that locks mid-lease is refused at once: the wait is only for the unlock that let the session start")
    func midLeaseDoesNotWait() async throws {
        let power = FakeDisplayPower()
        let target = target(power, unlockTimeout: .seconds(30))
        let lease = try await target.lease(request())
        power.setLocked(true)
        let start = ContinuousClock.now
        await #expect(throws: DisplayTargetError.targetUnavailable(MacHostDisplayTarget.lockedReason)) {
            _ = try await target.act(lease, ActionBatch([.type(text: "x")]))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
        await target.release(lease, reason: .completed)
    }

    @Test("A session whose user found the Mac locked sleeps the display at release, after letting it sleep")
    func relocksWhenFoundLocked() async throws {
        let power = FakeDisplayPower()
        let target = target(power, relocksOnRelease: true)
        let lease = try await target.lease(request(targetLocked: true))
        await target.release(lease, reason: .completed)
        #expect(power.sleeps == [[]], "the wake assertions are gone before the display sleeps")
        await target.release(lease, reason: .completed)
        #expect(power.sleeps.count == 1, "release is idempotent")
    }

    @Test("A Mac still locked when the lease began is locked again at release, even if the grant said otherwise")
    func relocksWhenLockedAtLease() async throws {
        let power = FakeDisplayPower(locked: true)
        let target = target(power, unlockTimeout: .seconds(5), relocksOnRelease: true)
        let unlocking = Task {
            try await Task.sleep(for: .milliseconds(100))
            power.setLocked(false)
        }
        let lease = try await target.lease(request(targetLocked: false))
        try await unlocking.value
        await target.release(lease, reason: .cancelled)
        #expect(power.sleeps.count == 1)
    }

    @Test("A Mac that was unlocked all along is left awake at release")
    func leavesUnlockedMacAlone() async throws {
        let power = FakeDisplayPower()
        let target = target(power, relocksOnRelease: true)
        let lease = try await target.lease(request())
        await target.release(lease, reason: .completed)
        #expect(power.sleeps.isEmpty)
        #expect(!power.displayIsAsleep)
    }

    @Test("With relocking off, a Mac found locked is left as the session ends it")
    func relockOff() async throws {
        let power = FakeDisplayPower()
        let target = target(power)
        let lease = try await target.lease(request(targetLocked: true))
        await target.release(lease, reason: .completed)
        #expect(power.sleeps.isEmpty)
    }

    @Test("A lease refused as locked doesn't sleep the display: it never had the Mac")
    func refusedLeaseDoesNotRelock() async throws {
        let power = FakeDisplayPower(locked: true)
        let target = target(power, relocksOnRelease: true)
        await #expect(throws: DisplayTargetError.self) {
            _ = try await target.lease(request(targetLocked: true))
        }
        #expect(power.sleeps.isEmpty)
    }
}
#endif
