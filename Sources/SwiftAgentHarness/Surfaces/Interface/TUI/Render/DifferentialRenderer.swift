import Foundation

public enum RenderStrategy: Sendable, Equatable {
    case firstRender
    case fullClear
    case differential(fromLine: Int)
}

/// Hand-written differential renderer implementing the three repaint strategies from the TUI spec.
/// `@unchecked Sendable`: frame state is guarded by `NSLock`; terminal writes are serialized.
public final class DifferentialRenderer: @unchecked Sendable {
    private let terminal: any Terminal
    private var lastFrame: [String] = []
    private var lastWidth: Int = 0
    private var isFirstRender = true
    /// Frame-relative row where the terminal cursor currently sits after the last paint.
    private var cursorFrameRow = 0
    private let lock = NSLock()

    public init(terminal: any Terminal) {
        self.terminal = terminal
    }

    public var frameLineCount: Int { lastFrame.count }

    public func render(component: any TUIComponent, width: Int, context: String, changeAboveViewport: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        let newFrame = TUIComponentRender.render(component, width: width, context: context)
        let strategy = pickStrategy(newFrame: newFrame, width: width, changeAboveViewport: changeAboveViewport)
        apply(strategy: strategy, newFrame: newFrame, width: width)
        lastFrame = newFrame
        lastWidth = width
        isFirstRender = false
    }

    public func renderLines(_ lines: [String], width: Int, changeAboveViewport: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        for (index, line) in lines.enumerated() {
            let visible = ANSIWidth.visibleWidth(of: CursorMarker.strip(from: line))
            if visible > width {
                preconditionFailure("Rendered line \(index) exceeds width \(width): visible=\(visible)")
            }
        }
        let strategy = pickStrategy(newFrame: lines, width: width, changeAboveViewport: changeAboveViewport)
        apply(strategy: strategy, newFrame: lines, width: width)
        lastFrame = lines
        lastWidth = width
        isFirstRender = false
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastFrame = []
        lastWidth = 0
        isFirstRender = true
        cursorFrameRow = 0
    }

    private func pickStrategy(newFrame: [String], width: Int, changeAboveViewport: Bool) -> RenderStrategy {
        if isFirstRender { return .firstRender }
        if width != lastWidth || changeAboveViewport { return .fullClear }
        if let firstChanged = firstChangedLine(between: lastFrame, and: newFrame) {
            return .differential(fromLine: firstChanged)
        }
        return .differential(fromLine: newFrame.count)
    }

    private func firstChangedLine(between old: [String], and new: [String]) -> Int? {
        let maxLines = max(old.count, new.count)
        for index in 0..<maxLines {
            let oldLine = index < old.count ? old[index] : ""
            let newLine = index < new.count ? new[index] : ""
            if oldLine != newLine { return index }
        }
        return nil
    }

    private func apply(strategy: RenderStrategy, newFrame: [String], width: Int) {
        let displayFrame = newFrame.map { CursorMarker.strip(from: $0) }
        terminal.write(TUIEscapes.syncStart)

        switch strategy {
        case .firstRender:
            writeLines(displayFrame, startAtHome: false)
            cursorFrameRow = max(0, displayFrame.count - 1)
        case .fullClear:
            terminal.clearScreen()
            writeLines(displayFrame, startAtHome: true)
            cursorFrameRow = max(0, displayFrame.count - 1)
        case .differential(let fromLine):
            if fromLine < displayFrame.count {
                moveToFrameLine(fromLine)
                terminal.clearFromCursor()
                writeLines(Array(displayFrame[fromLine...]), startAtHome: false)
                cursorFrameRow = max(0, displayFrame.count - 1)
            }
        }

        positionHardwareCursor(in: newFrame)
        terminal.write(TUIEscapes.syncEnd)
    }

    private func writeLines(_ lines: [String], startAtHome: Bool) {
        if startAtHome {
            terminal.write(TUIEscapes.home)
        }
        for (index, line) in lines.enumerated() {
            terminal.write(line)
            if index + 1 < lines.count {
                terminal.write("\n")
            }
        }
    }

    private func moveToFrameLine(_ target: Int) {
        terminal.moveBy(lines: target - cursorFrameRow)
        terminal.write("\r")
        cursorFrameRow = target
    }

    private func positionHardwareCursor(in frame: [String]) {
        guard let location = CursorMarker.locate(in: frame) else {
            terminal.hideCursor()
            return
        }
        terminal.moveBy(lines: location.row - cursorFrameRow)
        terminal.write("\r")
        if location.column > 0 {
            terminal.write(TUIEscapes.moveForward(location.column))
        }
        cursorFrameRow = location.row
        terminal.showCursor()
    }
}
