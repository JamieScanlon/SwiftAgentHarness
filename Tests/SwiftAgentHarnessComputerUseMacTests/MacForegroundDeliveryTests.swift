#if os(macOS)
import CoreGraphics
import Foundation
import Synchronization
import Testing
import SwiftAgentHarness
@testable import SwiftAgentHarnessComputerUseMac

/// Answers each probe with the next scripted state.
final class ScriptedDeliveryProbe: MacDeliveryProbing {
    private let states: Mutex<[String?]>

    init(_ states: [String?]) {
        self.states = Mutex(states)
    }

    func state(of pid: pid_t, app: AppIdentity) async -> String? {
        states.withLock { $0.isEmpty ? "unchanged" : $0.removeFirst() }
    }
}

@Suite("macOS foreground delivery: background first, foreground on a known trigger")
struct MacForegroundDeliveryTests {
    typealias D = MacDesktopFixtures

    static let game = MacRunningApp(pid: 90_010, identity: AppIdentity(bundleID: "com.example.Game", category: "public.app-category.action-games"), launchDate: D.launched)
    static let chrome = MacRunningApp(pid: 90_011, identity: AppIdentity(bundleID: "com.google.Chrome"), launchDate: D.launched)

    private func target(
        _ state: FakeMacWorkspace.State,
        probe: ScriptedDeliveryProbe,
        poster: RecordingEventPoster
    ) -> MacHostDisplayTarget {
        MacHostDisplayTarget(configuration: MacHostDisplayTarget.Configuration(
            excludedBundleIDs: ["com.example.harness"],
            permissionProbe: FakePermissionProbe(granted: [.screenCapture, .accessibility, .postEvents]),
            eventPoster: poster,
            workspace: FakeMacWorkspace(state),
            deliveryProbe: probe
        ))
    }

    private func lease(_ target: MacHostDisplayTarget, grants: [ComputerUseGrant], delivery: ComputerUseDeliveryPolicy = .foregroundAllowed) async throws -> Lease {
        try await target.lease(LeaseRequest(
            target: MacHostDisplayTarget.defaultID,
            agentID: "agent",
            grants: grants,
            budgets: ComputerUseBudgets(steps: 10, maxDuration: .seconds(60)),
            delivery: delivery,
            initiator: .operator,
            userPresent: true
        ))
    }

    private static let textEditOnly = FakeMacWorkspace.State(
        apps: [D.harness, D.textEdit, D.notes],
        frontmost: D.textEdit.pid,
        windows: [D.textEditWindow, D.notesWindow]
    )

    private func click(_ x: Double, _ y: Double, button: MouseButton = .left) -> ComputerAction {
        .click(at: .point(DisplayPoint(x: x, y: y), observation: "o_seed"), button: button)
    }

    @Test("Canvas and game apps go foreground from the first action; Chromium only for right-clicks")
    func upFront() {
        #expect(MacForegroundPolicy.upFront(Self.game.identity, for: click(1, 1)))
        #expect(MacForegroundPolicy.upFront(AppIdentity(bundleID: "com.figma.Desktop", category: "public.app-category.graphics-design"), for: nil))
        #expect(MacForegroundPolicy.upFront(Self.chrome.identity, for: click(1, 1, button: .right)))
        #expect(!MacForegroundPolicy.upFront(Self.chrome.identity, for: click(1, 1)))
        #expect(!MacForegroundPolicy.upFront(D.textEdit.identity, for: click(1, 1, button: .right)))
    }

    @Test("A background action that changes nothing is a suspected no-op that moves the app's later actions to the foreground")
    func evidence() async throws {
        let poster = RecordingEventPoster()
        let target = target(Self.textEditOnly, probe: ScriptedDeliveryProbe(["same", "same"]), poster: poster)
        let lease = try await lease(target, grants: [.app(bundleID: "com.apple.TextEdit", tier: .full)])
        await target.seedObservation("o_seed", pid: D.textEdit.pid, processStart: D.launched)

        let first = try #require(try await target.act(lease, ActionBatch([click(400, 400), click(410, 410)])).first)
        #expect(first.effect == .suspectedNoop)
        #expect(first.escalation == .foreground)
        #expect(poster.deliveries.allSatisfy { $0 == .process(D.textEdit.pid) }, "the batch stops; nothing is re-delivered")
        let posted = poster.count

        let second = try #require(try await target.act(lease, ActionBatch([click(410, 410)])).first)
        #expect(second.effect == .unverifiable)
        #expect(poster.deliveries.dropFirst(posted).allSatisfy { $0 == .foreground })
    }

    @Test("A background action that changed the app stays in the background")
    func landed() async throws {
        let poster = RecordingEventPoster()
        let target = target(Self.textEditOnly, probe: ScriptedDeliveryProbe(["before", "after", "after", "later"]), poster: poster)
        let lease = try await lease(target, grants: [.app(bundleID: "com.apple.TextEdit", tier: .full)])
        await target.seedObservation("o_seed", pid: D.textEdit.pid, processStart: D.launched)
        let outcomes = try await target.act(lease, ActionBatch([click(400, 400), click(410, 410)]))
        #expect(outcomes.map(\.effect) == [.unverifiable, .unverifiable])
        #expect(poster.deliveries.allSatisfy { $0 == .process(D.textEdit.pid) })
    }

    @Test("Without foreground consent there is no probe and no escalation")
    func backgroundOnly() async throws {
        let poster = RecordingEventPoster()
        let target = target(Self.textEditOnly, probe: ScriptedDeliveryProbe(["same", "same"]), poster: poster)
        let lease = try await lease(target, grants: [.app(bundleID: "com.apple.TextEdit", tier: .full)], delivery: .backgroundOnly)
        await target.seedObservation("o_seed", pid: D.textEdit.pid, processStart: D.launched)
        let outcome = try #require(try await target.act(lease, ActionBatch([click(400, 400)])).first)
        #expect(outcome.effect == .unverifiable)
        #expect(outcome.escalation == nil)
    }

    @Test("A game gets foreground input from its first action, and a foreground click covered by an ungranted window is refused")
    func hostileAndHitTest() async throws {
        let gameWindow = MacWindowEntry(pid: Self.game.pid, layer: 0, bounds: CGRect(x: 0, y: 0, width: 800, height: 800))
        let poster = RecordingEventPoster()
        let state = FakeMacWorkspace.State(apps: [D.harness, Self.game, D.notes], frontmost: Self.game.pid, windows: [D.notesWindow, gameWindow])
        let target = target(state, probe: ScriptedDeliveryProbe([]), poster: poster)
        let lease = try await lease(target, grants: [.app(bundleID: "com.example.Game", tier: .full)])
        await target.seedObservation("o_seed", pid: Self.game.pid, processStart: D.launched)

        let open = try #require(try await target.act(lease, ActionBatch([click(700, 700)])).first)
        #expect(open.effect == .unverifiable)
        #expect(poster.deliveries.allSatisfy { $0 == .foreground })

        let covered = try #require(try await target.act(lease, ActionBatch([click(150, 150)])).first)
        #expect(covered.effect == .refused)
        #expect(covered.evidence?.contains("com.apple.Notes") == true, "\(covered)")
        #expect(MacAppFocus.topmostOwner(at: CGPoint(x: 150, y: 150), windows: state.windows, ignoring: D.harness.pid) == D.notes.pid)
    }
}
#endif
