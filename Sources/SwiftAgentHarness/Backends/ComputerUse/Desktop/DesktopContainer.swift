import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct DesktopContainerConfiguration: Sendable {
    public var id: DisplayTargetID
    public var label: String
    /// An image whose entrypoint starts an X server on `display` with a window manager, and has `xdotool`,
    /// ImageMagick, `xprop` and `procps`. `docker/desktop` in this repository builds one.
    public var image: String
    public var display: String
    /// The Docker network the container joins. `none` by default: the desktop reaches nothing.
    public var network: String
    public var docker: String
    /// More `docker run` arguments, such as resource limits.
    public var runArguments: [String]
    public var startTimeout: Duration
    public var settleDelay: Duration
    public var liveViewFrameInterval: Duration

    public init(
        id: DisplayTargetID = "desktop-container",
        label: String = "Linux desktop (container)",
        image: String = "swiftagentharness/desktop:latest",
        display: String = ":99",
        network: String = "none",
        docker: String = "docker",
        runArguments: [String] = ["--memory", "2g", "--pids-limit", "512", "--shm-size", "256m"],
        startTimeout: Duration = .seconds(30),
        settleDelay: Duration = .milliseconds(150),
        liveViewFrameInterval: Duration = .milliseconds(500)
    ) {
        self.id = id
        self.label = label
        self.image = image
        self.display = display
        self.network = network
        self.docker = docker
        self.runArguments = runArguments
        self.startTimeout = startTimeout
        self.settleDelay = settleDelay
        self.liveViewFrameInterval = liveViewFrameInterval
    }
}

/// Starts and removes the throwaway containers a desktop-container target leases.
enum DesktopContainer {
    static let label = "swiftagentharness.desktop"
    static let ownerLabel = "swiftagentharness.owner"

    static func start(_ configuration: DesktopContainerConfiguration, host: any DisplayCommandRunner) async throws -> X11DesktopSession {
        let docker = configuration.docker
        await removeStale(docker: docker, host: host)
        let name = "sah-desktop-\(UUID().uuidString.prefix(12).lowercased())"
        let run = [docker, "run", "--detach", "--rm", "--name", name, "--network", configuration.network,
                   "--label", "\(label)=1", "--label", "\(ownerLabel)=\(owner)",
                   "--env", "DISPLAY=\(configuration.display)"]
            + configuration.runArguments + [configuration.image]
        _ = try await host.output(run, timeout: .seconds(120))
        let remove: @Sendable () async -> Void = { _ = try? await host.run([docker, "rm", "--force", name], stdin: nil, timeout: .seconds(30)) }
        let runner = DockerExecDisplayCommandRunner(container: name, docker: docker, environment: ["DISPLAY": configuration.display], host: host)
        let deadline = ContinuousClock.now.advanced(by: configuration.startTimeout)
        while ContinuousClock.now < deadline {
            if (try? await runner.run(["xdotool", "getdisplaygeometry"], timeout: .seconds(5)))?.exitCode == 0 {
                return X11DesktopSession(runner: runner, shutdown: remove)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        await remove()
        throw DisplayTargetError.driverFailure("the desktop container's display didn't start within \(configuration.startTimeout)")
    }

    /// This process, as recorded on the containers it starts: `host-pid`.
    static var owner: String { "\(hostName)-\(getpid())" }

    static var hostName: String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "localhost" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Removes containers whose harness on this host has died, which `--rm` doesn't cover while they run.
    static func removeStale(docker: String, host: any DisplayCommandRunner) async {
        guard let listing = try? await host.output([docker, "ps", "--all", "--filter", "label=\(label)=1", "--format", "{{.ID}}\t{{.Label \"\(ownerLabel)\"}}"]) else { return }
        for line in listing.text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard fields.count == 2, let id = fields.first, isStale(owner: fields[1]) else { continue }
            _ = try? await host.run([docker, "rm", "--force", id], stdin: nil, timeout: .seconds(30))
        }
    }

    static func isStale(owner: String, hostName: String = hostName) -> Bool {
        guard let dash = owner.lastIndex(of: "-"), let pid = Int32(owner[owner.index(after: dash)...]) else { return false }
        guard owner[..<dash] == hostName, pid > 0 else { return false }
        return kill(pid, 0) != 0 && errno == ESRCH
    }
}

extension X11DisplayTarget {
    #if os(macOS) || os(Linux)
    /// A throwaway Linux desktop in a Docker container, started for each lease and removed on release. It has no
    /// user data and, by default, no network.
    public static func desktopContainer(
        configuration: DesktopContainerConfiguration = DesktopContainerConfiguration(),
        liveView: DisplayLiveViewServer? = nil,
        host: any DisplayCommandRunner = LocalDisplayCommandRunner()
    ) -> X11DisplayTarget {
        X11DisplayTarget(
            configuration: X11DesktopConfiguration(
                id: configuration.id,
                label: configuration.label,
                isolation: .container,
                settleDelay: configuration.settleDelay,
                liveViewFrameInterval: configuration.liveViewFrameInterval
            ),
            liveView: liveView
        ) {
            try await DesktopContainer.start(configuration, host: host)
        }
    }
    #endif
}
