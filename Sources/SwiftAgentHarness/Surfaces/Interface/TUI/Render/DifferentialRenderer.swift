import Foundation

public enum RenderStrategy: Sendable, Equatable {
    /// The frame is byte-identical to the last one; nothing is repainted.
    case noChange
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

    public var frameLineCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return lastFrame.count
    }

    public func render(component: any TUIComponent, width: Int, context: String, changeAboveViewport: Bool = false) {
        let newFrame = TUIComponentRender.render(component, width: width, context: context)
        lock.lock()
        defer { lock.unlock() }
        commit(newFrame, width: width, changeAboveViewport: changeAboveViewport)
    }

    public func renderLines(_ lines: [String], width: Int, changeAboveViewport: Bool = false) {
        let newFrame = ANSIStyle.ensureWidthBound(lines, width: width, context: "renderLines")
        lock.lock()
        defer { lock.unlock() }
        commit(newFrame, width: width, changeAboveViewport: changeAboveViewport)
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastFrame = []
        lastWidth = 0
        isFirstRender = true
        cursorFrameRow = 0
    }

    // MARK: - Strategy

    private func commit(_ newFrame: [String], width: Int, changeAboveViewport: Bool) {
        let strategy = pickStrategy(newFrame: newFrame, width: width, changeAboveViewport: changeAboveViewport)
        apply(strategy: strategy, newFrame: newFrame)
        lastFrame = newFrame
        lastWidth = width
        isFirstRender = false
    }

    private func pickStrategy(newFrame: [String], width: Int, changeAboveViewport: Bool) -> RenderStrategy {
        if isFirstRender { return .firstRender }
        if width != lastWidth || changeAboveViewport { return .fullClear }
        guard let firstChanged = firstChangedLine(between: lastFrame, and: newFrame) else {
            return .noChange
        }
        // A change above the visible viewport can't be patched incrementally: those rows
        // have scrolled out of reach of relative cursor movement. Detect it here rather
        // than trusting the caller to know — the caller can't see the frame geometry.
        let tallestFrame = max(newFrame.count, lastFrame.count)
        let viewportTop = max(0, tallestFrame - terminal.rows)
        if firstChanged < viewportTop { return .fullClear }
        return .differential(fromLine: firstChanged)
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

    private func apply(strategy: RenderStrategy, newFrame: [String]) {
        let displayFrame = newFrame.map { CursorMarker.strip(from: $0) }
        terminal.write(TUIEscapes.syncStart)

        switch strategy {
        case .noChange:
            break

        case .firstRender:
            writeLines(displayFrame, startAtHome: false)
            cursorFrameRow = max(0, displayFrame.count - 1)

        case .fullClear:
            terminal.clearScreen()
            writeLines(displayFrame, startAtHome: true)
            cursorFrameRow = max(0, displayFrame.count - 1)

        case .differential(let fromLine):
            moveToFrameLine(fromLine)
            terminal.clearFromCursor()
            if fromLine < displayFrame.count {
                writeLines(Array(displayFrame[fromLine...]), startAtHome: false)
                cursorFrameRow = max(0, displayFrame.count - 1)
            } else {
                // The frame shrank: there is nothing left to draw from `fromLine`, but the
                // stale rows below still had to be erased. The physical cursor is now at
                // the old row, so record that rather than a row the frame no longer has —
                // otherwise every later relative move is off by the difference.
                cursorFrameRow = fromLine
            }
        }

        positionHardwareCursor(in: newFrame)
        terminal.write(TUIEscapes.syncEnd)
    }

    // MARK: - Output

    private func writeLines(_ lines: [String], startAtHome: Bool) {
        if startAtHome {
            terminal.write(TUIEscapes.home)
        }
        for (index, line) in lines.enumerated() {
            terminal.write(line)
            if index + 1 < lines.count {
                // CR + LF, not a bare LF: raw mode clears OPOST (and with it ONLCR), so a
                // lone LF moves down without returning to column 0 and staircases the frame.
                terminal.write("\r\n")
            }
        }
    }

    /// Moves the cursor to a frame row before writing.
    ///
    /// Downward movement is done with newlines rather than `CSI B` because `CSI B` clamps
    /// at the bottom margin and cannot scroll — so a frame that grows while anchored to
    /// the bottom of the screen would silently overwrite its own last line.
    private func moveToFrameLine(_ target: Int) {
        let delta = target - cursorFrameRow
        if delta > 0 {
            terminal.write(String(repeating: "\r\n", count: delta))
        } else if delta < 0 {
            terminal.write(TUIEscapes.moveUp(-delta))
            terminal.write("\r")
        } else {
            terminal.write("\r")
        }
        cursorFrameRow = target
    }

    private func positionHardwareCursor(in frame: [String]) {
        guard let location = CursorMarker.locate(in: frame) else {
            terminal.hideCursor()
            return
        }
        // The target row is already painted, so relative moves are safe here and must
        // not scroll: use CSI A/B rather than newlines.
        let delta = location.row - cursorFrameRow
        if delta != 0 { terminal.moveBy(lines: delta) }
        terminal.write("\r")
        if location.column > 0 {
            terminal.write(TUIEscapes.moveForward(location.column))
        }
        cursorFrameRow = location.row
        terminal.showCursor()
    }
}
