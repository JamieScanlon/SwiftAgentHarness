#if os(macOS)
import CoreGraphics
import Foundation
import Testing
import SwiftAgentHarness
@testable import SwiftAgentHarnessComputerUseMac

@Suite("macOS live view of granted apps")
struct MacLiveViewTests {
    typealias Desktop = MacDesktopFixtures

    // MARK: - Frames

    @Test("Where an ungranted window covers a granted one, that part is blanked; granted windows in front stay")
    func occluders() {
        let granted: Set<pid_t> = [Desktop.textEdit.pid, Desktop.notes.pid]
        let front = MacWindowEntry(pid: Desktop.notes.pid, layer: 0, bounds: CGRect(x: 300, y: 300, width: 100, height: 100))
        let covering = MacWindowEntry(pid: Desktop.harness.pid, layer: 0, bounds: CGRect(x: 250, y: 250, width: 200, height: 200))
        let behind = MacWindowEntry(pid: Desktop.textEdit.pid, layer: 0, bounds: CGRect(x: 200, y: 200, width: 600, height: 500))
        let clear = MacWindowEntry(pid: Desktop.dock.pid, layer: 25, bounds: CGRect(x: 0, y: 0, width: 2000, height: 2000), alpha: 0)
        let below = MacWindowEntry(pid: Desktop.dock.pid, layer: 0, bounds: CGRect(x: 0, y: 0, width: 900, height: 900))

        let blanked = MacLiveView.occluders(windows: [clear, front, covering, behind, below], grantedPIDs: granted)
        let area = blanked.reduce(0) { $0 + $1.width * $1.height }
        #expect(area == CGFloat(200 * 200 - 100 * 100), "the covering window, minus the granted window in front of it")
        #expect(blanked.allSatisfy { !$0.intersects(front.bounds) })
        #expect(blanked.allSatisfy { covering.bounds.contains($0) })
        #expect(MacLiveView.occluders(windows: [behind, below], grantedPIDs: granted).isEmpty, "windows below a granted one never show")
    }

    @Test("Display points map to frame pixels, and blanked areas are painted over")
    func painting() throws {
        let space = MacLiveFrameSpace(display: CGRect(x: 100, y: 0, width: 200, height: 100), frame: ImagePixelSize(width: 100, height: 50))
        #expect(space.pixelRect(for: CGRect(x: 120, y: 20, width: 40, height: 20)) == CGRect(x: 10, y: 10, width: 20, height: 10))

        let white = try #require(MacLiveView.blank(size: space.frame, gray: 1))
        let painted = try #require(MacLiveView.painting(white, occluders: [CGRect(x: 120, y: 20, width: 40, height: 20)], space: space))
        #expect(Self.gray(painted, x: 15, y: 12) < 0.9, "inside the blanked area")
        #expect(Self.gray(painted, x: 50, y: 40) > 0.99, "outside it")
        #expect(Self.gray(painted, x: 15, y: 40) > 0.99, "rows count from the top, as the display does")
    }

    /// The gray level at a pixel, counting rows from the top.
    private static func gray(_ image: CGImage, x: Int, y: Int) -> Double {
        var pixel: [UInt8] = [0, 0, 0, 0]
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return Double(pixel[0]) / 255
    }

    // MARK: - Keys

    @Test("A viewer's key reads as the combos it could be, by its key and by its physical code")
    func combos() {
        #expect(MacLiveInput.combos(key: "Tab", code: "Tab", modifiers: [.cmd]) == [KeyCombo(modifiers: [.cmd], key: "tab")])
        #expect(MacLiveInput.combos(key: " ", code: "Space", modifiers: [.cmd]) == [KeyCombo(modifiers: [.cmd], key: "space")])
        #expect(MacLiveInput.combos(key: "≥", code: "Period", modifiers: [.ctrl, .option, .cmd]).contains(.defaultStopKey))
        #expect(MacLiveInput.combos(key: "Shift", code: "ShiftLeft", modifiers: [.shift]).isEmpty, "a modifier alone is no combo")
    }

    // MARK: - Input

    /// TextEdit's window, with Notes' over part of it, and the harness's own window over another part. The frame
    /// shows the display one to one.
    private static func desktop(frontmost: pid_t = Desktop.textEdit.pid) -> FakeMacWorkspace.State {
        FakeMacWorkspace.State(
            apps: [Desktop.harness, Desktop.textEdit, Desktop.notes, Desktop.dock],
            frontmost: frontmost,
            windows: [
                Desktop.dockWindow,
                MacWindowEntry(pid: Desktop.harness.pid, layer: 0, bounds: CGRect(x: 0, y: 0, width: 300, height: 300)),
                MacWindowEntry(pid: Desktop.notes.pid, layer: 0, bounds: CGRect(x: 600, y: 200, width: 200, height: 200)),
                Desktop.textEditWindow,
            ]
        )
    }

    private static let space = MacLiveFrameSpace(display: CGRect(x: 0, y: 0, width: 1000, height: 1000), frame: ImagePixelSize(width: 1000, height: 1000))

