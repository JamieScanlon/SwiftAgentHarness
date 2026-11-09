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
        wakesDisplay: Bool = true
    ) -> MacHostDisplayTarget {
        var configuration = MacHostDisplayTarget.Configuration(
            excludedBundleIDs: [],
            permissionProbe: FakePermissionProbe(granted: [.screenCapture, .accessibility, .postEvents]),
            eventPoster: RecordingEventPoster(),
            displayPower: power,
            wakeTimeout: .milliseconds(100),
            relockTimeout: .milliseconds(100)
        )
        configuration.wakesDisplay = wakesDisplay
        configuration.unlockTimeout = unlockTimeout
        return MacHostDisplayTarget(configuration: configuration)
    }

    private func request(foundLocked: Bool = false, isHolderAlive: @escaping @Sendable () async -> Bool = { true }) -> LeaseRequest {
        LeaseRequest(
            target: MacHostDisplayTarget.defaultID,
            agentID: "agent",
            grants: [.app(bundleID: "com.apple.TextEdit", tier: .full)],
            budgets: ComputerUseBudgets(steps: 10, maxDuration: .seconds(60)),
            initiator: .operator,
            userPresent: true,
            foundLocked: foundLocked,
            isHolderAlive: isHolderAlive
        )
    }

    @Test("By default a lease doesn't wait for an unlock")
    func defaults() {
        #expect(MacHostDisplayTarget.Configuration().unlockTimeout == .zero)
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
        let lease = try await target.lease(request(foundLocked: true))
        try await unlocking.value
        await target.release(lease, reason: .completed)
    }

    @Test("A lease whose unlock doesn't come in time is refused as locked, keeping no lock or assertion")
    func unlockTimesOut() async throws {
        let power = FakeDisplayPower(locked: true)
        let target = target(power, unlockTimeout: .milliseconds(150))
        let start = ContinuousClock.now
        await #expect(throws: DisplayTargetError.targetUnavailable(MacHostDisplayTarget.lockedReason)) {
            _ = try await target.lease(request(foundLocked: true))
        }
        #expect(ContinuousClock.now - start >= .milliseconds(150))
        #expect(power.held.isEmpty)
        #expect(power.locks.isEmpty, "the Mac is still locked; nothing to put back")
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

    @Test("A session the user unlocked for keeps the display awake until release, even with waking off")
    func awakeWhileUnlocked() async throws {
        let power = FakeDisplayPower()
        let target = target(power, wakesDisplay: false)
        let lease = try await target.lease(request(foundLocked: true))
        #expect(power.held.count == 2, "the dialog said it stays awake until the run ends")
        await target.release(lease, reason: .completed)
        #expect(power.held.isEmpty)
    }

    @Test("A session that found the Mac locked locks it explicitly at release, on every release path, after letting it sleep")
    func relocksWhenFoundLocked() async throws {
        for reason in [ReleaseReason.completed, .cancelled, .killSwitch, .holderLost, .targetUnavailable] {
            let power = FakeDisplayPower()
            let target = target(power)
            let lease = try await target.lease(request(foundLocked: true))
            await target.release(lease, reason: reason)
            #expect(power.locks == [[]], "locked with no wake assertion left, after \(reason)")
            #expect(power.screenIsLocked)
            #expect(power.sleeps.isEmpty, "the explicit lock took, so no fallback")
            await target.release(lease, reason: reason)
            #expect(power.locks.count == 1, "release is idempotent")
        }
    }

    @Test("When the explicit lock doesn't take, release falls back to sleeping the display")
    func relockFallsBackToSleep() async throws {
        let power = FakeDisplayPower(lockTakes: false)
        let target = target(power)
        let lease = try await target.lease(request(foundLocked: true))
        await target.release(lease, reason: .completed)
        #expect(power.locks.count == 1)
        #expect(power.sleeps.count == 1)
    }

    @Test("A Mac still locked when the lease began is locked again at release, even if the grant said otherwise")
    func relocksWhenLockedAtLease() async throws {
        let power = FakeDisplayPower(locked: true)
        let target = target(power, unlockTimeout: .seconds(5))
        let unlocking = Task {
            try await Task.sleep(for: .milliseconds(100))
            power.setLocked(false)
        }
        let lease = try await target.lease(request(foundLocked: false))
        try await unlocking.value
        await target.release(lease, reason: .cancelled)
        #expect(power.locks.count == 1)
    }

    @Test("A Mac that was unlocked all along is left unlocked and awake at release")
    func leavesUnlockedMacAlone() async throws {
        let power = FakeDisplayPower()
        let target = target(power)
        let lease = try await target.lease(request())
        await target.release(lease, reason: .completed)
        #expect(power.locks.isEmpty)
        #expect(power.sleeps.isEmpty)
        #expect(!power.screenIsLocked)
    }

    @Test("A lease taken over from a holder that died is locked again first, if that holder found it locked")
    func deadHolderRelocks() async throws {
        let power = FakeDisplayPower()
        let target = target(power)
        _ = try await target.lease(request(foundLocked: true, isHolderAlive: { false }))
        await #expect(throws: DisplayTargetError.targetUnavailable(MacHostDisplayTarget.lockedReason)) {
            _ = try await target.lease(request())
        }
        #expect(power.locks.count == 1, "the dead holder's session never released, so the next lease locks it")
    }
}
#endif
