#if os(macOS)
import Darwin
import Foundation

/// Why a ``ProcessTerminal`` cannot drive this process's stdio.
///
/// The package targets Apple platforms, so a real terminal exists only on macOS. Rather
/// than handing a host a silently dead terminal that accepts every call and does nothing,
/// the reason is surfaced so startup can fail loudly or fall back to a headless surface.
public enum TerminalUnavailabilityReason: String, Sendable, Equatable {
    /// stdin/stdout are not a terminal (piped, redirected, or running under a test harness).
    case notATTY
    /// This platform has no `ProcessTerminal` implementation.
    case unsupportedPlatform
}

/// Restores the tty on abnormal exit.
///
/// `stop()` is not enough on its own: raw mode clears `ECHO` and `ISIG`, hides the
/// cursor and enables bracketed paste, so any path that skips `stop()` — a trap, an
/// uncaught error, an external `SIGTERM` — leaves the user's shell unusable and needing
/// a blind `reset`. Armed for the lifetime of raw mode.
final class TerminalRestoreState: @unchecked Sendable {
    static let shared = TerminalRestoreState()

    private let lock = NSLock()
    private var saved: termios?
    private var hooksInstalled = false
    private var signalSources: [DispatchSourceSignal] = []

    func arm(_ state: termios) {
        lock.lock()
        saved = state
        let needsHooks = !hooksInstalled
        hooksInstalled = true
        lock.unlock()
        guard needsHooks else { return }
        atexit(swiftAgentHarnessRestoreTerminalAtExit)
        installSignalHooks()
    }

    func disarm() {
        lock.lock()
        saved = nil
        lock.unlock()
    }

    func restoreNow() {
        lock.lock()
        let state = saved
        saved = nil
        lock.unlock()
        guard var state else { return }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &state)
        let epilogue = TUIEscapes.syncOutputOff
            + TUIEscapes.bracketedPasteOff
            + TUIEscapes.showCursor
        epilogue.withCString { pointer in
            _ = Darwin.write(STDOUT_FILENO, pointer, strlen(pointer))
        }
    }

    private func installSignalHooks() {
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInitiated))
            source.setEventHandler { [weak self] in
                self?.restoreNow()
                exit(128 + signalNumber)
            }
            source.resume()
            lock.lock()
            signalSources.append(source)
            lock.unlock()
        }
    }
}

/// `atexit` takes a C function pointer, which cannot capture context.
private func swiftAgentHarnessRestoreTerminalAtExit() {
    TerminalRestoreState.shared.restoreNow()
}

/// Real stdio terminal implementation for macOS. Not used in CI tests.
/// `@unchecked Sendable`: mutable state is guarded by `NSLock`; callbacks are dispatched off-thread.
public final class ProcessTerminal: Terminal, @unchecked Sendable {
    private var storedColumns: Int
    private var storedRows: Int

