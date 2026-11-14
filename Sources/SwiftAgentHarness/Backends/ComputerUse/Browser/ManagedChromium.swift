#if os(macOS) || os(Linux)
import Foundation

public struct ManagedChromiumConfiguration: Sendable {
    /// The Chromium-family executable. `nil` looks in the usual install locations.
    public var executable: URL?
    /// A headed browser shows a window the user can watch and take over in; a headless one shows nothing.
    public var headless: Bool
    /// The page viewport in CSS pixels: the target's whole coordinate space.
    public var viewport: ImagePixelSize
    public var extraArguments: [String]
    /// How long to wait for the browser to answer on its pipe.
    public var startTimeout: Duration
    /// Where each launch makes its throwaway profile. Launching also removes profiles here whose browser is gone,
    /// such as one left by a harness that was killed.
    public var profileRoot: URL

    public static var defaultProfileRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SwiftAgentHarness-browser-profiles", isDirectory: true)
    }

    public init(
        executable: URL? = nil,
        headless: Bool = false,
        viewport: ImagePixelSize = ImagePixelSize(width: 1280, height: 800),
        extraArguments: [String] = [],
        startTimeout: Duration = .seconds(20),
        profileRoot: URL = ManagedChromiumConfiguration.defaultProfileRoot
    ) {
        self.executable = executable
        self.headless = headless
        self.viewport = viewport
        self.extraArguments = extraArguments
        self.startTimeout = startTimeout
        self.profileRoot = profileRoot
    }

    public static let executableCandidates: [String] = [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
        "/usr/bin/chromium",
        "/usr/bin/chromium-browser",
        "/usr/bin/google-chrome",
    ]

    /// The executable to launch, or `nil` when none is configured or installed.
    public func resolvedExecutable(fileManager: FileManager = .default) -> URL? {
        if let executable { return fileManager.isExecutableFile(atPath: executable.path) ? executable : nil }
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = Self.executableCandidates + Self.executableCandidates.filter { $0.hasPrefix("/Applications/") }.map { home + $0 }
        return candidates.first(where: fileManager.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    /// The command line: a throwaway profile, the pipe instead of a debugging port, and every connection through
    /// the policy proxy, loopback included. Local name resolution is disabled so nothing bypasses the proxy's checks.
    func arguments(profile: URL, proxyPort: Int) -> [String] {
        var arguments = [
            "--user-data-dir=\(profile.path)",
            "--remote-debugging-pipe",
            "--proxy-server=socks5://127.0.0.1:\(proxyPort)",
            "--proxy-bypass-list=<-loopback>",
            "--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE 127.0.0.1",
            "--disable-quic",
            "--force-webrtc-ip-handling-policy=disable_non_proxied_udp",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-background-networking",
            "--disable-component-update",
            "--disable-default-apps",
            "--disable-extensions",
            "--disable-sync",
            "--disable-features=Translate,OptimizationHints,MediaRouter,DialMediaRouteProvider,AutofillServerCommunication",
            "--password-store=basic",
            "--use-mock-keychain",
            "--window-size=\(viewport.width),\(viewport.height + 120)",
        ]
        if headless { arguments.append("--headless=new") }
        return arguments + extraArguments + ["about:blank"]
    }
}

public enum ManagedChromiumError: Error, Sendable, Equatable, CustomStringConvertible {
    case executableNotFound
    case launchFailed(String)

    public var description: String {
        switch self {
        case .executableNotFound: return "no Chromium-family browser is installed; set the executable"
        case .launchFailed(let reason): return "the browser did not start: \(reason)"
        }
    }
}

/// One Chromium process with a throwaway profile, driven over its debugging pipe. Shutting it down kills the
/// process and deletes the profile. Chromium exits by itself when the pipe closes, so a harness that dies without
/// shutting down takes its browsers with it; the next launch removes their profiles.
public actor ManagedChromium {
    public nonisolated let connection: CDPConnection
    public nonisolated let processID: pid_t
    private let profile: URL
    private var exited = false

    private init(connection: CDPConnection, processID: pid_t, profile: URL) {
        self.connection = connection
        self.processID = processID
        self.profile = profile
    }

    public static func launch(_ configuration: ManagedChromiumConfiguration, proxyPort: Int) async throws -> ManagedChromium {
        guard let executable = configuration.resolvedExecutable() else { throw ManagedChromiumError.executableNotFound }
        let root = configuration.profileRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        removeStaleProfiles(in: root, hostName: currentHostName(), now: Date())
        let profile = root.appendingPathComponent("\(profilePrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // The browser reads commands on fd 3 and writes replies on fd 4.
        let toBrowser: (read: Int32, write: Int32)
        let fromBrowser: (read: Int32, write: Int32)
        do {
            toBrowser = try makePipe()
            do {
                fromBrowser = try makePipe()
            } catch {
                close(toBrowser.read)
                close(toBrowser.write)
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: profile)
            throw error
        }
        #if os(macOS)
        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // dup2 clears close-on-exec on the copies, so the browser keeps fds 3 and 4 and nothing else of the pipes.
        posix_spawn_file_actions_adddup2(&actions, toBrowser.read, 3)
        posix_spawn_file_actions_adddup2(&actions, fromBrowser.write, 4)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        #if os(macOS)
        // The harness's own sockets and files stay out of the browser: only the descriptors above are inherited.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        #endif

        let argv = [executable.path] + configuration.arguments(profile: profile, proxyPort: proxyPort)
        var cArguments = argv.map { strdup($0) } + [nil]
        defer { cArguments.forEach { free($0) } }
        var processID: pid_t = 0
        let status = posix_spawn(&processID, executable.path, &actions, &attributes, &cArguments, environ)
        close(toBrowser.read)
        close(fromBrowser.write)
        guard status == 0 else {
            close(toBrowser.write)
            close(fromBrowser.read)
            try? FileManager.default.removeItem(at: profile)
            throw ManagedChromiumError.launchFailed("posix_spawn failed: \(String(cString: strerror(status)))")
        }

        let connection = CDPConnection(transport: CDPPipeTransport(readFrom: fromBrowser.read, writeTo: toBrowser.write))
        await connection.start()
        let browser = ManagedChromium(connection: connection, processID: processID, profile: profile)
        do {
            try await browser.waitUntilReady(timeout: configuration.startTimeout)
        } catch {
            await browser.shutdown()
            throw error
        }
        return browser
    }

    private func waitUntilReady(timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while true {
            do {
                _ = try await connection.send("Browser.getVersion")
                return
            } catch let error as CDPError where error == .closed {
                throw ManagedChromiumError.launchFailed("the browser exited during startup")
            } catch {
                guard ContinuousClock.now < deadline else { throw ManagedChromiumError.launchFailed("\(error)") }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Asks the browser to close, kills it if it doesn't, and deletes the profile. Idempotent.
    public func shutdown() async {
        guard !exited else { return }
        exited = true
        _ = try? await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try await self.connection.send("Browser.close") }
            group.addTask { try await Task.sleep(for: .seconds(2)) }
            try await group.next()
            group.cancelAll()
        }
        await connection.close()
        let processID = processID
        await Task.detached {
            if !Self.reap(processID, within: .seconds(3)) {
                kill(processID, SIGKILL)
                var status: Int32 = 0
                waitpid(processID, &status, 0)
            }
        }.value
        try? FileManager.default.removeItem(at: profile)
    }

    /// `true` once the child is reaped, here or already: signalling a pid after that could hit an unrelated process.
    private static func reap(_ processID: pid_t, within limit: Duration) -> Bool {
        let deadline = ContinuousClock.now + limit
        var signalled = false
        while ContinuousClock.now < deadline {
            if reaped(processID) { return true }
            if !signalled, ContinuousClock.now > deadline - .seconds(2) {
                kill(processID, SIGTERM)
                signalled = true
            }
            usleep(50_000)
        }
        return reaped(processID)
    }

    private static func reaped(_ processID: pid_t) -> Bool {
        var status: Int32 = 0
        let result = waitpid(processID, &status, WNOHANG)
        return result == processID || (result == -1 && errno == ECHILD)
    }

    static let profilePrefix = "managed-browser-"
    /// A profile with no browser lock is one whose browser exited, or one still launching.
    static let unlockedProfileGrace: TimeInterval = 600

    /// A pipe whose ends are close-on-exec and above fd 4. A child spawned meanwhile, by anything in the process,
    /// then can't hold the browser's pipe open after the harness exits, and the dup2 onto fds 3 and 4 always copies.
    static func makePipe() throws -> (read: Int32, write: Int32) {
        var raw: [Int32] = [0, 0]
        guard pipe(&raw) == 0 else { throw ManagedChromiumError.launchFailed("could not create a pipe: errno \(errno)") }
        defer { close(raw[0]); close(raw[1]) }
        let read = fcntl(raw[0], F_DUPFD_CLOEXEC, 5)
        let write = fcntl(raw[1], F_DUPFD_CLOEXEC, 5)
        guard read >= 0, write >= 0 else {
            if read >= 0 { close(read) }
            if write >= 0 { close(write) }
            throw ManagedChromiumError.launchFailed("could not create a pipe: errno \(errno)")
        }
        return (read, write)
    }

    /// Deletes this launcher's profiles in `root` whose browser is gone. Chromium holds a `SingletonLock` link to
    /// "<host>-<pid>" while it runs: a profile locked by a dead process on this host is stale, as is an unlocked one
    /// untouched for ``unlockedProfileGrace``. Profiles locked from another host are left alone.
    static func removeStaleProfiles(in root: URL, hostName: String, now: Date) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasPrefix(profilePrefix) {
            let profile = root.appendingPathComponent(name, isDirectory: true)
            if let lock = try? fileManager.destinationOfSymbolicLink(atPath: profile.appendingPathComponent("SingletonLock").path) {
                guard let separator = lock.lastIndex(of: "-"),
                      lock[..<separator] == hostName,
                      let processID = pid_t(lock[lock.index(after: separator)...]),
                      !isRunning(processID)
                else { continue }
            } else {
                guard let modified = (try? fileManager.attributesOfItem(atPath: profile.path))?[.modificationDate] as? Date,
                      now.timeIntervalSince(modified) > unlockedProfileGrace
                else { continue }
            }
            try? fileManager.removeItem(at: profile)
        }
    }

    private static func isRunning(_ processID: pid_t) -> Bool {
        processID > 0 && (kill(processID, 0) == 0 || errno == EPERM)
    }

    static func currentHostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
#endif
