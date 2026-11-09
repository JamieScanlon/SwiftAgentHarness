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
        wakesDisplay: Bool = true,
        developmentMode: Bool = false,
        relockMarker: URL? = nil
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
        configuration.embeddedInSignedApp = !developmentMode
        configuration.relockMarker = relockMarker
        return MacHostDisplayTarget(configuration: configuration)
    }

    private static func markerURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("relock-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("relock-pending.json")
    }

    private static func events(_ target: MacHostDisplayTarget, _ lease: Lease) async -> Task<[DisplayTargetEvent], Never> {
        let stream = await target.events(lease)
        return Task {
            var received: [DisplayTargetEvent] = []
            for await event in stream { received.append(event) }
            return received
        }
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

    @Test("When the explicit lock doesn't take, release falls back to sleeping the display, which locks it")
    func relockFallsBackToSleep() async throws {
        let power = FakeDisplayPower(lockTakes: false, sleepLocks: true)
        let target = target(power)
        let lease = try await target.lease(request(foundLocked: true))
        let events = await Self.events(target, lease)
        await target.release(lease, reason: .completed)
        #expect(power.locks.count == 1)
        #expect(power.sleeps.count == 1)
        #expect(power.screenIsLocked)
        #expect(await events.value.isEmpty, "the Mac is locked, so nothing to say")
    }

    @Test("A Mac that still isn't locked after the fallback is reported to the holder, never left silent")
    func relockFailureReported() async throws {
        let power = FakeDisplayPower(lockTakes: false)
        let target = target(power)
        let lease = try await target.lease(request(foundLocked: true))
        let events = await Self.events(target, lease)
        await target.release(lease, reason: .completed)
        #expect(power.sleeps.count == 1)
        #expect(await events.value == [.relockFailed(MacHostDisplayTarget.relockFailedNotice)])
        #expect(MacHostDisplayTarget.relockFailedNotice == "Your Mac could not be locked after the run and may be unlocked.")
    }

    @Test("In development mode a locked Mac is refused at once: the dialog isn't offered an unlock and the lease doesn't wait")
    func developmentModeHasNoUnlockFlow() async throws {
        let power = FakeDisplayPower(locked: true)
        let target = target(power, unlockTimeout: .seconds(30), developmentMode: true)
        #expect(await target.isLocked() == false, "answers as a target with no unlock flow, so the dialog never offers one")
        let start = ContinuousClock.now
        await #expect(throws: DisplayTargetError.targetUnavailable(MacHostDisplayTarget.lockedReason)) {
            _ = try await target.lease(request(foundLocked: true))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test("A session that found the Mac locked records a relock-pending marker before its first action, cleared by a verified relock")
    func relockMarker() async throws {
        let marker = Self.markerURL()
        let power = FakeDisplayPower()
        let target = target(power, relockMarker: marker)
        let lease = try await target.lease(request(foundLocked: true))
        let pending = try JSONDecoder().decode(MacRelockMarker.self, from: Data(contentsOf: marker))
        #expect(pending.leaseID == lease.id)
        await target.release(lease, reason: .completed)
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        power.setLocked(false)
        let unlockedAllAlong = try await target.lease(request())
        #expect(!FileManager.default.fileExists(atPath: marker.path), "nothing to relock, so no marker")
        await target.release(unlockedAllAlong, reason: .completed)
    }

    @Test("A relock that can't be verified keeps the marker, so a restarted host tries again")
    func failedRelockKeepsMarker() async throws {
        let marker = Self.markerURL()
        let power = FakeDisplayPower(lockTakes: false)
        let target = target(power, relockMarker: marker)
        let lease = try await target.lease(request(foundLocked: true))
        await target.release(lease, reason: .completed)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("A host restarted after a crash finds the marker, locks the Mac, and clears it")
    func recoversAfterCrash() async throws {
        let marker = Self.markerURL()
        let crashed = target(FakeDisplayPower(), relockMarker: marker)
        _ = try await crashed.lease(request(foundLocked: true))
        #expect(FileManager.default.fileExists(atPath: marker.path))

        let power = FakeDisplayPower()
        let restarted = target(power, relockMarker: marker)
        #expect(await restarted.recoverPendingRelock() == .relocked)
        #expect(power.locks.count == 1)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(await restarted.recoverPendingRelock() == .nothingPending)
    }

    @Test("A restarted host that can't lock the Mac reports it, and clears the marker once it has said so")
    func recoveryFailureReported() async throws {
        let marker = Self.markerURL()
        _ = try await target(FakeDisplayPower(), relockMarker: marker).lease(request(foundLocked: true))
        let power = FakeDisplayPower(lockTakes: false)
        let restarted = target(power, relockMarker: marker)
        #expect(await restarted.recoverPendingRelock() == .failed(MacHostDisplayTarget.relockFailedNotice))
        #expect(power.sleeps.count == 1)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
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
