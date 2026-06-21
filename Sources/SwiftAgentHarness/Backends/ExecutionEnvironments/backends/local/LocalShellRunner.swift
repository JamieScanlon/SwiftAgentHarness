import Foundation

#if os(Linux)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum ShellProcessRunner {
    public struct RunResult: Sendable, Equatable {
        public let stdout: Data
        public let stderr: Data
        public let exitCode: Int32
    }

    /// Runs a short-lived, buffered child via Foundation `Process`.
    ///
    /// Timeout and task cancellation call `terminateImmediateChild`, which signals only the
    /// immediate local client (e.g. `docker`, `ssh`, `rsync`). Remote or in-container work may
    /// continue after the local client exits. Use for FS-bridge transport and workspace seeding,
    /// not long agent exec — prefer ``runSupervised`` for process-group teardown.
    public static func run(
        argv: [String],
        env: [String: String] = [:],
        cwd: String? = nil,
        stdin: Data? = nil,
        timeoutSeconds: TimeInterval? = nil,
        inheritHostEnvironment: Bool = true
    ) async throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        if let resolved = resolvedEnvironment(provided: env, inheritHostEnvironment: inheritHostEnvironment) {
            process.environment = resolved
        }
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        if stdin != nil {
            let inPipe = Pipe()
            process.standardInput = inPipe
            try process.run()
            if let stdin {
                inPipe.fileHandleForWriting.write(stdin)
                try inPipe.fileHandleForWriting.close()
            }
        } else {
            try process.run()
        }
        async let stdoutDrain = drain(outPipe.fileHandleForReading)
        async let stderrDrain = drain(errPipe.fileHandleForReading)
        let start = Date()
        do {
            while process.isRunning {
                try Task.checkCancellation()
                if let timeoutSeconds, Date().timeIntervalSince(start) > timeoutSeconds {
                    throw SandboxBackendError.commandFailed("timed out")
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        } catch {
            terminateImmediateChild(process)
            _ = await stdoutDrain
            _ = await stderrDrain
            throw error
        }
        return RunResult(stdout: await stdoutDrain, stderr: await stderrDrain, exitCode: process.terminationStatus)
    }

    /// Runs a long-lived, abortable exec spawned into its own process group so timeout, Task
    /// cancellation, and explicit kill tear down the entire tree (including backgrounded
    /// grandchildren) via `kill(-pgid, ...)`.
    public static func runSupervised(
        argv: [String],
        env: [String: String] = [:],
        cwd: String? = nil,
        stdin: Data? = nil,
        timeoutSeconds: TimeInterval? = nil,
        usePty: Bool = false,
        inheritHostEnvironment: Bool = true
    ) async throws -> RunResult {
        let handle = try startSupervised(
            argv: argv,
            env: env,
            cwd: cwd,
            stdin: stdin,
            usePty: usePty,
            inheritHostEnvironment: inheritHostEnvironment
        )
        return try await withTaskCancellationHandler {
            try await handle.wait(timeoutSeconds: timeoutSeconds)
        } onCancel: {
            handle.terminate()
        }
    }

    /// Spawns a supervised exec and returns a killable handle without waiting for it to finish.
    /// Used by the background registry, which must be able to signal the group before completion.
    static func startSupervised(
        argv: [String],
        env: [String: String] = [:],
        cwd: String? = nil,
        stdin: Data? = nil,
        keepStdinOpen: Bool = false,
        usePty: Bool = false,
        inheritHostEnvironment: Bool = true,
        maxLiveBufferBytes: Int = BashProcessRegistry.maxLiveBufferBytes
    ) throws -> SupervisedHandle {
        let envDict = resolvedEnvironment(provided: env, inheritHostEnvironment: inheritHostEnvironment)
            ?? ProcessInfo.processInfo.environment
        let envp = envDict.map { "\($0.key)=\($0.value)" }
        let effectiveArgv = cwd.map { ["/bin/sh", "-c", "cd \(shellQuote($0)) && exec \"$@\"", "sh"] + argv } ?? argv
        let spawned = try SupervisedSpawn.spawn(
            argv: effectiveArgv,
            envp: envp,
            wantsStdin: keepStdinOpen || stdin != nil,
            usePty: usePty
        )
        return SupervisedHandle(
            spawned: spawned,
            initialStdin: stdin,
            keepStdinOpen: keepStdinOpen,
            maxLiveBufferBytes: maxLiveBufferBytes
        )
    }

    public static func runShell(
        script: String,
        args: [String] = [],
        env: [String: String] = [:],
        workdir: String? = nil,
        stdin: Data? = nil
    ) async throws -> SandboxBackendCommandResult {
        var argv = ["/bin/bash", "-c", script]
        argv.append(contentsOf: args)
        let result = try await run(argv: argv, env: env, cwd: workdir, stdin: stdin)
        return SandboxBackendCommandResult(stdout: result.stdout, stderr: result.stderr, code: result.exitCode)
    }

    /// Drains a pipe concurrently with the running process so the child never blocks on a
    /// full pipe buffer. Resolves when an empty chunk (EOF) arrives after the write ends close.
    static func drain(_ handle: FileHandle) async -> Data {
        let buffer = DataBuffer(maxBytes: Int.max)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            handle.readabilityHandler = { fileHandle in
                let chunk = fileHandle.availableData
                if chunk.isEmpty {
                    fileHandle.readabilityHandler = nil
                    continuation.resume()
                } else {
                    buffer.append(chunk)
                }
            }
        }
        return buffer.contents
    }

    static func reap(pid: pid_t, group: ProcessGroupHandle, timeoutSeconds: TimeInterval?) async throws -> Int32 {
        let start = Date()
        while true {
            try Task.checkCancellation()
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return decodeStatus(status) }
            if result == -1 { return -1 }
            if let timeoutSeconds, Date().timeIntervalSince(start) > timeoutSeconds {
                group.signal(SIGTERM)
                try? await Task.sleep(nanoseconds: 200_000_000)
                group.signal(SIGKILL)
                waitpidBlocking(pid)
                throw SandboxBackendError.commandFailed("timed out")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    static func decodeStatus(_ status: Int32) -> Int32 {
        (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }

    static func waitpidBlocking(_ pid: pid_t) {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Terminates the direct child only; does not signal a process group or remote/container work.
    private static func terminateImmediateChild(_ process: Process) {
        process.terminate()
        process.waitUntilExit()
    }

    static func resolvedEnvironment(provided: [String: String], inheritHostEnvironment: Bool) -> [String: String]? {
        if inheritHostEnvironment {
            if provided.isEmpty { return nil }
            var merged = ProcessInfo.processInfo.environment
            provided.forEach { merged[$0.key] = $0.value }
            return merged
        }
        return provided
    }
}

/// A spawned supervised process that drains output via raw `read()` threads into live buffers
/// (EIO-safe for PTY masters) and whose entire process group can be killed via `terminate()`.
/// `@unchecked Sendable` is sound: `group`'s lock protects pgid; `stdinLock` protects `stdinFD`;
/// `liveOut`/`liveErr` are `@unchecked Sendable` DataBuffers with their own locks.
final class SupervisedHandle: @unchecked Sendable {
    let group: ProcessGroupHandle
    private let pid: pid_t
    private let liveOut: DataBuffer
    private let liveErr: DataBuffer
    private let outDoneTask: Task<Void, Never>
    private let errDoneTask: Task<Void, Never>?
    private let stdinLock = NSLock()
    private var stdinFD: Int32

    var liveStdout: Data { liveOut.contents }
    var liveStderr: Data { liveErr.contents }
    var liveStdoutBuffer: DataBuffer { liveOut }
    var liveStderrBuffer: DataBuffer { liveErr }

    init(spawned: SupervisedSpawn.Spawned, initialStdin: Data?, keepStdinOpen: Bool, maxLiveBufferBytes: Int = BashProcessRegistry.maxLiveBufferBytes) {
        self.pid = spawned.pid
        self.group = ProcessGroupHandle(pid: spawned.pid)
        let outBuf = DataBuffer(maxBytes: maxLiveBufferBytes)
        let errBuf = DataBuffer(maxBytes: maxLiveBufferBytes)
        self.liveOut = outBuf
        self.liveErr = errBuf
        self.stdinFD = (keepStdinOpen && spawned.stdinFD >= 0) ? spawned.stdinFD : -1

        let outFD = spawned.stdoutFD
        self.outDoneTask = Task {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                Thread.detachNewThread {
                    SupervisedHandle.readPump(fd: outFD, into: outBuf)
                    cont.resume()
                }
            }
        }

        let errFD = spawned.stderrFD
        if errFD >= 0 {
            self.errDoneTask = Task {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    Thread.detachNewThread {
                        SupervisedHandle.readPump(fd: errFD, into: errBuf)
                        cont.resume()
                    }
                }
            }
        } else {
            self.errDoneTask = nil
        }

        if let initialStdin, spawned.stdinFD >= 0 {
            let fd = spawned.stdinFD
            initialStdin.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress, ptr.count > 0 else { return }
                _ = write(fd, base, ptr.count)
            }
        }
        if !keepStdinOpen && spawned.stdinFD >= 0 {
            close(spawned.stdinFD)
        }
    }

    var stdinClosed: Bool {
        stdinLock.lock()
        defer { stdinLock.unlock() }
        return stdinFD < 0
    }

    func terminate() {
        closeStdin()
        group.signal(SIGKILL)
    }

    func sendKeys(_ data: Data) {
        stdinLock.lock()
        let fd = stdinFD
        stdinLock.unlock()
        guard fd >= 0 else { return }
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress, ptr.count > 0 else { return }
            _ = write(fd, base, ptr.count)
        }
    }

    func closeStdin() {
        stdinLock.lock()
        let fd = stdinFD
        stdinFD = -1
        stdinLock.unlock()
        if fd >= 0 { close(fd) }
    }

    deinit {
        closeStdin()
    }

    func wait(timeoutSeconds: TimeInterval?) async throws -> ShellProcessRunner.RunResult {
        defer { closeStdin() }
        do {
            let exitCode = try await ShellProcessRunner.reap(pid: pid, group: group, timeoutSeconds: timeoutSeconds)
            group.invalidate()
            _ = await outDoneTask.value
            _ = await errDoneTask?.value
            return ShellProcessRunner.RunResult(stdout: liveOut.contents, stderr: liveErr.contents, exitCode: exitCode)
        } catch {
            group.signal(SIGKILL)
            ShellProcessRunner.waitpidBlocking(pid)
            group.invalidate()
            _ = await outDoneTask.value
            _ = await errDoneTask?.value
            throw error
        }
    }

    /// Drains `fd` using raw `read()` so EIO (PTY master on Linux after child exit) is handled
    /// safely — `FileHandle.availableData` would raise an uncatchable ObjC exception on EIO.
    private static func readPump(fd: Int32, into buffer: DataBuffer) {
        var tmp = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = tmp.withUnsafeMutableBytes { ptr -> Int in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if n <= 0 { break }
            buffer.append(Data(tmp.prefix(n)))
        }
        close(fd)
    }
}

