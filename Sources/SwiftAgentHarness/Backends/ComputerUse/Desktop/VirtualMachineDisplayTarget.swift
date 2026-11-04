import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A running VM the harness can reach.
public struct VirtualMachineInstance: Sendable, Hashable {
    public var name: String
    /// The guest's address on the network it shares with this machine.
    public var address: String

    public init(name: String, address: String) {
        self.name = name
        self.address = address
    }
}

/// Starts and stops the VMs a VM target leases.
public protocol VirtualMachineController: Sendable {
    /// A fresh VM from a clean image, once it has an address.
    func start() async throws -> VirtualMachineInstance
    /// Stops the VM and deletes it, so nothing it did outlives the lease. Idempotent.
    func stop(_ instance: VirtualMachineInstance) async
}

/// A process started and left running, such as a VM's monitor.
public protocol SpawnedDisplayProcess: Sendable {
    func terminate() async
}

public protocol DisplayProcessSpawner: Sendable {
    func spawn(_ argv: [String]) async throws -> any SpawnedDisplayProcess
}

#if os(macOS) || os(Linux)
/// Starts processes on this machine, their output discarded.
public struct LocalDisplayProcessSpawner: DisplayProcessSpawner {
    public init() {}

    public func spawn(_ argv: [String]) async throws -> any SpawnedDisplayProcess {
        guard let first = argv.first else { throw DisplayTargetError.driverFailure("nothing to run") }
        let search = ProcessInfo.processInfo.environment["PATH"].map { $0 + ":/opt/homebrew/bin:/usr/local/bin" }
        guard let executable = ExecutablePathResolver.resolve(first, path: search, cwd: nil) else {
            throw DisplayTargetError.driverFailure("\(first) isn't installed")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return LocalSpawnedProcess(process: process)
    }
}

private actor LocalSpawnedProcess: SpawnedDisplayProcess {
    let process: Process

    init(process: Process) {
        self.process = process
    }

    func terminate() async {
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0..<50 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}
#endif

public struct TartVirtualMachineConfiguration: Sendable {
    /// The image each lease clones: a prepared VM with the guest's driver installed.
    public var baseImage: String
    public var tart: String
    /// More `tart run` arguments. `--no-graphics` keeps the guest off this machine's screen.
    public var runArguments: [String]
    public var startTimeout: Duration

    public init(baseImage: String, tart: String = "tart", runArguments: [String] = ["--no-graphics"], startTimeout: Duration = .seconds(180)) {
        self.baseImage = baseImage
        self.tart = tart
        self.runArguments = runArguments
        self.startTimeout = startTimeout
    }
}

/// VMs run with Tart (Apple's Virtualization framework): each lease clones the base image, so it starts clean, and
/// the clone is deleted on release. Clones are named `sah-vm-<pid>-…`, and each start deletes those whose harness
/// has died.
public actor TartVirtualMachineController: VirtualMachineController {
    public nonisolated let configuration: TartVirtualMachineConfiguration
    private let host: any DisplayCommandRunner
    private let spawner: any DisplayProcessSpawner
    private var running: [String: any SpawnedDisplayProcess] = [:]

    static let prefix = "sah-vm-"

    public init(configuration: TartVirtualMachineConfiguration, host: any DisplayCommandRunner, spawner: any DisplayProcessSpawner) {
        self.configuration = configuration
        self.host = host
        self.spawner = spawner
    }

    #if os(macOS) || os(Linux)
    public init(configuration: TartVirtualMachineConfiguration) {
        self.init(configuration: configuration, host: LocalDisplayCommandRunner(), spawner: LocalDisplayProcessSpawner())
    }
    #endif

    public func start() async throws -> VirtualMachineInstance {
        let tart = configuration.tart
        await removeStale()
        let name = "\(Self.prefix)\(getpid())-\(UUID().uuidString.prefix(8).lowercased())"
        _ = try await host.output([tart, "clone", configuration.baseImage, name], timeout: .seconds(600))
        do {
            running[name] = try await spawner.spawn([tart, "run"] + configuration.runArguments + [name])
            let seconds = Int(configuration.startTimeout.timeInterval.rounded(.up))
            let address = try await host.output([tart, "ip", name, "--wait", String(seconds)], timeout: configuration.startTimeout + .seconds(10))
                .text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty, !address.contains(where: \.isWhitespace) else {
                throw DisplayTargetError.driverFailure("the VM reported no address")
            }
            return VirtualMachineInstance(name: name, address: address)
        } catch {
            await stop(VirtualMachineInstance(name: name, address: ""))
            throw error
        }
    }

    public func stop(_ instance: VirtualMachineInstance) async {
        _ = try? await host.run([configuration.tart, "stop", instance.name], stdin: nil, timeout: .seconds(60))
        await running.removeValue(forKey: instance.name)?.terminate()
        _ = try? await host.run([configuration.tart, "delete", instance.name], stdin: nil, timeout: .seconds(60))
    }

    private func removeStale() async {
        guard let listing = try? await host.output([configuration.tart, "list", "--quiet"]) else { return }
        for name in listing.text.split(whereSeparator: \.isNewline).map(String.init) where Self.isStale(name) {
            _ = try? await host.run([configuration.tart, "stop", name], stdin: nil, timeout: .seconds(60))
            _ = try? await host.run([configuration.tart, "delete", name], stdin: nil, timeout: .seconds(60))
        }
    }

    static func isStale(_ name: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let rest = name.dropFirst(prefix.count)
        guard let dash = rest.firstIndex(of: "-"), let pid = Int32(rest[..<dash]), pid > 0 else { return false }
        return kill(pid, 0) != 0 && errno == ESRCH
    }
}

/// A desktop in a VM started for each lease from a clean image, driven by a driver inside the guest: the guest's
/// own display, so delivery never touches this machine's screen. Every call goes to the guest's target; release
/// releases it and stops the VM.
public actor VirtualMachineDisplayTarget: DisplayTarget {
    public nonisolated let manifest: DisplayTargetManifest
    private let controller: any VirtualMachineController
    private let guest: @Sendable (VirtualMachineInstance) async throws -> any DisplayTarget
    private let lock = DisplayTargetLeaseLock()
    private var current: (lease: Lease, guest: any DisplayTarget, guestLease: Lease, instance: VirtualMachineInstance)?
    private let liveViewServer: DisplayLiveViewServer?
    private let liveViewFrameInterval: Duration
    private var liveFeed: UUID?
    private var frames: Task<Void, Never>?
    private var takeoverActive = false

    /// - Parameters:
    ///   - guest: Connects to the guest's driver. Called once per lease, after the VM has an address.
    ///   - liveView: Serves the live view here, from the guest's ``DisplayTarget/liveFrame(_:)`` frames, for a guest
    ///     whose own view can't be reached. Without it, live-view calls go to the guest.
    public init(
        manifest: DisplayTargetManifest,
        controller: any VirtualMachineController,
        liveView: DisplayLiveViewServer? = nil,
        liveViewFrameInterval: Duration = .milliseconds(500),
        guest: @escaping @Sendable (VirtualMachineInstance) async throws -> any DisplayTarget
    ) {
        self.manifest = manifest
        self.controller = controller
        self.liveViewServer = liveView
        self.liveViewFrameInterval = liveViewFrameInterval
        self.guest = guest
    }

    public func lease(_ request: LeaseRequest) async throws -> Lease {
        let lease = Lease(request: request, issuedAt: Date())
        try await lock.acquire(leaseID: lease.id, holder: DisplayTargetLeaseLock.Holder(id: request.agentID, isAlive: request.isHolderAlive))
        var instance: VirtualMachineInstance?
        do {
            let started = try await controller.start()
            instance = started
            let target = try await guest(started)
            var guestRequest = request
            guestRequest.target = target.manifest.id
            let guestLease = try await target.lease(guestRequest)
            current = (lease, target, guestLease, started)
            takeoverActive = false
            if let liveViewServer {
                liveFeed = await liveViewServer.open(DisplayLiveViewFeed(
                    label: manifest.label,
                    viewersChanged: { [weak self] count in await self?.viewersChanged(count) },
                    input: { [weak self] input in await self?.relayInput(input) }
                ))
            }
            return lease
        } catch {
            if let instance { await controller.stop(instance) }
            await lock.release(leaseID: lease.id)
            throw DisplayTargetError.driverFailure("the VM did not start: \(error)")
        }
    }

    public func release(_ lease: Lease, reason: ReleaseReason) async {
        guard await lock.holds(leaseID: lease.id), let current, current.lease.id == lease.id else { return }
        self.current = nil
        frames?.cancel()
        frames = nil
        takeoverActive = false
        if let liveFeed { await liveViewServer?.close(liveFeed) }
        liveFeed = nil
        await current.guest.release(current.guestLease, reason: reason)
        await controller.stop(current.instance)
        await lock.release(leaseID: lease.id)
    }

    /// Before a lease nothing runs to ask; the guest's permissions are its own, and a revoked one fails its actions.
    public func permissions() async -> PermissionSnapshot {
        await current?.guest.permissions() ?? PermissionSnapshot(states: [:])
    }

    public func describe(_ lease: Lease) async throws -> TargetLayout {
        let (guest, guestLease) = try await leased(lease)
        return try await guest.describe(guestLease)
    }

    public func observe(_ lease: Lease, _ request: ObserveRequest) async throws -> DisplayObservation {
        let (guest, guestLease) = try await leased(lease)
        return try await guest.observe(guestLease, request)
    }

    public func act(_ lease: Lease, _ batch: ActionBatch) async throws -> [ActionOutcome] {
        let (guest, guestLease) = try await leased(lease)
        return try await guest.act(guestLease, batch)
    }

    public func liveView(_ lease: Lease, role: DisplayLiveViewRole) async throws -> DisplayLiveView? {
        let (guest, guestLease) = try await leased(lease)
        if let liveViewServer {
            guard let liveFeed else { return nil }
            return try await liveViewServer.link(for: liveFeed, role: role)
        }
        return try await guest.liveView(guestLease, role: role)
    }

    public func endObservers(_ lease: Lease) async throws {
        let (guest, guestLease) = try await leased(lease)
        if let liveViewServer {
            if let liveFeed { await liveViewServer.endObservers(liveFeed) }
            return
        }
        try await guest.endObservers(guestLease)
    }

    public func liveViewers(_ lease: Lease) async throws -> Int {
        let (guest, guestLease) = try await leased(lease)
        if let liveViewServer {
            guard let liveFeed else { return 0 }
            return await liveViewServer.viewerCount(liveFeed, role: .user)
        }
        return try await guest.liveViewers(guestLease)
    }

    public func liveFrame(_ lease: Lease) async throws -> DisplayLiveViewFrame? {
        let (guest, guestLease) = try await leased(lease)
        return try await guest.liveFrame(guestLease)
    }

    public func liveInput(_ lease: Lease, _ input: DisplayLiveViewInput) async throws {
        let (guest, guestLease) = try await leased(lease)
        try await guest.liveInput(guestLease, input)
    }

    public func takeover(_ lease: Lease, on: Bool) async throws {
        let (guest, guestLease) = try await leased(lease)
        try await guest.takeover(guestLease, on: on)
        takeoverActive = on
        if let liveFeed { await liveViewServer?.setControl(on, for: liveFeed) }
    }

    // MARK: - Live view

    private func viewersChanged(_ count: Int) {
        guard current != nil else { return }
        if count > 0, frames == nil {
            frames = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.publishFrame()
                    try? await Task.sleep(for: self.liveViewFrameInterval)
                }
            }
        } else if count == 0 {
            frames?.cancel()
            frames = nil
        }
    }

