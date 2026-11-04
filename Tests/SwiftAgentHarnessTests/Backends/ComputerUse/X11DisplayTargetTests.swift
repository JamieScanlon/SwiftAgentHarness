import Foundation
import Testing
@testable import SwiftAgentHarness

/// Stands in for the tools inside a desktop: answers `xdotool`, `import`, and the window script, and records every
/// command.
actor FakeDesktopRunner: DisplayCommandRunner {
    private(set) var commands: [[String]] = []
    private(set) var inputs: [String] = []
    var window = "4194311"
    var appClass = "XTerm"
    var displayReady = true
    var exitCodes: [String: Int32] = [:]

    func setWindow(_ window: String) { self.window = window }
    func setExitCode(_ code: Int32, forScriptContaining marker: String) { exitCodes[marker] = code }

    func run(_ argv: [String], stdin: Data?, timeout: Duration) async throws -> DisplayCommandResult {
        commands.append(argv)
        if let stdin { inputs.append(String(decoding: stdin, as: UTF8.self)) }
        switch argv.first {
        case "xdotool" where argv.dropFirst().first == "getdisplaygeometry":
            return displayReady ? DisplayCommandResult(stdout: Data("1280 800\n".utf8)) : DisplayCommandResult(exitCode: 1)
        case "import":
            let size = argv.firstIndex(of: "-resize").map { argv[$0 + 1].dropLast() }?.split(separator: "x").compactMap { Int($0) } ?? [1280, 800]
            return DisplayCommandResult(stdout: ManagedBrowserDisplayTargetTests.FakeBrowser.png(width: size[0], height: size[1]))
        case "sh":
            if argv.count > 2, argv[2].contains("getactivewindow") {
                return DisplayCommandResult(stdout: Data("window=\(window)\npid=812\nclass=\(appClass)\nstart=1790000000\n".utf8))
            }
            let code = exitCodes.first { argv.joined(separator: " ").contains($0.key) }?.value ?? 0
            return DisplayCommandResult(exitCode: code)
        default:
            return DisplayCommandResult()
        }
    }

    func xdotool() -> [String] {
        commands.filter { $0.first == "xdotool" }.map { $0.dropFirst().joined(separator: " ") }
    }
}

@Suite("X11 desktop target")
struct X11DisplayTargetTests {
    private struct Fixture {
        let runner: FakeDesktopRunner
        let target: X11DisplayTarget
        let lease: Lease
    }

    private actor Shutdowns {
        private(set) var count = 0
        func record() { count += 1 }
    }

    private static func fixture(liveView: DisplayLiveViewServer? = nil, shutdowns: Shutdowns = Shutdowns()) async throws -> Fixture {
        let runner = FakeDesktopRunner()
        let target = X11DisplayTarget(
            configuration: X11DesktopConfiguration(id: "desktop", label: "Desktop", isolation: .container, settleDelay: .zero),
            liveView: liveView
        ) {
            X11DesktopSession(runner: runner, shutdown: { await shutdowns.record() })
        }
        let lease = try await target.lease(LeaseRequest(
            target: "desktop",
            agentID: "specialist",
            grants: [.app(bundleID: "XTerm", tier: .full)],
            budgets: ComputerUseBudgets(steps: 10, maxDuration: .seconds(600)),
            initiator: .trigger,
            userPresent: false
        ))
        return Fixture(runner: runner, target: target, lease: lease)
    }

    private static func observe(_ fixture: Fixture, scope: ObservationScope = .display(nil), limit: ObservationImageLimit? = nil) async throws -> DisplayObservation {
        try await fixture.target.observe(fixture.lease, ObserveRequest(modes: [.pixels, .accessibility], scope: scope, maxImage: limit))
    }

    private static func act(_ fixture: Fixture, _ action: ComputerAction) async throws -> ActionOutcome {
        try #require(try await fixture.target.act(fixture.lease, ActionBatch([action])).first)
    }