/// Thread-safe bounded ring buffer for live pipe output. `@unchecked Sendable` is sound because
/// the lock guards all access to mutable state.
final class DataBuffer: @unchecked Sendable {
    let maxBytes: Int
    private let lock = NSLock()
    private(set) var totalBytes = 0
    private var storage = Data()

    init(maxBytes: Int = BashProcessRegistry.maxLiveBufferBytes) {
        self.maxBytes = maxBytes
    }

    func append(_ chunk: Data) {
        lock.lock()
        totalBytes += chunk.count
        storage.append(chunk)
        if storage.count > maxBytes {
            storage = Data(storage.suffix(maxBytes))
        }
        lock.unlock()
    }

    var contents: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var droppedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return max(0, totalBytes - storage.count)
    }

    var isTruncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return totalBytes > maxBytes
    }

    func slice(fromLogicalOffset offset: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        let dropped = max(0, totalBytes - storage.count)
        let start = max(offset, dropped)
        guard start < totalBytes else { return Data() }
        let localOffset = start - dropped
        guard localOffset < storage.count else { return Data() }
        return Data(storage.dropFirst(localOffset))
    }
}

#if os(macOS)
import CryptoKit
import Logging

enum LocalSeatbelt {
    static func profile(workspaceRoot: String, memoryDirectory: String?) -> String {
        var lines = [
            "(version 1)",
            "(import \"dyld-support.sb\")",
            "(deny default)",
            "(allow file-read* (subpath \(q(workspaceRoot))))",
            "(allow file-write* (subpath \(q(workspaceRoot))))",
            "(allow file-read* (subpath \"/bin\"))",
            "(allow file-read* (subpath \"/usr\"))",
            "(allow file-read* (subpath \"/System/Library\"))",
            "(allow file-read* (subpath \"/Library\"))",
            "(allow process-exec (literal \"/bin/bash\"))",
            "(allow process-exec (subpath \"/usr/bin\"))",
            "(allow process-exec (subpath \"/bin\"))",
            "(allow process-fork)",
            "(allow file-map-executable)",
            "(allow sysctl-read)",
            "(allow mach-lookup)",
            "(allow signal)",
            "(allow ipc-posix-shm*)",
            "(allow file-read* (subpath \"/tmp\"))",
            "(allow file-write* (subpath \"/tmp\"))",
            "(allow file-read-metadata)",
            "(deny network*)",
        ]
        if let memoryDirectory {
            lines.insert("(allow file-read* (subpath \(q(memoryDirectory))))", at: 3)
            lines.insert("(allow file-write* (subpath \(q(memoryDirectory))))", at: 5)
        }
        return lines.joined(separator: "\n")
    }

