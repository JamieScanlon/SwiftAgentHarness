import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Display host over TCP")
struct DisplayHostTCPTests {
    private static func request() -> LeaseRequest {
        LeaseRequest(
            target: FakeDisplayTarget.vmManifest.id,
            agentID: "agent",
            grants: ComputerUseSessionFixtures.grants,
            budgets: ComputerUseBudgets(steps: 10, maxDuration: .seconds(60)),
            initiator: .operator,
            userPresent: true
        )
    }

    @Test("A client holding the secret drives the served target")
    func roundTrip() async throws {
        let secret = DisplayHostSecret.random()
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest)
        let listener = try await DisplayHostTCP.listen(port: 0, secret: secret)
        let serving = Task { try? await DisplayHostServer(target: target, name: "guest").serve(listener) }
        defer { serving.cancel() }

        let remote = try await RemoteDisplayTarget.connect(over: try await DisplayHostTCP.connect(host: "127.0.0.1", port: listener.port, secret: secret))
        #expect(remote.hostName == "guest")
        let lease = try await remote.lease(Self.request())
        let observation = try await remote.observe(lease, ObserveRequest(modes: [.pixels], scope: .display(nil)))
        #expect(observation.id == "o_1")
        #expect(try await remote.liveFrame(lease) == nil)
        await target.setServedFrame(DisplayLiveViewFrame(jpeg: Data([0xFF, 0xD8]), width: 1440, height: 900))
        #expect(try await remote.liveFrame(lease) == DisplayLiveViewFrame(jpeg: Data([0xFF, 0xD8]), width: 1440, height: 900))
        let click = DisplayLiveViewInput.mouse(.down, x: 10, y: 20, button: .left, clickCount: 1, modifiers: [.shift])
        try await remote.liveInput(lease, click)
        #expect(await target.liveInputs == [click])
        await remote.release(lease, reason: .completed)
        await remote.close()
        await listener.close()
    }

    @Test("A client without the secret is refused before any message, and so is a host without it")
    func wrongSecret() async throws {
        let listener = try await DisplayHostTCP.listen(port: 0, secret: DisplayHostSecret.random())
        let accepted = Task { () -> Bool in
            for try await _ in listener.connections { return true }
            return false
        }
        await #expect(throws: DisplayHostError.peerRejected) {
            _ = try await DisplayHostTCP.connect(host: "127.0.0.1", port: listener.port, secret: DisplayHostSecret.random())
        }
        try await Task.sleep(for: .milliseconds(100))
        await listener.close()
        #expect(try await accepted.value == false)
    }

    @Test("Secrets are at least 256 bits and travel as base64")
    func secrets() throws {
        #expect(DisplayHostSecret(Data(repeating: 1, count: 31)) == nil)
        let secret = DisplayHostSecret.random()
        #expect(DisplayHostSecret(base64: secret.base64) == secret)
        #expect(secret.key.count == 32)
    }
}

@Suite("Tart VMs")
struct TartVirtualMachineControllerTests {
    actor Host: DisplayCommandRunner {
        private(set) var commands: [[String]] = []
        var address = "192.168.64.7\n"
        var listing = ""

        func setAddress(_ value: String) { address = value }
        func setListing(_ value: String) { listing = value }

        func run(_ argv: [String], stdin: Data?, timeout: Duration) async throws -> DisplayCommandResult {
            commands.append(argv)
            switch argv.dropFirst().first {
            case "ip": return DisplayCommandResult(stdout: Data(address.utf8))
            case "list": return DisplayCommandResult(stdout: Data(listing.utf8))
            default: return DisplayCommandResult()
            }
        }
    }

    actor Spawner: DisplayProcessSpawner {
        actor Spawned: SpawnedDisplayProcess {
            private(set) var terminated = false
            func terminate() async { terminated = true }
        }

        private(set) var spawned: [([String], Spawned)] = []

        func spawn(_ argv: [String]) async throws -> any SpawnedDisplayProcess {
            let process = Spawned()
            spawned.append((argv, process))
            return process
        }
    }

    @Test("Each start clones the base image, runs it without graphics, and waits for its address; stop deletes the clone")
    func lifecycle() async throws {
        let host = Host()
        let spawner = Spawner()
        let controller = TartVirtualMachineController(configuration: TartVirtualMachineConfiguration(baseImage: "ubuntu-desktop"), host: host, spawner: spawner)
        let instance = try await controller.start()
        #expect(instance.address == "192.168.64.7")
        #expect(instance.name.hasPrefix("sah-vm-\(getpid())-"))
        let commands = await host.commands
        #expect(commands.contains(["tart", "clone", "ubuntu-desktop", instance.name]))
        #expect(commands.contains(["tart", "ip", instance.name, "--wait", "180"]))
        let run = try #require(await spawner.spawned.first)
        #expect(run.0 == ["tart", "run", "--no-graphics", instance.name])

        await controller.stop(instance)
        #expect(await host.commands.suffix(2) == [["tart", "stop", instance.name], ["tart", "delete", instance.name]])
        #expect(await run.1.terminated)
    }

