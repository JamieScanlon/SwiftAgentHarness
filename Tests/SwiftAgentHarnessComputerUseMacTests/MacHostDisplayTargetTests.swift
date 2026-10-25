#if os(macOS)
import CoreGraphics
import Foundation
import Synchronization
import Testing
import SwiftAgentHarness
@testable import SwiftAgentHarnessComputerUseMac

/// Records events instead of posting them, so tests never type into the user's apps.
final class RecordingEventPoster: MacEventPosting {
    private let posted = Mutex<[(CGEventType, MacInputDelivery)]>([])

    func post(_ event: CGEvent, delivery: MacInputDelivery) {
        posted.withLock { $0.append((event.type, delivery)) }
    }

    var count: Int { posted.withLock { $0.count } }
}

@Suite("macOS host display target")
struct MacHostDisplayTargetTests {
    private func target(
        granted: Set<DisplayPlatformPermission> = [.screenCapture, .accessibility, .postEvents],
        excluded: Set<String> = ["com.example.harness"],
        poster: RecordingEventPoster = RecordingEventPoster()
    ) -> MacHostDisplayTarget {
        MacHostDisplayTarget(configuration: MacHostDisplayTarget.Configuration(
            excludedBundleIDs: excluded,
            permissionProbe: FakePermissionProbe(granted: granted),
            eventPoster: poster
        ))
    }

    private func request(
        grants: [ComputerUseGrant] = [.app(bundleID: "com.apple.TextEdit", tier: .full)],
        delivery: ComputerUseDeliveryPolicy = .backgroundOnly,
        agent: String = "agent"
    ) -> LeaseRequest {
        LeaseRequest(
            target: MacHostDisplayTarget.defaultID,
            agentID: agent,
            grants: grants,
            budgets: ComputerUseBudgets(maxSteps: 10, maxDuration: .seconds(60)),
            delivery: delivery,
            operatorInitiated: true,
            userPresent: true
        )
    }

    @Test("The manifest declares the shared host desktop, its perception, delivery, and required permissions")
    func manifest() {
        let manifest = target().manifest
        #expect(manifest.isolation == .host)
        #expect(manifest.humanPresence == .shared)
        #expect(manifest.platform == "macos")
        #expect(manifest.perception == [.pixels, .accessibility])
        #expect(manifest.delivery == [.background, .foreground])
        #expect(manifest.requires == [.screenCapture, .accessibility, .postEvents])
        #expect(manifest.label.contains("dev mode"))
    }

    @Test("One controller at a time; a second lease is target-busy until release")
    func singleController() async throws {
        let target = target()
        let lease = try await target.lease(request())
        await #expect(throws: DisplayTargetError.targetBusy(holder: "agent")) {
            _ = try await target.lease(self.request(agent: "other"))
        }
        await target.release(lease, reason: .completed)
        _ = try await target.lease(request(agent: "other"))
    }

    @Test("Grants for the harness's own apps are dropped at lease time")
    func excludedGrantsDropped() async throws {
        let lease = try await target().lease(request(grants: [
            .app(bundleID: "com.apple.TextEdit", tier: .full),
            .app(bundleID: "com.example.harness", tier: .full),
        ]))
        #expect(lease.grants == [.app(bundleID: "com.apple.TextEdit", tier: .full)])
    }

    @Test("Permissions are preflighted live on every call")
    func permissions() async {
        let target = target(granted: [.screenCapture])
        #expect(await target.permissions().missing(target.manifest.requires) == [.accessibility, .postEvents])
    }

    @Test("Acting without the lease, or with a stale one, throws lease-not-held")
    func leaseRequired() async throws {
        let target = target()
        let lease = try await target.lease(request())
        await target.release(lease, reason: .completed)
        await #expect(throws: DisplayTargetError.leaseNotHeld) {
            _ = try await target.act(lease, ActionBatch([.wait(milliseconds: 1)]))
        }
    }

    @Test("Waits run; observe-class actions are routed elsewhere and refused here; nothing is posted")
    func waitsAndRefusals() async throws {
        let poster = RecordingEventPoster()
        let target = target(poster: poster)
        let lease = try await target.lease(request())
        let outcomes = try await target.act(lease, ActionBatch([
            .wait(milliseconds: 1),
            .zoom(region: DisplayRect(x: 0, y: 0, width: 1, height: 1), observation: "o_1"),
            .wait(milliseconds: 1),
        ]))
        #expect(outcomes.map(\.effect) == [.confirmed, .refused])
        #expect(poster.count == 0)
    }

    @Test("A wait-for is bounded and reported as unverifiable: the driver does not judge conditions")
    func waitFor() async throws {
        let target = target()
        let lease = try await target.lease(request())
        let outcomes = try await target.act(lease, ActionBatch([.waitFor(condition: "dialog closes", timeoutMilliseconds: 5)]))
        #expect(outcomes.first?.effect == .unverifiable)
        #expect(outcomes.first?.escalation == .observe)
    }

    @Test("Refs and points citing an observation this target never made are refused with an observe escalation")
    func unknownObservation() async throws {
        let poster = RecordingEventPoster()
        let target = target(poster: poster)
        let lease = try await target.lease(request())
        let outcomes = try await target.act(lease, ActionBatch([.click(at: .point(DisplayPoint(x: 10, y: 10), observation: "o_404"))]))
        #expect(outcomes.first?.effect == .refused)
        #expect(outcomes.first?.escalation == .observe)
        #expect(poster.count == 0)
    }

    @Test("While the user has taken over, actions are refused")
    func takeover() async throws {
        let target = target()
        let lease = try await target.lease(request())
        try await target.takeover(lease, on: true)
        let outcomes = try await target.act(lease, ActionBatch([.wait(milliseconds: 1)]))
        #expect(outcomes.first?.effect == .refused)
        try await target.takeover(lease, on: false)
        #expect(try await target.act(lease, ActionBatch([.wait(milliseconds: 1)])).first?.effect == .confirmed)
    }
}
#endif