    static func wrapExecArgv(command: String, workspaceRoot: String, memoryDirectory: String?) -> [String] {
        let profile = profile(workspaceRoot: workspaceRoot, memoryDirectory: memoryDirectory)
        return ["/usr/bin/sandbox-exec", "-p", profile, "/bin/bash", "-c", command]
    }

    private static func q(_ path: String) -> String { "\"\(path)\"" }
}
#endif

enum LinuxBwrapMountPolicy {
    static let candidatePaths = ["/usr", "/bin", "/lib", "/lib64", "/etc"]

    static func hostReadOnlyMounts(fileManager: FileManager = .default) -> [(String, String)] {
        candidatePaths
            .filter { fileManager.fileExists(atPath: $0) }
            .map { ($0, $0) }
    }
}

enum LinuxBwrapEnvPolicy {
    static func setenvFlags(env: [String: String]) -> [String] {
        var argv = ["--clearenv"]
        for (key, value) in env.sorted(by: { $0.key < $1.key }) {
            argv += ["--setenv", key, value]
        }
        return argv
    }
}

#if os(Linux)
enum LinuxBwrap {
    static func wrapExecArgv(command: String, workspaceRoot: String, memoryDirectory: String?, env: [String: String]) -> [String] {
        var argv = ["/usr/bin/bwrap"]
        for mount in LinuxBwrapMountPolicy.hostReadOnlyMounts() {
            argv += ["--ro-bind", mount.0, mount.1]
        }
        argv += [
            "--proc", "/proc",
            "--dev", "/dev",
            "--tmpfs", "/tmp",
            "--bind", workspaceRoot, workspaceRoot,
            "--chdir", workspaceRoot,
            "--unshare-net",
            "--unshare-pid",
            "--die-with-parent",
        ]
        if let memoryDirectory {
            argv += ["--bind", memoryDirectory, memoryDirectory]
        }
        argv += LinuxBwrapEnvPolicy.setenvFlags(env: env)
        argv += ["--", "/bin/bash", "-c", command]
        return argv
    }
}
#endif

public enum LocalExecArgv {
    public static func sandboxed(command: String, workspaceRoot: String, memoryDirectory: String?, env: [String: String]) -> [String] {
        #if os(macOS)
        return LocalSeatbelt.wrapExecArgv(command: command, workspaceRoot: workspaceRoot, memoryDirectory: memoryDirectory)
        #elseif os(Linux)
        return LinuxBwrap.wrapExecArgv(command: command, workspaceRoot: workspaceRoot, memoryDirectory: memoryDirectory, env: env)
        #else
        return ["/bin/bash", "-c", command]
        #endif
    }

    public static var isSandboxAvailable: Bool {
        #if os(macOS)
        FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec")
        #elseif os(Linux)
        FileManager.default.isExecutableFile(atPath: "/usr/bin/bwrap")
        #else
        false
        #endif
    }
}
