import Foundation

/// Headless terminal emulator for CI-friendly frame assertions.
///
/// Fidelity matters more than completeness here: this emulator is the oracle every
/// renderer and component test asserts against, so it deliberately reproduces the
/// behaviours a real TTY exhibits under the modes ``ProcessTerminal`` sets —
/// notably that `LF` does **not** imply a carriage return (`OPOST` is cleared),
/// that `ESC[J` erases to the end of the *display* rather than the line, and that
/// writing past the last column wraps instead of overwriting it.
///
/// `@unchecked Sendable`: all mutable state is guarded by `NSLock`.
public final class VirtualTerminal: Terminal, @unchecked Sendable {
    public private(set) var columns: Int
    public private(set) var rows: Int
    public private(set) var rawOutput: String = ""

    public private(set) var cursorRow: Int = 0
    /// May equal `columns`, representing the deferred-wrap state a real terminal
    /// holds after printing in the last column.
    public private(set) var cursorColumn: Int = 0
    public private(set) var cursorHidden: Bool = false
    /// Nesting depth of `CSI ?2026h` / `CSI ?2026l` synchronized-output blocks.
    /// Tests assert this returns to zero so no frame leaves an update block open.
    public private(set) var synchronizedUpdateDepth: Int = 0

    private var grid: [[Character]]
    private var styleGrid: [[TerminalCellStyle]]
    /// Marks cells occupied by the right half of a double-width character.
    private var continuationCells: [[Bool]]
    /// Lines that have scrolled off the top, oldest first.
    private var scrollback: [String] = []
    /// SGR state persists across `write` calls, exactly as a real terminal's does.
    private var currentStyle = TerminalCellStyle()
    private var onInput: (@Sendable (String) -> Void)?
    private var onResize: (@Sendable (Int, Int) -> Void)?
    private let lock = NSLock()

    public struct TerminalCellStyle: Sendable, Equatable {
        public var bold = false
        public var dim = false
        public var reverse = false
        public var fg: Int?

        public init(bold: Bool = false, dim: Bool = false, reverse: Bool = false, fg: Int? = nil) {
            self.bold = bold
            self.dim = dim
            self.reverse = reverse
            self.fg = fg
        }
    }