    private func publishFrame() async {
        guard let current, let liveFeed, let liveViewServer,
              let frame = try? await current.guest.liveFrame(current.guestLease) else { return }
        await liveViewServer.publish(frame, to: liveFeed)
    }

    private func relayInput(_ input: DisplayLiveViewInput) async {
        guard takeoverActive, let current else { return }
        try? await current.guest.liveInput(current.guestLease, input)
    }

    private func leased(_ lease: Lease) async throws -> (any DisplayTarget, Lease) {
        guard await lock.holds(leaseID: lease.id), let current, current.lease.id == lease.id else { throw DisplayTargetError.leaseNotHeld }
        return (current.guest, current.guestLease)
    }
}

public struct LinuxGuestConfiguration: Sendable {
    public var id: DisplayTargetID
    public var label: String
    /// The guest account whose X session the driver uses, reached over SSH with key authentication.
    public var user: String
    public var identityFile: String?
    public var display: String
    public var sshOptions: [String]
    public var settleDelay: Duration
    public var liveViewFrameInterval: Duration

    public init(
        id: DisplayTargetID = "linux-vm",
        label: String = "Linux desktop (VM)",
        user: String,
        identityFile: String? = nil,
        display: String = ":0",
        sshOptions: [String] = ["BatchMode=yes", "StrictHostKeyChecking=accept-new", "UserKnownHostsFile=/dev/null", "ConnectTimeout=10"],
        settleDelay: Duration = .milliseconds(150),
        liveViewFrameInterval: Duration = .milliseconds(500)
    ) {
        self.id = id
        self.label = label
        self.user = user
        self.identityFile = identityFile
        self.display = display
        self.sshOptions = sshOptions
        self.settleDelay = settleDelay
        self.liveViewFrameInterval = liveViewFrameInterval
    }
}