    @Test("A VM with no address is cleaned up and fails to start")
    func noAddress() async throws {
        let host = Host()
        await host.setAddress("\n")
        let controller = TartVirtualMachineController(configuration: TartVirtualMachineConfiguration(baseImage: "base"), host: host, spawner: Spawner())
        await #expect(throws: DisplayTargetError.self) { try await controller.start() }
        #expect(await host.commands.last?.prefix(2) == ["tart", "delete"])
    }

    @Test("Clones left by a harness that died are deleted; others are kept")
    func stale() async throws {
        let host = Host()
        await host.setListing("sah-vm-99999999-aaaa\nsah-vm-\(getpid())-bbbb\nmy-own-vm\n")
        let controller = TartVirtualMachineController(configuration: TartVirtualMachineConfiguration(baseImage: "base"), host: host, spawner: Spawner())
        let instance = try await controller.start()
        let deleted = await host.commands.filter { $0.dropFirst().first == "delete" }.map { $0.last! }
        #expect(deleted == ["sah-vm-99999999-aaaa"])
        await controller.stop(instance)
    }
}

@Suite("VM display target")
struct VirtualMachineDisplayTargetTests {
    actor Controller: VirtualMachineController {
        private(set) var started = 0
        private(set) var stopped: [String] = []
        func start() async throws -> VirtualMachineInstance {
            started += 1
            return VirtualMachineInstance(name: "vm-\(started)", address: "10.0.0.\(started)")
        }
        func stop(_ instance: VirtualMachineInstance) async { stopped.append(instance.name) }
    }

    static let manifest = DisplayTargetManifest(
        id: "test-vm", label: "Test VM", platform: "linux", isolation: .vm,
        perception: [.pixels], delivery: [.background], humanPresence: .exclusive
    )

    private static func request(_ agent: String = "agent") -> LeaseRequest {
        LeaseRequest(
            target: "test-vm", agentID: agent, grants: ComputerUseSessionFixtures.grants,
            budgets: ComputerUseBudgets(steps: 10, maxDuration: .seconds(60)), initiator: .trigger, userPresent: false
        )
    }

    @Test("A lease boots a fresh VM and leases its guest; calls go to the guest; release stops the VM")
    func lifecycle() async throws {
        let controller = Controller()
        let guest = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest)
        let target = VirtualMachineDisplayTarget(manifest: Self.manifest, controller: controller) { _ in guest }
        let lease = try await target.lease(Self.request())
        #expect(await controller.started == 1)
        _ = try await target.observe(lease, ObserveRequest(modes: [.pixels], scope: .display(nil)))
        #expect(await guest.observeCalls.count == 1)
        _ = try await target.act(lease, ActionBatch([.wait(milliseconds: 1)]))
        #expect(await guest.actCalls.count == 1)
        await #expect(throws: DisplayTargetError.self) { try await target.lease(Self.request("other")) }

