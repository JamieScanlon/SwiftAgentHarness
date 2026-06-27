import Foundation

/// Headless terminal emulator for CI-friendly frame assertions.
/// `@unchecked Sendable`: all mutable state is guarded by `NSLock`.
public final class VirtualTerminal: Terminal, @unchecked Sendable {
    public private(set) var columns: Int
    public private(set) var rows: Int
    public private(set) var rawOutput: String = ""

    public func clearRawOutput() {
        lock.lock()
        defer { lock.unlock() }
        rawOutput = ""
    }
    public private(set) var cursorRow: Int = 0
    public private(set) var cursorColumn: Int = 0
    public private(set) var cursorHidden: Bool = false

    private var grid: [[Character]]
    private var styleGrid: [[TerminalCellStyle]]
    private var onInput: (@Sendable (String) -> Void)?
    private var onResize: (@Sendable (Int, Int) -> Void)?
    private let lock = NSLock()

    public struct TerminalCellStyle: Sendable, Equatable {
        public var bold = false
        public var dim = false
        public var reverse = false
        public var fg: Int?
    }

    public init(columns: Int = 80, rows: Int = 24) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.grid = Array(repeating: Array(repeating: " ", count: self.columns), count: self.rows)
        self.styleGrid = Array(repeating: Array(repeating: TerminalCellStyle(), count: self.columns), count: self.rows)
    }

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

    public func resize(columns: Int, rows: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        grid = Array(repeating: Array(repeating: " ", count: self.columns), count: self.rows)
        styleGrid = Array(repeating: Array(repeating: TerminalCellStyle(), count: self.columns), count: self.rows)
        cursorRow = min(cursorRow, self.rows - 1)
        cursorColumn = min(cursorColumn, self.columns - 1)
        onResize?(self.columns, self.rows)
    }

    public func simulateInput(_ data: String) {
        onInput?(data)
    }

    public func frameLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return grid.map { String($0) }
    }

    public func visibleGrid() -> [[Character]] {
        lock.lock()
        defer { lock.unlock() }
        return grid
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

    private func parse(_ data: String) {
        var index = data.startIndex
        var currentStyle = TerminalCellStyle()
        while index < data.endIndex {
            let ch = data[index]
            if ch == "\u{1B}" {
                index = parseEscape(data, from: index, style: &currentStyle)
                continue
            }
            if ch == "\n" {
                cursorRow += 1
                cursorColumn = 0
                if cursorRow >= rows { scrollUp() }
                index = data.index(after: index)
                continue
            }
            if ch == "\r" {
                cursorColumn = 0
                index = data.index(after: index)
                continue
            }
            if ch == "\t" {
                let nextTab = ((cursorColumn / 8) + 1) * 8
                cursorColumn = min(nextTab, columns - 1)
                index = data.index(after: index)
                continue
            }
            writeCharacter(ch, style: currentStyle)
            index = data.index(after: index)
        }
    }

    private func parseEscape(_ data: String, from start: String.Index, style: inout TerminalCellStyle) -> String.Index {
        var index = data.index(after: start)
        guard index < data.endIndex else { return data.endIndex }
        let lead = data[index]
        if lead == "]" {
            index = data.index(after: index)
            while index < data.endIndex {
                if data[index] == "\u{7}" { return data.index(after: index) }
                if data[index] == "\u{1B}", data.index(after: index) < data.endIndex, data[data.index(after: index)] == "\\" {
                    return data.index(index, offsetBy: 2)
                }
                index = data.index(after: index)
            }
            return data.endIndex
        }
        if lead == "_" {
            index = data.index(after: index)
            while index < data.endIndex {
                if data[index] == "\u{1B}", data.index(after: index) < data.endIndex, data[data.index(after: index)] == "\\" {
                    return data.index(index, offsetBy: 2)
                }
                index = data.index(after: index)
            }
            return data.endIndex
        }
        if lead == "[" {
            index = data.index(after: index)
            var params = ""
            while index < data.endIndex, !data[index].isLetter {
                params.append(data[index])
                index = data.index(after: index)
            }
            guard index < data.endIndex else { return data.endIndex }
            let command = data[index]
            index = data.index(after: index)
            applyCSI(params: params, command: command, style: &style)
            return index
        }
        if lead == "?" {
            index = data.index(after: index)
            while index < data.endIndex, !data[index].isLetter {
                index = data.index(after: index)
            }
            if index < data.endIndex { index = data.index(after: index) }
            return index
        }
        return data.index(after: start)
    }

    private func applyCSI(params: String, command: Character, style: inout TerminalCellStyle) {
        let parts = params.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        switch command {
        case "H", "f":
            let row = max(1, Int(parts.first ?? "1") ?? 1) - 1
            let col = max(1, Int(parts.count > 1 ? parts[1] : "1") ?? 1) - 1
            cursorRow = min(max(0, row), rows - 1)
            cursorColumn = min(max(0, col), columns - 1)
        case "A":
            cursorRow = max(0, cursorRow - (Int(parts.first ?? "1") ?? 1))
        case "B":
            cursorRow = min(rows - 1, cursorRow + (Int(parts.first ?? "1") ?? 1))
        case "C":
            cursorColumn = min(columns - 1, cursorColumn + (Int(parts.first ?? "1") ?? 1))
        case "D":
            cursorColumn = max(0, cursorColumn - (Int(parts.first ?? "1") ?? 1))
        case "K":
            clearLine(mode: Int(parts.first ?? "0") ?? 0)
        case "J":
            clearFromCursor(mode: Int(parts.first ?? "0") ?? 0)
        case "m":
            applySGR(parts, style: &style)
        default:
            break
        }
    }

    private func applySGR(_ parts: [String], style: inout TerminalCellStyle) {
        for part in parts {
            guard let code = Int(part) else { continue }
            switch code {
            case 0:
                style = TerminalCellStyle()
            case 1: style.bold = true
            case 2: style.dim = true
            case 7: style.reverse = true
            case 22: style.bold = false; style.dim = false
            case 27: style.reverse = false
            case 38 where parts.count >= 3:
                if let fg = Int(parts[2]) { style.fg = fg }
            default:
                break
            }
        }
    }

    private func writeCharacter(_ character: Character, style: TerminalCellStyle) {
        let width = ANSIWidth.characterWidth(character)
        guard cursorRow >= 0, cursorRow < rows, cursorColumn >= 0, cursorColumn < columns else { return }
        grid[cursorRow][cursorColumn] = Character(String(character))
        styleGrid[cursorRow][cursorColumn] = style
        cursorColumn += width
        if cursorColumn >= columns {
            cursorColumn = columns - 1
        }
    }

    private func clearLine(mode: Int) {
        switch mode {
        case 2:
            for col in 0..<columns {
                grid[cursorRow][col] = " "
                styleGrid[cursorRow][col] = TerminalCellStyle()
            }
            cursorColumn = 0
        case 1:
            for col in 0..<cursorColumn {
                grid[cursorRow][col] = " "
                styleGrid[cursorRow][col] = TerminalCellStyle()
            }
        default:
            for col in cursorColumn..<columns {
                grid[cursorRow][col] = " "
                styleGrid[cursorRow][col] = TerminalCellStyle()
            }
        }
    }

    private func clearFromCursor(mode: Int) {
        switch mode {
        case 2:
            for row in 0..<rows {
                for col in 0..<columns {
                    grid[row][col] = " "
                    styleGrid[row][col] = TerminalCellStyle()
                }
            }
            cursorRow = 0
            cursorColumn = 0
        case 1:
            for col in cursorColumn..<columns {
                grid[cursorRow][col] = " "
                styleGrid[cursorRow][col] = TerminalCellStyle()
            }
            for row in (cursorRow + 1)..<rows {
                for col in 0..<columns {
                    grid[row][col] = " "
                    styleGrid[row][col] = TerminalCellStyle()
                }
            }
        default:
            for col in cursorColumn..<columns {
                grid[cursorRow][col] = " "
                styleGrid[cursorRow][col] = TerminalCellStyle()
            }
        }
    }

    private func scrollUp() {
        for row in 0..<(rows - 1) {
            grid[row] = grid[row + 1]
            styleGrid[row] = styleGrid[row + 1]
        }
        grid[rows - 1] = Array(repeating: " ", count: columns)
        styleGrid[rows - 1] = Array(repeating: TerminalCellStyle(), count: columns)
        cursorRow = rows - 1
    }
}
