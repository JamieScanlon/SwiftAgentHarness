import Foundation
import Testing
@testable import SwiftAgentHarness

/// Drives a real desktop container. Opt in with `SWIFTAGENTHARNESS_DOCKER_SMOKE=1`; needs Docker and the image built
/// from `docker/desktop` (`docker build -t swiftagentharness/desktop:latest docker/desktop`).
@Suite(
    "Desktop container smoke",
    .enabled(if: ProcessInfo.processInfo.environment["SWIFTAGENTHARNESS_DOCKER_SMOKE"] == "1"),
    .serialized
)
struct DesktopContainerSmokeTests {
    private func containers() async throws -> [String] {
        let listing = try await LocalDisplayCommandRunner().output([
            "docker", "ps", "--all", "--filter", "label=\(DesktopContainer.ownerLabel)=\(DesktopContainer.owner)", "--format", "{{.Names}}",
        ])
        return listing.text.split(whereSeparator: \.isNewline).map(String.init)
    }

    @Test("Starts a desktop, launches and types into an app, streams it, and removes it on release")
    func drives() async throws {
        let server = DisplayLiveViewServer()
        defer { Task { await server.stop() } }
        let target = X11DisplayTarget.desktopContainer(liveView: server)
        let lease = try await target.lease(LeaseRequest(
            target: target.manifest.id,
            agentID: "smoke",
            grants: [.app(bundleID: "XTerm", tier: .full)],
            budgets: ComputerUseBudgets(steps: 50, maxDuration: .seconds(600)),
            operatorInitiated: true,
            userPresent: true
        ))
        let name = try #require(try await containers().first)

        let first = try await target.observe(lease, ObserveRequest(modes: [.pixels], scope: .display(nil), maxImage: ObservationImageLimit(longEdgePx: 1024)))
        #expect(first.image?.geometry.imageSize == ImagePixelSize(width: 1024, height: 640))
        #expect(first.image.flatMap { ManagedBrowserDisplayTarget.pngSize($0.data ?? Data()) } == ImagePixelSize(width: 1024, height: 640))

        let launched = try await target.act(lease, ActionBatch([.launch(app: "xterm")]))
        #expect(launched.first?.effect == .unverifiable, "\(launched)")
        var observed = first
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(250))
            observed = try await target.observe(lease, ObserveRequest(modes: [.pixels], scope: .display(nil)))
            if observed.target.app?.bundleID == "XTerm" { break }
        }
        #expect(observed.target.app == AppIdentity(bundleID: "XTerm"), "\(observed.target)")
        #expect(observed.target.pid != nil)
        #expect(observed.target.processStart != nil)

        let typed = try await target.act(lease, ActionBatch([.type(text: "echo smoke-ok > /home/desktop/out\n")]))
        #expect(typed.first?.effect == .unverifiable, "\(typed)")
        var written = ""
        for _ in 0..<20 where written != "smoke-ok" {
            try await Task.sleep(for: .milliseconds(250))
            written = (try? await LocalDisplayCommandRunner().output(["docker", "exec", name, "cat", "/home/desktop/out"]).text)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        #expect(written == "smoke-ok")

        let viewer = try DisplayLiveViewServerTests.Viewer(try #require(try await target.liveView(lease)))
        _ = try await viewer.status()
        #expect(try await viewer.frame().width == 1280)

        await target.release(lease, reason: .completed)
        var remaining = try await containers()
        for _ in 0..<20 where !remaining.isEmpty {
            try await Task.sleep(for: .milliseconds(250))
            remaining = try await containers()
        }
        #expect(remaining.isEmpty)
    }
}
