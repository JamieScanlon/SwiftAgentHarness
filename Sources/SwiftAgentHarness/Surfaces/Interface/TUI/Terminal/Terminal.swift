import Foundation

/// Abstract terminal interface. The renderer never touches process stdout directly.
public protocol Terminal: Sendable {
    var columns: Int { get }
    var rows: Int { get }

    func start(onInput: @escaping @Sendable (String) -> Void, onResize: @escaping @Sendable (Int, Int) -> Void)
    func stop()
    func write(_ data: String)
    func moveBy(lines: Int)
    func hideCursor()
    func showCursor()
    func clearLine()
    func clearFromCursor()
    func clearScreen()
}

public extension Terminal {
    func moveBy(lines: Int) {
        if lines > 0 {
            write(TUIEscapes.moveDown(lines))
        } else if lines < 0 {
            write(TUIEscapes.moveUp(-lines))
        }
    }

    func hideCursor() { write(TUIEscapes.hideCursor) }
    func showCursor() { write(TUIEscapes.showCursor) }
    func clearLine() { write(TUIEscapes.clearLine) }
    func clearFromCursor() { write(TUIEscapes.clearFromCursor) }
    func clearScreen() { write(TUIEscapes.clearScreen + TUIEscapes.home) }
}