    private func target(
        _ state: FakeMacWorkspace.State = Self.desktop(),
        mode: MacHostDisplayTarget.LiveFrames = .grantedApps,
        grants: [ComputerUseGrant] = [.app(bundleID: Desktop.textEdit.identity.bundleID, tier: .view)],
        remoteTakeoverBundleIDs: Set<String> = [],
        poster: RecordingEventPoster
    ) async throws -> (MacHostDisplayTarget, Lease) {
        var configuration = MacHostDisplayTarget.Configuration(
            excludedBundleIDs: [Desktop.harness.identity.bundleID],
            permissionProbe: FakePermissionProbe(granted: [.screenCapture, .accessibility, .postEvents]),
            eventPoster: poster,
            workspace: FakeMacWorkspace(state)
        )
        configuration.liveFrames = mode
        configuration.remoteTakeoverBundleIDs = remoteTakeoverBundleIDs
        let target = MacHostDisplayTarget(configuration: configuration)
        let lease = try await target.lease(LeaseRequest(
            target: MacHostDisplayTarget.defaultID, agentID: "agent", grants: grants,
            budgets: ComputerUseBudgets(steps: 10, maxDuration: .seconds(60)), initiator: .operator, userPresent: true
        ))
        await target.noteLiveFrame(Self.space)
        try await target.takeover(lease, on: true)
        return (target, lease)
    }

    private static func mouse(_ action: DisplayLiveViewInput.MouseAction, _ x: Double, _ y: Double) -> DisplayLiveViewInput {
        .mouse(action, x: x, y: y, button: action == .move ? nil : .left, clickCount: 1, modifiers: [])
    }

    private static func key(_ key: String, code: String, text: String? = nil, _ modifiers: Set<KeyModifier> = []) -> DisplayLiveViewInput {
        .key(down: true, key: key, code: code, keyCode: 0, text: text, modifiers: modifiers)
    }

    private static let terminal = MacRunningApp(pid: 90_010, identity: AppIdentity(bundleID: "com.apple.Terminal"), launchDate: Desktop.launched)

    /// Terminal's window where TextEdit's would be, in front.
    private static func terminalDesktop() -> FakeMacWorkspace.State {
        FakeMacWorkspace.State(
            apps: [Desktop.harness, terminal, Desktop.dock],
            frontmost: terminal.pid,
            windows: [Desktop.dockWindow, MacWindowEntry(pid: terminal.pid, layer: 0, bounds: Desktop.textEditWindow.bounds)]
        )
    }

    @Test("Granted-apps frames declare a stream; a click reaches only the handoff app's window, never one over it")
    func pointer() async throws {
        let poster = RecordingEventPoster()
        let (target, lease) = try await target(poster: poster)
        #expect(target.manifest.observerAccess == .stream)
        try await target.liveInput(lease, Self.mouse(.down, 400, 500))
        #expect(poster.count == 2, "TextEdit's window, granted even at view: the user isn't held to the agent's tier")
        try await target.liveInput(lease, Self.mouse(.up, 400, 500))
        let afterClick = poster.count
        for point in [(650.0, 250.0), (250.0, 250.0), (500.0, 670.0), (950.0, 50.0)] {
            try await target.liveInput(lease, Self.mouse(.down, point.0, point.1))
            try await target.liveInput(lease, .wheel(x: point.0, y: point.1, dx: 0, dy: 40, modifiers: []))
        }
        #expect(poster.count == afterClick, "Notes, the harness's own window, the Dock, and the bare desktop are all refused")
        await target.release(lease, reason: .completed)
    }

    @Test("Remote input reaches only the app the handoff is for, not every granted app")
    func handoffAppOnly() async throws {
        let poster = RecordingEventPoster()
        let (target, lease) = try await target(
            grants: [
                .app(bundleID: Desktop.textEdit.identity.bundleID, tier: .full),
                .app(bundleID: Desktop.notes.identity.bundleID, tier: .full),
            ],
            poster: poster
        )
        try await target.liveInput(lease, Self.mouse(.down, 650, 250))
        #expect(poster.count == 0, "Notes is granted, but the handoff is for TextEdit")
        try await target.liveInput(lease, Self.mouse(.down, 400, 500))
        #expect(poster.count == 2)
        await target.release(lease, reason: .completed)
    }

    @Test("A drag can't carry out of the handoff app's window; its release lands where it last was allowed")
    func drag() async throws {
        let poster = RecordingEventPoster()
        let (target, lease) = try await target(poster: poster)
        try await target.liveInput(lease, Self.mouse(.down, 400, 500))
        try await target.liveInput(lease, Self.mouse(.move, 450, 500))
        #expect(poster.count == 3)
        try await target.liveInput(lease, Self.mouse(.move, 650, 250))
        #expect(poster.count == 3, "the move into Notes isn't posted")
        try await target.liveInput(lease, Self.mouse(.up, 650, 250))
        #expect(poster.count == 4, "the button is still released, so nothing stays held")
        #expect(await target.lastLivePoint == CGPoint(x: 450, y: 500))
        await target.release(lease, reason: .completed)
    }