        await target.release(lease, reason: .completed)
        #expect(await guest.releases == [.completed])
        #expect(await controller.stopped == ["vm-1"])
        await #expect(throws: DisplayTargetError.leaseNotHeld) { try await target.describe(lease) }
        _ = try await target.lease(Self.request())
        #expect(await controller.started == 2, "every lease starts clean")
    }

    @Test("When the guest can't be reached, the VM is stopped and the lease fails")
    func guestFails() async throws {
        let controller = Controller()
        let target = VirtualMachineDisplayTarget(manifest: Self.manifest, controller: controller) { _ in throw DisplayHostError.connectionClosed }
        await #expect(throws: DisplayTargetError.self) { try await target.lease(Self.request()) }
        #expect(await controller.stopped == ["vm-1"])
    }

    @Test("A Linux guest is the X11 driver over SSH to the VM's address")
    func linuxGuest() async throws {
        let host = FakeSSHHost()
        let target = VirtualMachineDisplayTarget.linux(
            controller: Controller(),
            configuration: LinuxGuestConfiguration(user: "admin", identityFile: "/keys/vm"),
            host: host
        )
        #expect(target.manifest.id == "linux-vm")
        #expect(target.manifest.isolation == .vm)
        #expect(target.manifest.perception == [.pixels])
        let lease = try await target.lease(Self.request())
        let first = try #require(await host.commands.first)
        #expect(first.prefix(3) == ["ssh", "-i", "/keys/vm"])
        #expect(first.suffix(3) == ["admin@10.0.0.1", "--", "env DISPLAY=':0' 'xdotool' 'getdisplaygeometry'"])
        #expect(try await target.describe(lease).displays.first?.frame.width == 1280)
        await target.release(lease, reason: .completed)
    }

    @Test("A guest's frames are served here while someone watches, and a viewer's input reaches it only during takeover")
    func relayedLiveView() async throws {
        let server = DisplayLiveViewServer()
        defer { Task { await server.stop() } }
        let guest = FakeDisplayTarget(manifest: FakeDisplayTarget.hostManifest)
        await guest.setServedFrame(DisplayLiveViewFrame(jpeg: Data([0xFF, 0xD8, 0xFF]), width: 1440, height: 900))
        let target = VirtualMachineDisplayTarget(manifest: Self.manifest, controller: Controller(), liveView: server, liveViewFrameInterval: .milliseconds(10)) { _ in guest }
        let lease = try await target.lease(Self.request())
        #expect(await guest.liveFrameCalls == 0, "no frames while nobody watches")
        #expect(await guest.liveViewRoles.isEmpty, "the view is served here, not by the guest")

        let viewer = try DisplayLiveViewServerTests.Viewer(try #require(try await target.liveView(lease)))
        _ = try await viewer.status()
        #expect(try await target.liveViewers(lease) == 1)
        let frame = try await viewer.frame()
        #expect(frame.jpeg == Data([0xFF, 0xD8, 0xFF]))
        #expect(frame.width == 1440 && frame.height == 900)

        let mouse = #"{"type":"mouse","action":"down","x":40,"y":50,"button":"left","clickCount":1,"modifiers":[]}"#
        try await viewer.send(mouse)
        try await viewer.roundTrip()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await guest.liveInputs.isEmpty, "input waits for takeover")
        try await target.takeover(lease, on: true)
        #expect(await guest.takeoverStates == [true])
        try await viewer.send(mouse)
        try await viewer.roundTrip()
        for _ in 0..<100 where await guest.liveInputs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await guest.liveInputs == [.mouse(.down, x: 40, y: 50, button: .left, clickCount: 1, modifiers: [])])
        await target.release(lease, reason: .completed)
    }

    @Test("A macOS guest is unshared and reached through its display host over TCP")
    func macGuest() async throws {
        let secret = DisplayHostSecret.random()
        let guest = FakeDisplayTarget(manifest: FakeDisplayTarget.hostManifest)
        let listener = try await DisplayHostTCP.listen(port: 0, secret: secret)
        let serving = Task { try? await DisplayHostServer(target: guest, name: "guest").serve(listener) }
        defer { serving.cancel() }
        actor Loopback: VirtualMachineController {
            func start() async throws -> VirtualMachineInstance { VirtualMachineInstance(name: "mac", address: "127.0.0.1") }
            func stop(_ instance: VirtualMachineInstance) async {}
        }
        let target = VirtualMachineDisplayTarget.macOS(controller: Loopback(), configuration: MacGuestConfiguration(port: listener.port, secret: secret))
        #expect(target.manifest.isolation == .vm)
        #expect(target.manifest.humanPresence == .exclusive)
        #expect(target.manifest.observerAccess == .none)
        #expect(VirtualMachineDisplayTarget.macOS(
            controller: Loopback(), configuration: MacGuestConfiguration(port: listener.port, secret: secret), liveView: DisplayLiveViewServer()
        ).manifest.observerAccess == .stream)
        var request = Self.request()
        request.target = "macos-vm"
        let lease = try await target.lease(request)
        #expect(try await target.describe(lease).focusedApp == ComputerUseFixtures.textEdit)
        await target.release(lease, reason: .completed)
        #expect(await guest.releases == [.completed])
        await listener.close()
    }
}

/// Answers the X11 driver's commands as they arrive over `ssh`.
actor FakeSSHHost: DisplayCommandRunner {
    private(set) var commands: [[String]] = []

    func run(_ argv: [String], stdin: Data?, timeout: Duration) async throws -> DisplayCommandResult {
        commands.append(argv)
        let remote = argv.last ?? ""
        if remote.contains("getdisplaygeometry") { return DisplayCommandResult(stdout: Data("1280 800".utf8)) }
        if remote.contains("getactivewindow") { return DisplayCommandResult(stdout: Data("window=1\nclass=XTerm\n".utf8)) }
        return DisplayCommandResult()
    }
}