    public init(columns: Int = 80, rows: Int = 24) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.grid = Self.blankGrid(columns: self.columns, rows: self.rows)
        self.styleGrid = Array(
            repeating: Array(repeating: TerminalCellStyle(), count: self.columns),
            count: self.rows
        )
        self.continuationCells = Array(
            repeating: Array(repeating: false, count: self.columns),
            count: self.rows
        )
    }

    // MARK: - Terminal

    public func start(onInput: @escaping @Sendable (String) -> Void, onResize: @escaping @Sendable (Int, Int) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.onInput = onInput
        self.onResize = onResize
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        onInput = nil
        onResize = nil
    }

    public func write(_ data: String) {
        lock.lock()
        defer { lock.unlock() }
        rawOutput += data
        parse(data)
    }

    // MARK: - Test controls

    public func clearRawOutput() {
        lock.lock()
        defer { lock.unlock() }
        rawOutput = ""
    }

    public func resize(columns: Int, rows: Int) {
        lock.lock()
        let newColumns = max(1, columns)
        let newRows = max(1, rows)
        let oldGrid = grid
        let oldStyles = styleGrid
        let oldContinuations = continuationCells

        self.columns = newColumns
        self.rows = newRows
        grid = Self.blankGrid(columns: newColumns, rows: newRows)
        styleGrid = Array(repeating: Array(repeating: TerminalCellStyle(), count: newColumns), count: newRows)
        continuationCells = Array(repeating: Array(repeating: false, count: newColumns), count: newRows)

        // Real terminals preserve content across a resize (clipped, not reflowed).
        for row in 0..<min(newRows, oldGrid.count) {
            for col in 0..<min(newColumns, oldGrid[row].count) {
                grid[row][col] = oldGrid[row][col]
                styleGrid[row][col] = oldStyles[row][col]
                continuationCells[row][col] = oldContinuations[row][col]
            }
        }

        cursorRow = min(cursorRow, newRows - 1)
        cursorColumn = min(cursorColumn, newColumns)
        let handler = onResize
        lock.unlock()
        // Invoked outside the lock: a handler that writes back would otherwise
        // deadlock on this non-recursive lock.
        handler?(newColumns, newRows)
    }

    public func simulateInput(_ data: String) {
        lock.lock()
        let handler = onInput
        lock.unlock()
        handler?(data)
    }

    // MARK: - Frame inspection

    public func frameLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return (0..<rows).map { renderRow($0) }
    }

    public func frameLine(_ row: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard row >= 0, row < rows else { return "" }
        return renderRow(row)
    }

    public func visibleGrid() -> [[Character]] {
        lock.lock()
        defer { lock.unlock() }
        return grid
    }

    public func styleAt(row: Int, column: Int) -> TerminalCellStyle? {
        lock.lock()
        defer { lock.unlock() }
        guard row >= 0, row < rows, column >= 0, column < columns else { return nil }
        return styleGrid[row][column]
    }

    /// Lines that have scrolled above the viewport, oldest first. Lets tests assert
    /// positively that a first render preserved scrollback instead of clearing it.
    public func scrollbackLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return scrollback
    }

    public func trimmedFrameLines() -> [String] {
        let lines = frameLines()
        guard let firstNonEmpty = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return []
        }
        var lastNonEmpty = lines.count - 1
        while lastNonEmpty >= firstNonEmpty, lines[lastNonEmpty].trimmingCharacters(in: .whitespaces).isEmpty {
            lastNonEmpty -= 1
        }
        return Array(lines[firstNonEmpty...lastNonEmpty]).map { $0.trimmingCharacters(in: .newlines) }
    }

    // MARK: - Parsing

    private func parse(_ data: String) {
        var index = data.startIndex
        while index < data.endIndex {
            let ch = data[index]
            if ch == "\u{1B}" {
                index = parseEscape(data, from: index)
                continue
            }
            switch ch {
            case "\r\n":
                // Swift merges CR+LF into a single extended grapheme cluster, so a
                // `Character` loop never sees them separately. Without this case the
                // renderer's line separator is swallowed whole and the frame collapses
                // onto one row.
                cursorColumn = 0
                lineFeed()
            case "\n":
                // LF only. `ProcessTerminal` clears OPOST, so ONLCR is off and a
                // bare LF does NOT return the cursor to column 0.
                lineFeed()
            case "\r":
                cursorColumn = 0
            case "\t":
                let nextTab = ((cursorColumn / 8) + 1) * 8
                cursorColumn = min(nextTab, columns - 1)
            case "\u{08}":
                cursorColumn = max(0, cursorColumn - 1)
            default:
                writeCharacter(ch, style: currentStyle)
            }
            index = data.index(after: index)
        }
    }

    private func parseEscape(_ data: String, from start: String.Index) -> String.Index {
        var index = data.index(after: start)
        guard index < data.endIndex else { return data.endIndex }
        let lead = data[index]

        if lead == "]" {
            // OSC — terminated by BEL or ST.
            index = data.index(after: index)
            while index < data.endIndex {
                if data[index] == "\u{7}" { return data.index(after: index) }
                if data[index] == "\u{1B}",
                   data.index(after: index) < data.endIndex,
                   data[data.index(after: index)] == "\\" {
                    return data.index(index, offsetBy: 2)
                }
                index = data.index(after: index)
            }
            return data.endIndex
        }

        if lead == "_" || lead == "P" || lead == "^" {
            // APC / DCS / PM — terminated by ST.
            index = data.index(after: index)
            while index < data.endIndex {
                if data[index] == "\u{1B}",
                   data.index(after: index) < data.endIndex,
                   data[data.index(after: index)] == "\\" {
                    return data.index(index, offsetBy: 2)
                }
                index = data.index(after: index)
            }
            return data.endIndex
        }

        if lead == "[" {
            index = data.index(after: index)
            var params = ""
            // CSI final bytes are 0x40...0x7E; parameter/intermediate bytes precede them.
            while index < data.endIndex, !Self.isCSIFinalByte(data[index]) {
                params.append(data[index])
                index = data.index(after: index)
            }
            guard index < data.endIndex else { return data.endIndex }
            let command = data[index]
            index = data.index(after: index)
            applyCSI(params: params, command: command)
            return index
        }

        // Two-character escape (ESC M, ESC 7, charset selection, …).
        return data.index(after: index)
    }

    private static func isCSIFinalByte(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
        return (0x40...0x7E).contains(scalar.value)
    }

    private func applyCSI(params: String, command: Character) {
        if params.hasPrefix("?") {
            applyPrivateMode(String(params.dropFirst()), command: command)
            return
        }
        let parts = params.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        func param(_ index: Int, default fallback: Int = 1) -> Int {
            guard index < parts.count, let value = Int(parts[index]), value > 0 else { return fallback }
            return value
        }

        switch command {
        case "H", "f":
            cursorRow = min(max(0, param(0) - 1), rows - 1)
            cursorColumn = min(max(0, param(1) - 1), columns - 1)
        case "A":
            cursorRow = max(0, cursorRow - param(0))
        case "B":
            // CSI B cannot scroll — it clamps at the bottom margin, as on a real terminal.
            cursorRow = min(rows - 1, cursorRow + param(0))
        case "C":
            cursorColumn = min(columns - 1, cursorColumn + param(0))
        case "D":
            cursorColumn = max(0, cursorColumn - param(0))
        case "G":
            cursorColumn = min(max(0, param(0) - 1), columns - 1)
        case "K":
            eraseInLine(mode: parts.first.flatMap(Int.init) ?? 0)
        case "J":
            eraseInDisplay(mode: parts.first.flatMap(Int.init) ?? 0)
        case "m":
            applySGR(parts)
        default:
            break
        }
    }

    private func applyPrivateMode(_ params: String, command: Character) {
        let codes = params.split(separator: ";").compactMap { Int($0) }
        for code in codes {
            switch (code, command) {
            case (25, "h"): cursorHidden = false
            case (25, "l"): cursorHidden = true
            case (2026, "h"): synchronizedUpdateDepth += 1
            case (2026, "l"): synchronizedUpdateDepth = max(0, synchronizedUpdateDepth - 1)
            default: break
            }
        }
    }

    /// Parses SGR parameters positionally so extended colour selectors consume their
    /// own arguments — `CSI 1;38;5;39m` is bold plus colour 39, not colour 5.
    private func applySGR(_ parts: [String]) {
        var index = 0
        while index < parts.count {
            guard let code = Int(parts[index]) else {
                index += 1
                continue
            }
            switch code {
            case 0:
                currentStyle = TerminalCellStyle()
            case 1: currentStyle.bold = true
            case 2: currentStyle.dim = true
            case 7: currentStyle.reverse = true
            case 22:
                currentStyle.bold = false
                currentStyle.dim = false
            case 27: currentStyle.reverse = false
            case 39: currentStyle.fg = nil
            case 30...37: currentStyle.fg = code - 30
            case 90...97: currentStyle.fg = code - 90 + 8
            case 38, 48:
                let selector = index + 1 < parts.count ? Int(parts[index + 1]) : nil
                if selector == 5 {
                    if code == 38, index + 2 < parts.count, let value = Int(parts[index + 2]) {
                        currentStyle.fg = value
                    }
                    index += 2
                } else if selector == 2 {
                    index += 4
                }
            default:
                break
            }
            index += 1
        }
    }

    // MARK: - Grid mutation

    private func writeCharacter(_ character: Character, style: TerminalCellStyle) {
        let width = ANSIWidth.characterWidth(character)
        // Zero-width scalars (combining marks, joiners) occupy no cell.
        guard width > 0 else { return }

        // Deferred wrap: a real terminal parks the cursor in the last column and
        // wraps only when the next printable character arrives.
        if cursorColumn + width > columns {
            cursorColumn = 0
            lineFeed()
        }
        guard cursorRow >= 0, cursorRow < rows, cursorColumn >= 0, cursorColumn < columns else { return }

        // Repair cells orphaned by partially overwriting a double-width character:
        // otherwise a stale continuation flag makes `renderRow` skip a live cell forever.
        if continuationCells[cursorRow][cursorColumn], cursorColumn > 0 {
            blank(row: cursorRow, column: cursorColumn - 1)
        }
        let tail = cursorColumn + width
        if tail < columns, continuationCells[cursorRow][tail] {
            blank(row: cursorRow, column: tail)
        }

        grid[cursorRow][cursorColumn] = character
        styleGrid[cursorRow][cursorColumn] = style
        continuationCells[cursorRow][cursorColumn] = false

        if width == 2, cursorColumn + 1 < columns {
            grid[cursorRow][cursorColumn + 1] = " "
            styleGrid[cursorRow][cursorColumn + 1] = style
            continuationCells[cursorRow][cursorColumn + 1] = true
        }
        cursorColumn += width
    }

    private func lineFeed() {
        cursorRow += 1
        if cursorRow >= rows { scrollUp() }
    }

    private func eraseInLine(mode: Int) {
        guard cursorRow >= 0, cursorRow < rows else { return }
        let column = min(cursorColumn, columns - 1)
        switch mode {
        case 1:
            for col in 0...column { blank(row: cursorRow, column: col) }
        case 2:
            for col in 0..<columns { blank(row: cursorRow, column: col) }
            // ESC[2K does not move the cursor.
        default:
            for col in column..<columns { blank(row: cursorRow, column: col) }
        }
    }

    /// `ESC[J` (mode 0) erases from the cursor to the end of the **display**, not the
    /// end of the line. The differential renderer depends on this to drop stale rows
    /// when a frame shrinks; emulating it as an erase-to-end-of-line hides that bug.
    private func eraseInDisplay(mode: Int) {
        switch mode {
        case 1:
            for row in 0..<cursorRow {
                for col in 0..<columns { blank(row: row, column: col) }
            }
            let column = min(cursorColumn, columns - 1)
            for col in 0...column { blank(row: cursorRow, column: col) }
        case 2, 3:
            for row in 0..<rows {
                for col in 0..<columns { blank(row: row, column: col) }
            }
        default:
            let column = min(cursorColumn, columns - 1)
            for col in column..<columns { blank(row: cursorRow, column: col) }
            guard cursorRow + 1 < rows else { return }
            for row in (cursorRow + 1)..<rows {
                for col in 0..<columns { blank(row: row, column: col) }
            }
        }
    }

    private func blank(row: Int, column: Int) {
        guard row >= 0, row < rows, column >= 0, column < columns else { return }
        // Erasing half of a double-width character must erase the other half too, or the
        // orphaned flag makes `renderRow` skip a live cell for the rest of the session.
        if continuationCells[row][column], column > 0 {
            clearCell(row: row, column: column - 1)
        }
        if column + 1 < columns, continuationCells[row][column + 1] {
            clearCell(row: row, column: column + 1)
        }
        clearCell(row: row, column: column)
    }

    private func clearCell(row: Int, column: Int) {
        grid[row][column] = " "
        styleGrid[row][column] = TerminalCellStyle()
        continuationCells[row][column] = false
    }

    private func scrollUp() {
        scrollback.append(renderRow(0))
        for row in 0..<(rows - 1) {
            grid[row] = grid[row + 1]
            styleGrid[row] = styleGrid[row + 1]
            continuationCells[row] = continuationCells[row + 1]
        }
        grid[rows - 1] = Array(repeating: " ", count: columns)
        styleGrid[rows - 1] = Array(repeating: TerminalCellStyle(), count: columns)
        continuationCells[rows - 1] = Array(repeating: false, count: columns)
        cursorRow = rows - 1
    }

    private func renderRow(_ row: Int) -> String {
        guard row >= 0, row < rows else { return "" }
        var result = ""
        for col in 0..<columns where !continuationCells[row][col] {
            result.append(grid[row][col])
        }
        return result
    }

    private static func blankGrid(columns: Int, rows: Int) -> [[Character]] {
        Array(repeating: Array(repeating: Character(" "), count: columns), count: rows)
    }
}