    @Test("Keys and text go to the handoff app's process, whatever is in front; global shortcuts need system-keys; never the stop key")
    func keys() async throws {
        let poster = RecordingEventPoster()
        let (target, lease) = try await target(poster: poster)
        try await target.liveInput(lease, Self.key("a", code: "KeyA", text: "a"))
        try await target.liveInput(lease, .text("hello"))
        let typed = poster.count
        #expect(typed > 0)
        #expect(poster.deliveries.allSatisfy { $0 == .process(Desktop.textEdit.pid) }, "delivered to the process, never posted globally")
        try await target.liveInput(lease, Self.key("Tab", code: "Tab", [.cmd]))
        try await target.liveInput(lease, Self.key(" ", code: "Space", [.cmd]))
        try await target.liveInput(lease, Self.key("≥", code: "Period", [.ctrl, .option, .cmd]))
        #expect(poster.count == typed, "⌘Tab, ⌘Space, and the stop key are refused")
        await target.release(lease, reason: .completed)

        let flagged = RecordingEventPoster()
        let (withKeys, keysLease) = try await self.target(
            grants: [.app(bundleID: Desktop.textEdit.identity.bundleID, tier: .full, flags: [.systemKeys])], poster: flagged
        )
        try await withKeys.liveInput(keysLease, Self.key("Tab", code: "Tab", [.cmd]))
        #expect(flagged.count > 0, "the grant's system-keys flag lets them through")
        let before = flagged.count
        try await withKeys.liveInput(keysLease, Self.key("≥", code: "Period", [.ctrl, .option, .cmd]))
        #expect(flagged.count == before, "never the stop key")
        await withKeys.release(keysLease, reason: .completed)

        let elsewhere = RecordingEventPoster()
        let (harnessFront, frontLease) = try await self.target(Self.desktop(frontmost: Desktop.harness.pid), poster: elsewhere)
        try await harnessFront.liveInput(frontLease, .text("hello"))
        #expect(elsewhere.count > 0)
        #expect(elsewhere.deliveries.allSatisfy { $0 == .process(Desktop.textEdit.pid) }, "the harness in front never gets them")
        await harnessFront.release(frontLease, reason: .completed)
    }

    @Test("A broad-reach app, such as a terminal, takes no remote input unless the operator opts it in")
    func broadReachApps() async throws {
        let grants: [ComputerUseGrant] = [.app(bundleID: Self.terminal.identity.bundleID, tier: .click)]
        let refused = RecordingEventPoster()
        let (target, lease) = try await target(Self.terminalDesktop(), grants: grants, poster: refused)
        try await target.liveInput(lease, Self.mouse(.down, 400, 500))
        try await target.liveInput(lease, .text("rm -rf ~"))
        #expect(refused.count == 0, "a terminal granted for the agent must not become a remote shell")
        await target.release(lease, reason: .completed)

        let optedIn = RecordingEventPoster()
        let (allowed, allowedLease) = try await self.target(
            Self.terminalDesktop(), grants: grants, remoteTakeoverBundleIDs: [Self.terminal.identity.bundleID], poster: optedIn
        )
        try await allowed.liveInput(allowedLease, .text("ls"))
        #expect(optedIn.count > 0)
        await allowed.release(allowedLease, reason: .completed)
    }

    @Test("A takeover with no granted app on screen takes no remote input")
    func noHandoffApp() async throws {
        let poster = RecordingEventPoster()
        let state = FakeMacWorkspace.State(apps: [Desktop.harness, Desktop.dock], frontmost: Desktop.harness.pid, windows: [Desktop.dockWindow])
        let (target, lease) = try await target(state, poster: poster)
        try await target.liveInput(lease, .text("hello"))
        try await target.liveInput(lease, Self.mouse(.down, 400, 500))
        #expect(poster.count == 0)
        await target.release(lease, reason: .completed)
    }

    @Test("The broad-reach apps are the terminals and IDEs, file managers, and system settings")
    func broadReachPolicy() {
        let policy = ComputerUseAppPolicy.default
        for bundleID in ["com.apple.Terminal", "com.microsoft.VSCode", "com.apple.finder", "com.apple.systempreferences"] {
            #expect(policy.hasBroadReach(AppIdentity(bundleID: bundleID)), "\(bundleID)")
        }
        #expect(!policy.hasBroadReach(AppIdentity(bundleID: "com.apple.TextEdit")))
        #expect(!policy.hasBroadReach(AppIdentity(bundleID: "com.apple.Safari")))
    }

    @Test("Whole-display frames, for a VM guest, take input anywhere but still never the stop key")
    func wholeDisplay() async throws {
        let poster = RecordingEventPoster()
        let (target, lease) = try await target(mode: .wholeDisplay, poster: poster)
        try await target.liveInput(lease, Self.mouse(.down, 650, 250))
        try await target.liveInput(lease, Self.key("Tab", code: "Tab", [.cmd]))
        #expect(poster.count == 3)
        try await target.liveInput(lease, Self.key("≥", code: "Period", [.ctrl, .option, .cmd]))
        #expect(poster.count == 3)
        await target.release(lease, reason: .completed)
    }
}
#endif
