import Foundation

#if os(Linux)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Spawns a child via `posix_spawn` into its own process group (`pgid == pid`) so that the
/// whole tree, including backgrounded grandchildren, can be signalled with `kill(-pgid, ...)`.
enum SupervisedSpawn {
    /// Raw file descriptors from a spawned child. The caller takes ownership and must close each
    /// fd ≥ 0. `stderrFD` is -1 for PTY mode (stdout/stderr merged on master). `stdinFD` is -1
    /// when stdin was not requested.
    struct Spawned {
        let pid: pid_t
        let stdoutFD: Int32
        let stderrFD: Int32
        let stdinFD: Int32
        let isPTY: Bool
    }

    static func spawn(argv: [String], envp: [String], wantsStdin: Bool, usePty: Bool = false) throws -> Spawned {
        guard let executable = argv.first else { throw SandboxBackendError.emptyCommand }
        if usePty {
            return try spawnWithPTY(argv: argv, executable: executable, envp: envp)
        }
        return try spawnWithPipes(argv: argv, executable: executable, envp: envp, wantsStdin: wantsStdin)
    }

    // MARK: - Pipe spawn

    private static func spawnWithPipes(argv: [String], executable: String, envp: [String], wantsStdin: Bool) throws -> Spawned {
        let outPipe = try makePipe()
        let errPipe = try makePipe()
        let inPipe = wantsStdin ? try makePipe() : nil

        #if canImport(Darwin) && !os(Linux)
        var fileActions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        #else
        var fileActions = posix_spawn_file_actions_t()
        var attr = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&fileActions)
        posix_spawnattr_init(&attr)
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attr)
        }

        posix_spawn_file_actions_adddup2(&fileActions, outPipe.write, 1)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe.write, 2)
        posix_spawn_file_actions_addclose(&fileActions, outPipe.read)
        posix_spawn_file_actions_addclose(&fileActions, outPipe.write)
        posix_spawn_file_actions_addclose(&fileActions, errPipe.read)
        posix_spawn_file_actions_addclose(&fileActions, errPipe.write)
        if let inPipe {
            posix_spawn_file_actions_adddup2(&fileActions, inPipe.read, 0)
            posix_spawn_file_actions_addclose(&fileActions, inPipe.read)
            posix_spawn_file_actions_addclose(&fileActions, inPipe.write)
        }

        var flags = Int16(POSIX_SPAWN_SETPGROUP)
        #if canImport(Darwin) && !os(Linux)
        flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #endif
        posix_spawnattr_setflags(&attr, flags)
        posix_spawnattr_setpgroup(&attr, 0)

        #if os(Linux)
        setCloexec(outPipe.read)
        setCloexec(errPipe.read)
        if let inPipe { setCloexec(inPipe.write) }
        #endif

        let argvC: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let envpC: [UnsafeMutablePointer<CChar>?] = envp.map { strdup($0) } + [nil]
        defer {
            argvC.forEach { free($0) }
            envpC.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &fileActions, &attr, argvC, envpC)

        close(outPipe.write)
        close(errPipe.write)
        if let inPipe { close(inPipe.read) }

        guard rc == 0 else {
            close(outPipe.read)
            close(errPipe.read)
            if let inPipe { close(inPipe.write) }
            throw SandboxBackendError.commandFailed("posix_spawn failed: \(String(cString: strerror(rc)))")
        }

        return Spawned(
            pid: pid,
            stdoutFD: outPipe.read,
            stderrFD: errPipe.read,
            stdinFD: inPipe.map { $0.write } ?? -1,
            isPTY: false
        )
    }

    // MARK: - PTY spawn

    private static func spawnWithPTY(argv: [String], executable: String, envp: [String]) throws -> Spawned {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else {
            throw SandboxBackendError.commandFailed("posix_openpt failed: \(String(cString: strerror(errno)))")
        }
        guard grantpt(master) == 0, unlockpt(master) == 0 else {
            close(master)
            throw SandboxBackendError.commandFailed("grantpt/unlockpt failed")
        }
        guard let slaveName = ptsname(master) else {
            close(master)
            throw SandboxBackendError.commandFailed("ptsname failed")
        }
        let slave = open(slaveName, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            close(master)
            throw SandboxBackendError.commandFailed("open slave PTY failed: \(String(cString: strerror(errno)))")
        }

        var ws = winsize()
        ws.ws_row = 24
        ws.ws_col = 80
        _ = ioctl(slave, TIOCSWINSZ, &ws)

        #if canImport(Darwin) && !os(Linux)
        var fileActions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        #else
        var fileActions = posix_spawn_file_actions_t()
        var attr = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&fileActions)
        posix_spawnattr_init(&attr)
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attr)
        }

        posix_spawn_file_actions_adddup2(&fileActions, slave, 0)
        posix_spawn_file_actions_adddup2(&fileActions, slave, 1)
        posix_spawn_file_actions_adddup2(&fileActions, slave, 2)
        posix_spawn_file_actions_addclose(&fileActions, master)
        if slave > 2 { posix_spawn_file_actions_addclose(&fileActions, slave) }

        var flags = Int16(POSIX_SPAWN_SETSID)
        #if canImport(Darwin) && !os(Linux)
        flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #endif
        posix_spawnattr_setflags(&attr, flags)

        #if os(Linux)
        setCloexec(master)
        #endif

        let argvC: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let envpC: [UnsafeMutablePointer<CChar>?] = envp.map { strdup($0) } + [nil]
        defer {
            argvC.forEach { free($0) }
            envpC.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &fileActions, &attr, argvC, envpC)

        close(slave)

        guard rc == 0 else {
            close(master)
            throw SandboxBackendError.commandFailed("posix_spawn (PTY) failed: \(String(cString: strerror(rc)))")
        }

        // Dup master so the reader and writer own independent fds
        let stdinFD = dup(master)
        return Spawned(pid: pid, stdoutFD: master, stderrFD: -1, stdinFD: stdinFD, isPTY: true)
    }

    // MARK: - Helpers

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else {
            throw SandboxBackendError.commandFailed("pipe failed: \(String(cString: strerror(errno)))")
        }
        return (fds[0], fds[1])
    }

    #if os(Linux)
    private static func setCloexec(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFD)
        if flags >= 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
    }
    #endif
}

/// Thread-safe holder for a spawned process group id (`pgid == pid`) so callers can signal the
/// whole group. `@unchecked Sendable` is sound because the lock guards all access to `pgid`.
final class ProcessGroupHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var pgid: pid_t?

    init(pid: pid_t) { self.pgid = pid }

    func signal(_ sig: Int32) {
        lock.lock()
        let target = pgid
        lock.unlock()
        if let target { _ = kill(-target, sig) }
    }

    func invalidate() {
        lock.lock()
        pgid = nil
        lock.unlock()
    }
}