    public var columns: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedColumns
    }

    public var rows: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedRows
    }

    private var onInput: (@Sendable (String) -> Void)?
    private var onResize: (@Sendable (Int, Int) -> Void)?
    private var originalTermios: termios?
    private var readSource: DispatchSourceRead?
    private var resizeSource: DispatchSourceSignal?
    /// Bytes of a multi-byte UTF-8 sequence split across two reads.
    private var pendingInputBytes: [UInt8] = []
    private let lock = NSLock()
    private var started = false

    public init(columns: Int = 80, rows: Int = 24) {
        self.storedColumns = columns
        self.storedRows = rows
        updateSizeFromEnvironment()
    }

    public static var isTTY: Bool {
        isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
    }

    /// `nil` when a real terminal is available.
    public static var unavailabilityReason: TerminalUnavailabilityReason? {
        isTTY ? nil : .notATTY
    }

    public func start(onInput: @escaping @Sendable (String) -> Void, onResize: @escaping @Sendable (Int, Int) -> Void) {
        lock.lock()
        guard !started, Self.isTTY else {
            lock.unlock()
            return
        }
        self.onInput = onInput
        self.onResize = onResize
        started = true
        lock.unlock()

        enableRawMode()
        write(TUIEscapes.bracketedPasteOn)
        // `?2026` is not a session-level mode — setting it *begins* a synchronized
        // update, which the renderer does per frame. Enabling it here would open a
        // block nothing closes.
        write(TUIEscapes.hideCursor)
        installReaders()
    }

    public func stop() {
        lock.lock()
        guard started else {
            lock.unlock()
            return
        }
        readSource?.cancel()
        readSource = nil
        resizeSource?.cancel()
        resizeSource = nil
        started = false
        onInput = nil
        onResize = nil
        pendingInputBytes = []
        lock.unlock()

        write(TUIEscapes.bracketedPasteOff)
        write(TUIEscapes.showCursor)
        restoreTerminalMode()
    }

    public func write(_ data: String) {
        guard let bytes = data.data(using: .utf8) else { return }
        bytes.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return }
            var remaining = bytes.count
            // A single `write` can return short on a slow tty; without the loop a large
            // frame is emitted truncated, usually mid-escape-sequence.
            while remaining > 0 {
                let written = Darwin.write(STDOUT_FILENO, base, remaining)
                if written > 0 {
                    base = base.advanced(by: written)
                    remaining -= written
                    continue
                }
                if written < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                break
            }
        }
    }

    private func enableRawMode() {
        var current = termios()
        tcgetattr(STDIN_FILENO, &current)
        lock.lock()
        originalTermios = current
        lock.unlock()
        TerminalRestoreState.shared.arm(current)

        var raw = current
        raw.c_iflag &= ~UInt(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON)
        raw.c_oflag &= ~UInt(OPOST)
        raw.c_cflag |= UInt(CS8)
        raw.c_lflag &= ~UInt(ECHO | ECHONL | ICANON | IEXTEN | ISIG)
        raw.c_cc.16 = 1
        raw.c_cc.17 = 0
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    }

    private func restoreTerminalMode() {
        lock.lock()
        let saved = originalTermios
        originalTermios = nil
        lock.unlock()
        guard var original = saved else { return }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        TerminalRestoreState.shared.disarm()
    }

    private func installReaders() {
        let inputSource = DispatchSource.makeReadSource(
            fileDescriptor: STDIN_FILENO,
            queue: .global(qos: .userInteractive)
        )
        inputSource.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            guard count > 0 else { return }
            self.deliver(bytes: Array(buffer.prefix(count)))
        }
        inputSource.resume()

        signal(SIGWINCH, SIG_IGN)
        let resize = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global(qos: .utility))
        resize.setEventHandler { [weak self] in
            self?.handleResize()
        }
        resize.resume()

        lock.lock()
        readSource = inputSource
        resizeSource = resize
        lock.unlock()
    }

    /// Decodes a read, carrying any trailing partial UTF-8 sequence into the next one.
    ///
    /// Decoding each read independently replaces a code point straddling the boundary
    /// with U+FFFD — which corrupts exactly the CJK and emoji input the IME support
    /// exists for.
    private func deliver(bytes: [UInt8]) {
        lock.lock()
        var combined = pendingInputBytes
        combined.append(contentsOf: bytes)
        let (complete, partial) = Self.splitTrailingPartialUTF8(combined)
        pendingInputBytes = partial
        let handler = onInput
        lock.unlock()

        guard !complete.isEmpty else { return }
        handler?(String(decoding: complete, as: UTF8.self))
    }

    static func splitTrailingPartialUTF8(_ bytes: [UInt8]) -> (complete: [UInt8], partial: [UInt8]) {
        guard !bytes.isEmpty else { return ([], []) }
        // Walk back over continuation bytes to the last sequence lead byte.
        var index = bytes.count - 1
        var continuationCount = 0
        while index >= 0, bytes[index] & 0b1100_0000 == 0b1000_0000 {
            continuationCount += 1
            index -= 1
            if continuationCount > 3 { return (bytes, []) }
        }
        guard index >= 0 else { return (bytes, []) }

        let lead = bytes[index]
        let expected: Int
        if lead & 0b1000_0000 == 0 { expected = 1 }
        else if lead & 0b1110_0000 == 0b1100_0000 { expected = 2 }
        else if lead & 0b1111_0000 == 0b1110_0000 { expected = 3 }
        else if lead & 0b1111_1000 == 0b1111_0000 { expected = 4 }
        else { return (bytes, []) }

        let available = bytes.count - index
        guard available < expected else { return (bytes, []) }
        return (Array(bytes[..<index]), Array(bytes[index...]))
    }

    private func handleResize() {
        updateSizeFromEnvironment()
        lock.lock()
        let handler = onResize
        let currentColumns = storedColumns
        let currentRows = storedRows
        lock.unlock()
        handler?(currentColumns, currentRows)
    }

    private func updateSizeFromEnvironment() {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 {
            lock.lock()
            storedColumns = Int(size.ws_col)
            storedRows = Int(size.ws_row)
            lock.unlock()
        } else if let envCols = ProcessInfo.processInfo.environment["COLUMNS"].flatMap(Int.init),
                  let envRows = ProcessInfo.processInfo.environment["LINES"].flatMap(Int.init) {
            lock.lock()
            storedColumns = envCols
            storedRows = envRows
            lock.unlock()
        }
    }
}
#else
import Foundation

/// Why a ``ProcessTerminal`` cannot drive this process's stdio.
public enum TerminalUnavailabilityReason: String, Sendable, Equatable {
    case notATTY
    case unsupportedPlatform
}

/// `ProcessTerminal` is only available on macOS in this package.
///
/// The package declares `.macOS`, `.iOS` and `.visionOS` platforms, so a Linux terminal
/// implementation could never be compiled or tested here — writing one would be
/// unverifiable dead code. The limitation is made explicit instead: every method is a
/// documented no-op and ``unavailabilityReason`` says why, so a host detects it at startup
/// rather than staring at a terminal that silently renders nothing.
///
/// To run the TUI on Linux, add the platform to `Package.swift` and implement this type
/// against Glibc `termios` / `ioctl(TIOCGWINSZ)`; ``VirtualTerminal`` already provides a
/// working, fully-tested `Terminal` for headless use on any platform.
public final class ProcessTerminal: Terminal, @unchecked Sendable {
    public private(set) var columns: Int
    public private(set) var rows: Int

    public init(columns: Int = 80, rows: Int = 24) {
        self.columns = columns
        self.rows = rows
    }

    public static var isTTY: Bool { false }

    public static var unavailabilityReason: TerminalUnavailabilityReason? { .unsupportedPlatform }

    /// No-op: see the type documentation.
    public func start(onInput: @escaping @Sendable (String) -> Void, onResize: @escaping @Sendable (Int, Int) -> Void) {}
    /// No-op: see the type documentation.
    public func stop() {}
    /// No-op: see the type documentation.
    public func write(_ data: String) {}
}
#endif