    @Test("It declares a pixels-only, background, unshared Linux target")
    func manifest() {
        let target = X11DisplayTarget.desktopContainer(host: FakeDesktopRunner())
        #expect(target.manifest.id == "desktop-container")
        #expect(target.manifest.platform == "linux")
        #expect(target.manifest.isolation == .container)
        #expect(target.manifest.perception == [.pixels])
        #expect(target.manifest.delivery == [.background])
        #expect(target.manifest.semanticActions == [.launchApp, .openURL])
        #expect(target.manifest.humanPresence == .exclusive)
        #expect(target.manifest.scripting.isEmpty)
        #expect(target.manifest.observerAccess == .none)
        #expect(X11DisplayTarget.desktopContainer(liveView: DisplayLiveViewServer(), host: FakeDesktopRunner()).manifest.observerAccess == .stream)
    }

    @Test("A lease reads the screen size, and release releases held keys and shuts the desktop down")
    func lifecycle() async throws {
        let shutdowns = Shutdowns()
        let fixture = try await Self.fixture(shutdowns: shutdowns)
        let layout = try await fixture.target.describe(fixture.lease)
        #expect(layout.displays.first?.frame == DisplayRect(x: 0, y: 0, width: 1280, height: 800))
        #expect(layout.focusedApp == AppIdentity(bundleID: "XTerm"))
        await fixture.target.release(fixture.lease, reason: .completed)
        #expect(await fixture.runner.xdotool().last == "keyup shift ctrl alt super")
        #expect(await shutdowns.count == 1)
        await #expect(throws: DisplayTargetError.leaseNotHeld) { try await fixture.target.describe(fixture.lease) }
    }

    @Test("Screenshots are sized to the model in the desktop, recorded with their geometry, and carry no tree")
    func observation() async throws {
        let fixture = try await Self.fixture()
        let observation = try await Self.observe(fixture, limit: ObservationImageLimit(longEdgePx: 1024))
        let image = try #require(observation.image)
        #expect(image.geometry == ScreenshotGeometry(capturedRect: DisplayRect(x: 0, y: 0, width: 1280, height: 800), imageSize: ImagePixelSize(width: 1024, height: 640), scaleFactor: 1))
        #expect(await fixture.runner.commands.contains(["import", "-silent", "-window", "root", "-resize", "1024x640!", "png:-"]))
        #expect(observation.tree == nil)
        #expect(observation.target.app == AppIdentity(bundleID: "XTerm"))
        #expect(observation.target.pid == 812)
        #expect(observation.target.processStart == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(observation.target.windowID == "4194311")

        let zoom = try await Self.observe(fixture, scope: .region(DisplayRect(x: 10, y: 20, width: 200, height: 100)), limit: ObservationImageLimit(longEdgePx: 1024))
        #expect(zoom.image?.geometry.imageSize == ImagePixelSize(width: 400, height: 200))
        #expect(await fixture.runner.commands.last { $0.first == "import" } == ["import", "-silent", "-window", "root", "-crop", "200x100+10+20", "+repage", "-resize", "400x200!", "png:-"])
    }

