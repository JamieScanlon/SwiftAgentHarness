#if os(macOS)
import Foundation
import Synchronization
import Testing
import SwiftAgentHarness
@testable import SwiftAgentHarnessComputerUseMac

/// Stands in for the Mac's power management and session state, so tests never wake or hold the real display.
final class FakeDisplayPower: MacDisplayPowering {
    private struct State {
        var asleep: Bool
        var wakes: Bool
        var locked: Bool
        var nextID: UInt32 = 1
        var held: Set<UInt32> = []
        var holds: [String] = []
    }

    private let state: Mutex<State>

    init(asleep: Bool = false, wakes: Bool = true, locked: Bool = false) {
        state = Mutex(State(asleep: asleep, wakes: wakes, locked: locked))
    }

    func holdAwake(reason: String) -> [UInt32] {
        state.withLock { state in
            state.holds.append(reason)
            if state.wakes { state.asleep = false }
            let ids = [state.nextID, state.nextID + 1]
            state.nextID += 2
            state.held.formUnion(ids)
            return ids
        }
    }

    func release(_ assertions: [UInt32]) {
        state.withLock { $0.held.subtract(assertions) }
    }

    var displayIsAsleep: Bool { state.withLock { $0.asleep } }
    var screenIsLocked: Bool { state.withLock { $0.locked } }

    func setLocked(_ locked: Bool) { state.withLock { $0.locked = locked } }
    var held: Set<UInt32> { state.withLock { $0.held } }
    var holds: [String] { state.withLock { $0.holds } }
}

@Suite("macOS host display target: waking the display and the lock screen")
struct MacDisplayWakeTests {
    private func target(_ power: FakeDisplayPower, wakesDisplay: Bool, poster: RecordingEventPoster = RecordingEventPoster()) -> MacHostDisplayTarget {
        var configuration = MacHostDisplayTarget.Configuration(
            excludedBundleIDs: [],
            permissionProbe: FakePermissionProbe(granted: [.screenCapture, .accessibility, .postEvents]),
            eventPoster: poster,
            displayPower: power,
            wakeTimeout: .milliseconds(100)
        )
        configuration.wakesDisplay = wakesDisplay
        return MacHostDisplayTarget(configuration: configuration)
    }

    private func request(agent: String = "agent") -> LeaseRequest {
        LeaseRequest(
            target: MacHostDisplayTarget.defaultID,
            agentID: agent,
            grants: [.app(bundleID: "com.apple.TextEdit", tier: .full)],
            budgets: ComputerUseBudgets(steps: 10, maxDuration: .seconds(60)),
            initiator: .operator,
            userPresent: true
        )
    }

    @Test("Waking the display is off by default")
    func offByDefault() {
        #expect(MacHostDisplayTarget.Configuration().wakesDisplay == false)
    }

    @Test("With waking on, a lease wakes the display and keeps it awake until release")
    func wakesForLease() async throws {
        let power = FakeDisplayPower(asleep: true)
        let target = target(power, wakesDisplay: true)
        let lease = try await target.lease(request())
        #expect(power.holds == ["Computer use: agent"])
        #expect(power.held.count == 2)
        #expect(!power.displayIsAsleep)
        await target.release(lease, reason: .completed)
        #expect(power.held.isEmpty, "the Mac's own sleep and lock settings apply again")
    }

    @Test("A display that doesn't report waking in time still leases; capture says if it can't see the screen")
    func slowWake() async throws {
        let power = FakeDisplayPower(asleep: true, wakes: false)
        let target = target(power, wakesDisplay: true)
        let lease = try await target.lease(request())
        #expect(power.held.count == 2)
        await target.release(lease, reason: .completed)
        #expect(power.held.isEmpty)
    }

    @Test("A locked Mac refuses the lease with a reason the user can act on, and keeps no lock or assertion")
    func lockedLease() async throws {
        for wakesDisplay in [true, false] {
            let power = FakeDisplayPower(locked: true)
            let target = target(power, wakesDisplay: wakesDisplay)
            await #expect(throws: DisplayTargetError.targetUnavailable(MacHostDisplayTarget.lockedReason)) {
                _ = try await target.lease(request())
            }
            #expect(power.held.isEmpty)
            power.setLocked(false)
            let other = try await target.lease(request(agent: "other"))
            await target.release(other, reason: .completed)
        }
    }

    @Test("With waking off, leases leave power management alone")
    func offLeavesPowerAlone() async throws {
        let power = FakeDisplayPower(asleep: true)
        let target = target(power, wakesDisplay: false)
        let lease = try await target.lease(request())
        await target.release(lease, reason: .completed)
        #expect(power.holds.isEmpty)
        #expect(power.displayIsAsleep)
    }

    @Test("A Mac that locks during a lease refuses observing and acting, so nothing is typed into the lock screen")
    func lockedMidLease() async throws {
        let power = FakeDisplayPower()
        let poster = RecordingEventPoster()
        let target = target(power, wakesDisplay: true, poster: poster)
        let lease = try await target.lease(request())
        power.setLocked(true)
        let unavailable = DisplayTargetError.targetUnavailable(MacHostDisplayTarget.lockedReason)
        await #expect(throws: unavailable) {
            _ = try await target.observe(lease, ObserveRequest(modes: [.pixels], scope: .display(nil)))
        }
        await #expect(throws: unavailable) {
            _ = try await target.act(lease, ActionBatch([.type(text: "Hello World!")]))
        }
        #expect(poster.count == 0)
        await target.release(lease, reason: .completed)
    }

    @Test("A capture that finds no display reports a display that is asleep or disconnected")
    func noDisplay() {
        #expect(MacHostDisplayTarget.unavailable(MacCaptureError.noDisplay) as? DisplayTargetError
            == .targetUnavailable(MacHostDisplayTarget.noDisplayReason))
        #expect(MacHostDisplayTarget.unavailable(MacCaptureError.encodingFailed) as? MacCaptureError == .encodingFailed)
    }
}
#endif
