#if os(macOS)
import Darwin
import Foundation

/// Real stdio terminal implementation for macOS. Not used in CI tests.
/// `@unchecked Sendable`: mutable state is guarded by `NSLock`; callbacks are dispatched off-thread.
public final class ProcessTerminal: Terminal, @unchecked Sendable {
    public private(set) var columns: Int
    public private(set) var rows: Int

    private var onInput: (@Sendable (String) -> Void)?
    private var onResize: (@Sendable (Int, Int) -> Void)?
    private var originalTermios: termios?
    private var readSource: DispatchSourceRead?
    private var resizeSource: DispatchSourceSignal?
    private let lock = NSLock()
    private var started = false

    public init(columns: Int = 80, rows: Int = 24) {
        self.columns = columns
        self.rows = rows
        updateSizeFromEnvironment()
    }

    public static var isTTY: Bool {
        isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
    }

    public func start(onInput: @escaping @Sendable (String) -> Void, onResize: @escaping @Sendable (Int, Int) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        guard Self.isTTY else { return }
        self.onInput = onInput
        self.onResize = onResize
        started = true
        enableRawMode()
        write(TUIEscapes.bracketedPasteOn)
        write(TUIEscapes.syncOutputOn)
        write(TUIEscapes.hideCursor)
        installReaders()
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard started else { return }
        readSource?.cancel()
        readSource = nil
        resizeSource?.cancel()
        resizeSource = nil
        write(TUIEscapes.syncOutputOff)
        write(TUIEscapes.bracketedPasteOff)
        write(TUIEscapes.showCursor)
        restoreTerminalMode()
        started = false
        onInput = nil
        onResize = nil
    }

    public func write(_ data: String) {
        guard let bytes = data.data(using: .utf8) else { return }
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = Darwin.write(STDOUT_FILENO, base, bytes.count)
        }
    }

    private func enableRawMode() {
        var current = termios()
        tcgetattr(STDIN_FILENO, &current)
        originalTermios = current
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
        guard var original = originalTermios else { return }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        originalTermios = nil
    }

    private func installReaders() {
        let inputSource = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .global(qos: .userInteractive))
        inputSource.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 256)
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            guard count > 0 else { return }
            let data = String(decoding: buffer.prefix(count), as: UTF8.self)
            self?.onInput?(data)
        }
        inputSource.resume()
        readSource = inputSource

        signal(SIGWINCH, SIG_IGN)
        let resize = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global(qos: .utility))
        resize.setEventHandler { [weak self] in
            self?.handleResize()
        }
        resize.resume()
        resizeSource = resize
    }

    private func handleResize() {
        updateSizeFromEnvironment()
        onResize?(columns, rows)
    }

    private func updateSizeFromEnvironment() {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 {
            columns = Int(size.ws_col)
            rows = Int(size.ws_row)
        } else if let envCols = ProcessInfo.processInfo.environment["COLUMNS"].flatMap(Int.init),
                  let envRows = ProcessInfo.processInfo.environment["LINES"].flatMap(Int.init) {
            columns = envCols
            rows = envRows
        }
    }
}
#else
import Foundation

/// ProcessTerminal is only available on macOS in this package.
public final class ProcessTerminal: Terminal, @unchecked Sendable {
    public private(set) var columns: Int
    public private(set) var rows: Int

    public init(columns: Int = 80, rows: Int = 24) {
        self.columns = columns
        self.rows = rows
    }

    public static var isTTY: Bool { false }

    public func start(onInput: @escaping @Sendable (String) -> Void, onResize: @escaping @Sendable (Int, Int) -> Void) {}
    public func stop() {}
    public func write(_ data: String) {}
}
#endif
