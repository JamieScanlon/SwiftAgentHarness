#if os(macOS)
import Foundation
import Testing
import SwiftAgentHarness
@testable import SwiftAgentHarnessComputerUseMac

/// Reads the real screen; never sends input. Opt in with `SWIFTAGENTHARNESS_MAC_SMOKE=1` after granting Screen
/// Recording and Accessibility to the process running the tests (the terminal, in dev mode).
@Suite(
    "macOS host smoke test",
    .enabled(if: ProcessInfo.processInfo.environment["SWIFTAGENTHARNESS_MAC_SMOKE"] == "1")
)
struct MacHostSmokeTests {
    @Test("Observing the frontmost app returns a sized screenshot and an accessibility tree")
    func observeFrontmostApp() async throws {
        let target = MacHostDisplayTarget()
        let missing = await target.permissions().missing([.screenCapture, .accessibility])
        try #require(missing.isEmpty, "grant \(missing.map(\.rawValue)) to the test runner first")
        let frontmost = try #require(await MacAppControl.frontmostApp())
        let lease = try await target.lease(LeaseRequest(
            target: target.manifest.id,
            agentID: "smoke",
            grants: [.app(bundleID: frontmost.identity.bundleID, tier: .view)],
            budgets: ComputerUseBudgets(maxSteps: 5, maxDuration: .seconds(60)),
            operatorInitiated: true,
            userPresent: true
        ))
        defer { Task { await target.release(lease, reason: .completed) } }

        let observation = try await target.observe(lease, ObserveRequest(
            modes: [.pixels, .accessibility],
            scope: .display(nil),
            maxImage: ObservationImageLimit(longEdgePx: 1_200)
        ))
        let image = try #require(observation.image)
        #expect(image.data?.isEmpty == false)
        #expect(max(image.geometry.imageSize.width, image.geometry.imageSize.height) <= 1_200)
        #expect(observation.target.app?.bundleID == frontmost.identity.bundleID)
        let tree = try #require(observation.tree)
        #expect(tree.text.contains("obs=\(observation.id)"))
        print("[smoke] \(frontmost.identity.bundleID): \(image.geometry.imageSize.width)×\(image.geometry.imageSize.height), \(tree.elements.count) elements")
    }
}
#endif