    @Test("A click lands on its point with modifiers held and released, and refs are refused")
    func click() async throws {
        let fixture = try await Self.fixture()
        let observation = try await Self.observe(fixture)
        let outcome = try await Self.act(fixture, .click(at: .point(DisplayPoint(x: 100.4, y: 200.6), observation: observation.id), count: 2, modifiers: [.ctrl, .shift]))
        #expect(outcome.effect == .unverifiable)
        #expect(await fixture.runner.xdotool().suffix(4) == [
            "mousemove --sync 100 201", "keydown ctrl shift", "click --repeat 2 --delay 80 1", "keyup ctrl shift",
        ])
        let ref = try await Self.act(fixture, .click(at: .ref("e1", observation: observation.id)))
        #expect(ref.effect == .refused)
        #expect(ref.evidence?.contains("no element tree") == true)
    }

    @Test("A point is refused once the focused window changed since its screenshot")
    func drift() async throws {
        let fixture = try await Self.fixture()
        let observation = try await Self.observe(fixture)
        await fixture.runner.setWindow("4194999")
        let outcome = try await Self.act(fixture, .click(at: .point(DisplayPoint(x: 10, y: 10), observation: observation.id)))
        #expect(outcome.effect == .refused)
        #expect(outcome.escalation == .observe)
        #expect(await !fixture.runner.xdotool().contains { $0.hasPrefix("click") })
        let stale = try await Self.act(fixture, .click(at: .point(DisplayPoint(x: 10, y: 10), observation: "o_99")))
        #expect(stale.escalation == .observe)
    }

    @Test("Typing goes through standard input, keys are named for X, and scrolling uses wheel buttons")
    func keyboard() async throws {
        let fixture = try await Self.fixture()
        _ = try await Self.act(fixture, .type(text: "héllo 'world'"))
        #expect(await fixture.runner.inputs.last == "héllo 'world'")
        #expect(await fixture.runner.xdotool().last == "type --clearmodifiers --delay 12 --file -")
        for (combo, chord) in [("cmd+shift+a", "shift+super+a"), ("return", "Return"), ("page-up", "Prior"), ("f5", "F5"), ("ctrl+-", "ctrl+minus")] {
            _ = try await Self.act(fixture, .key(combo: try KeyCombo(parsing: combo)))
            #expect(await fixture.runner.xdotool().last == "key --clearmodifiers --repeat 1 --delay 40 \(chord)")
        }
        #expect(try await Self.act(fixture, .key(combo: KeyCombo(modifiers: [], key: "nosuchkey"))).effect == .refused)
        _ = try await Self.act(fixture, .scroll(at: nil, dx: -2, dy: 3, unit: .line))
        #expect(await fixture.runner.xdotool().suffix(2) == ["click --repeat 3 --delay 20 5", "click --repeat 2 --delay 20 6"])
        #expect(try await Self.act(fixture, .type(text: "x", mode: .setValue)).effect == .refused)
    }

    @Test("Apps launch by command name and URLs open with xdg-open, each passed as an argument, never as shell text")
    func launchAndOpen() async throws {
        let fixture = try await Self.fixture()
        #expect(try await Self.act(fixture, .launch(app: "mousepad")).effect == .unverifiable)
        let launch = try #require(await fixture.runner.commands.last)
        #expect(launch.first == "sh" && launch.last == "mousepad")
        #expect(try await Self.act(fixture, .launch(app: "rm -rf /")).effect == .refused)

        let url = "https://example.com/?q=$(reboot)"
        #expect(try await Self.act(fixture, .openURL(url)).effect == .unverifiable)
        let open = try #require(await fixture.runner.commands.last)
        #expect(open.last == url)
        #expect(open[2].contains("xdg-open \"$0\""))

        await fixture.runner.setExitCode(127, forScriptContaining: "missing-app")
        let missing = try await Self.act(fixture, .launch(app: "missing-app"))
        #expect(missing.effect == .refused)
        #expect(missing.evidence == "missing-app isn't installed")
        #expect(try await Self.act(fixture, .press(at: .ref("e1", observation: "o_1"))).effect == .refused)
        #expect(try await Self.act(fixture, .script(language: .javascript, source: "1", timeoutMilliseconds: 100)).effect == .refused)
    }

    @Test("Takeover pauses the agent, and a viewer's input reaches the desktop only then")
    func takeover() async throws {
        let server = DisplayLiveViewServer()
        defer { Task { await server.stop() } }
        let fixture = try await Self.fixture(liveView: server)
        try await fixture.target.takeover(fixture.lease, on: true)
        await #expect(throws: DisplayTargetError.self) { try await Self.observe(fixture) }
        await #expect(throws: DisplayTargetError.self) { try await fixture.target.act(fixture.lease, ActionBatch([.wait(milliseconds: 1)])) }

        let link = try #require(try await fixture.target.liveView(fixture.lease))
        let viewer = try DisplayLiveViewServerTests.Viewer(link)
        #expect(try await viewer.status().control == true)
        #expect(try await fixture.target.liveViewers(fixture.lease) == 1)
        try await viewer.send(#"{"type":"mouse","action":"down","x":40,"y":50,"button":"left","clickCount":1,"modifiers":[]}"#)
        try await viewer.send(#"{"type":"key","action":"down","key":"Enter","code":"Enter","keyCode":13,"text":"\r","modifiers":[]}"#)
        try await viewer.send(#"{"type":"key","action":"down","key":"a","code":"KeyA","keyCode":65,"text":"a","modifiers":[]}"#)
        try await viewer.send(#"{"type":"key","action":"up","key":"a","code":"KeyA","keyCode":65,"modifiers":[]}"#)
        try await viewer.roundTrip()
        for _ in 0..<100 where await !fixture.runner.xdotool().contains("keydown Return") {
            try await Task.sleep(for: .milliseconds(10))
        }
        let sent = await fixture.runner.xdotool()
        #expect(sent.contains("mousemove 40 50"))
        #expect(sent.contains("mousedown 1"))
        #expect(sent.contains("keydown Return"))
        #expect(!sent.contains("keyup a"), "a typed character isn't released on its own")
        #expect(await fixture.runner.inputs.last == "a")

        try await fixture.target.takeover(fixture.lease, on: false)
        let before = await fixture.runner.commands.count
        try await viewer.send(#"{"type":"mouse","action":"down","x":1,"y":1,"button":"left","clickCount":1,"modifiers":[]}"#)
        try await viewer.roundTrip()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await fixture.runner.commands.dropFirst(before).allSatisfy { $0.first != "xdotool" || !$0.contains("mousedown") })
        await fixture.target.release(fixture.lease, reason: .completed)
    }

    @Test("The live view is fed screenshots only while someone watches")
    func liveFrames() async throws {
        let server = DisplayLiveViewServer()
        defer { Task { await server.stop() } }
        let fixture = try await Self.fixture(liveView: server)
        #expect(await !fixture.runner.commands.contains { $0.contains("jpeg:-") })
        let viewer = try DisplayLiveViewServerTests.Viewer(try #require(try await fixture.target.liveView(fixture.lease)))
        _ = try await viewer.status()
        for _ in 0..<200 where await !fixture.runner.commands.contains(where: { $0.contains("jpeg:-") }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fixture.runner.commands.contains { $0 == ["import", "-silent", "-window", "root", "-quality", "60", "jpeg:-"] })
        await fixture.target.release(fixture.lease, reason: .completed)
    }
}

@Suite("Desktop container")
struct DesktopContainerTests {
    actor HostRunner: DisplayCommandRunner {
        private(set) var commands: [[String]] = []
        var displayChecks = 0
        var readyAfter = 2
        var listing = ""

        func setListing(_ text: String) { listing = text }
        func setReadyAfter(_ count: Int) { readyAfter = count }

        func run(_ argv: [String], stdin: Data?, timeout: Duration) async throws -> DisplayCommandResult {
            commands.append(argv)
            if argv.contains("getdisplaygeometry") {
                displayChecks += 1
                return displayChecks >= readyAfter ? DisplayCommandResult(stdout: Data("1280 800".utf8)) : DisplayCommandResult(exitCode: 1)
            }
            if argv.dropFirst().first == "ps" { return DisplayCommandResult(stdout: Data(listing.utf8)) }
            if argv.contains("getactivewindow") || argv.joined().contains("getactivewindow") {
                return DisplayCommandResult(stdout: Data("window=1\nclass=XTerm\n".utf8))
            }
            return DisplayCommandResult()
        }
    }

    @Test("Each lease runs a fresh container with no network, waits for its display, and removes it on release")
    func lifecycle() async throws {
        let host = HostRunner()
        let target = X11DisplayTarget.desktopContainer(host: host)
        let lease = try await target.lease(LeaseRequest(
            target: "desktop-container", agentID: "a", grants: [], budgets: ComputerUseBudgets(steps: 1, maxDuration: .seconds(60)),
            initiator: .trigger, userPresent: false
        ))
        let commands = await host.commands
        let run = try #require(commands.first { $0.dropFirst().first == "run" })
        let name = try #require(run.firstIndex(of: "--name").map { run[$0 + 1] })
        #expect(name.hasPrefix("sah-desktop-"))
        #expect(run.contains("--rm"))
        #expect(run.firstIndex(of: "--network").map { run[$0 + 1] } == "none")
        #expect(run.contains("\(DesktopContainer.ownerLabel)=\(DesktopContainer.owner)"))
        #expect(run.last == "swiftagentharness/desktop:latest")
        let exec = try #require(commands.last { $0.contains("getdisplaygeometry") })
        #expect(Array(exec.prefix(6)) == ["docker", "exec", "-e", "DISPLAY=:99", name, "xdotool"])

        await target.release(lease, reason: .completed)
        #expect(await host.commands.last == ["docker", "rm", "--force", name])
    }

    @Test("A display that never comes up removes the container and fails the lease")
    func neverReady() async throws {
        let host = HostRunner()
        await host.setReadyAfter(.max)
        let target = X11DisplayTarget.desktopContainer(configuration: DesktopContainerConfiguration(startTimeout: .milliseconds(300)), host: host)
        await #expect(throws: DisplayTargetError.self) {
            try await target.lease(LeaseRequest(
                target: "desktop-container", agentID: "a", grants: [], budgets: ComputerUseBudgets(steps: 1, maxDuration: .seconds(60)),
                initiator: .trigger, userPresent: false
            ))
        }
        #expect(await host.commands.last?.prefix(3) == ["docker", "rm", "--force"])
    }

    @Test("Containers left by a harness that died on this host are removed; live ones and other hosts' are kept")
    func staleContainers() async throws {
        let host = HostRunner()
        let me = DesktopContainer.hostName
        await host.setListing("aaa\t\(me)-99999999\nbbb\t\(me)-\(getpid())\nccc\tother-host-99999999\nddd\t\n")
        await DesktopContainer.removeStale(docker: "docker", host: host)
        let removals = await host.commands.filter { $0.prefix(2) == ["docker", "rm"] }.map { $0.last! }
        #expect(removals == ["aaa"])
        #expect(DesktopContainer.isStale(owner: "Mac-Studio.HomeNet-\(getpid())", hostName: "Mac-Studio.HomeNet") == false)
    }
}

@Suite("Display command runners")
struct DisplayCommandRunnerTests {
    actor Recorder: DisplayCommandRunner {
        private(set) var argv: [String] = []
        func run(_ argv: [String], stdin: Data?, timeout: Duration) async throws -> DisplayCommandResult {
            self.argv = argv
            return DisplayCommandResult()
        }
    }

    @Test("SSH quotes every argument for the remote shell")
    func ssh() async throws {
        let recorder = Recorder()
        let runner = SSHDisplayCommandRunner(destination: "admin@192.168.64.5", port: 2222, options: ["BatchMode=yes"], host: recorder)
        _ = try await runner.run(["xdotool", "type", "it's $(here)"])
        #expect(await recorder.argv == [
            "ssh", "-p", "2222", "-o", "BatchMode=yes", "admin@192.168.64.5", "--",
            "env DISPLAY=':0' 'xdotool' 'type' 'it'\\''s $(here)'",
        ])
    }

    @Test("Docker exec passes standard input only when there is some")
    func docker() async throws {
        let recorder = Recorder()
        let runner = DockerExecDisplayCommandRunner(container: "c1", host: recorder)
        _ = try await runner.run(["xdotool", "type", "--file", "-"], stdin: Data("x".utf8))
        #expect(await recorder.argv == ["docker", "exec", "-i", "-e", "DISPLAY=:99", "c1", "xdotool", "type", "--file", "-"])
        _ = try await runner.run(["xdotool", "getdisplaygeometry"])
        #expect(await recorder.argv == ["docker", "exec", "-e", "DISPLAY=:99", "c1", "xdotool", "getdisplaygeometry"])
    }
}