public struct MacGuestConfiguration: Sendable {
    public var id: DisplayTargetID
    public var label: String
    /// The port the guest's display host listens on, with ``DisplayHostTCP``.
    public var port: Int
    public var secret: DisplayHostSecret
    /// How long to keep trying to reach the guest's display host while the guest finishes booting.
    public var connectTimeout: Duration
    public var liveViewFrameInterval: Duration

    public init(
        id: DisplayTargetID = "macos-vm",
        label: String = "macOS desktop (VM)",
        port: Int,
        secret: DisplayHostSecret,
        connectTimeout: Duration = .seconds(120),
        liveViewFrameInterval: Duration = .milliseconds(500)
    ) {
        self.id = id
        self.label = label
        self.port = port
        self.secret = secret
        self.connectTimeout = connectTimeout
        self.liveViewFrameInterval = liveViewFrameInterval
    }
}

extension VirtualMachineDisplayTarget {
    /// A Linux guest driven like the desktop container, with its tools run over SSH: the guest needs `xdotool`,
    /// ImageMagick, `xprop`, and an X session for `user` on `display`.
    public static func linux(
        controller: any VirtualMachineController,
        configuration: LinuxGuestConfiguration,
        liveView: DisplayLiveViewServer? = nil,
        host: any DisplayCommandRunner
    ) -> VirtualMachineDisplayTarget {
        let desktop = X11DesktopConfiguration(
            id: configuration.id,
            label: configuration.label,
            isolation: .vm,
            settleDelay: configuration.settleDelay,
            liveViewFrameInterval: configuration.liveViewFrameInterval
        )
        let manifest = X11DisplayTarget.manifest(for: desktop, servesLiveView: liveView != nil)
        return VirtualMachineDisplayTarget(manifest: manifest, controller: controller) { instance in
            let runner = SSHDisplayCommandRunner(
                destination: "\(configuration.user)@\(instance.address)",
                identityFile: configuration.identityFile,
                options: configuration.sshOptions,
                environment: ["DISPLAY": configuration.display],
                host: host
            )
            return X11DisplayTarget(configuration: desktop, liveView: liveView) { X11DesktopSession(runner: runner) }
        }
    }

    /// A macOS guest whose own display host (a ``DisplayHostServer`` serving the macOS driver, listening with
    /// ``DisplayHostTCP``) has the guest's screen-capture and accessibility permissions. Nobody uses the guest, so
    /// it is unshared, whatever the guest's driver declares.
    /// - Parameter liveView: Serves the guest's screen, from frames its display host sends, to the user and
    ///   observers. The guest's display host must give frames out (`MacHostDisplayTarget`'s `servesLiveFrames`).
    public static func macOS(
        controller: any VirtualMachineController,
        configuration: MacGuestConfiguration,
        liveView: DisplayLiveViewServer? = nil
    ) -> VirtualMachineDisplayTarget {
        let manifest = DisplayTargetManifest(
            id: configuration.id,
            label: configuration.label,
            platform: "macos",
            isolation: .vm,
            perception: [.pixels, .accessibility, .ocr],
            delivery: [.background, .foreground],
            semanticActions: [.press, .setValue, .focus, .menuPath, .launchApp, .openURL],
            observerAccess: liveView == nil ? .none : .stream,
            humanPresence: .exclusive
        )
        return VirtualMachineDisplayTarget(
            manifest: manifest,
            controller: controller,
            liveView: liveView,
            liveViewFrameInterval: configuration.liveViewFrameInterval
        ) { instance in
            let deadline = ContinuousClock.now.advanced(by: configuration.connectTimeout)
            while true {
                do {
                    let connection = try await DisplayHostTCP.connect(host: instance.address, port: configuration.port, secret: configuration.secret)
                    return try await RemoteDisplayTarget.connect(over: connection)
                } catch DisplayHostError.peerRejected {
                    throw DisplayHostError.peerRejected
                } catch {
                    guard ContinuousClock.now < deadline else { throw error }
                    try await Task.sleep(for: .seconds(2))
                }
            }
        }
    }
}
