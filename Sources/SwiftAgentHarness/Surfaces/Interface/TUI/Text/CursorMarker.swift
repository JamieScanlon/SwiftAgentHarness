import Foundation

/// Zero-width APC cursor marker for hardware cursor / IME positioning.
public enum CursorMarker: Sendable {
    /// APC sequence ignored visually by terminals; scanned by the differential renderer.
    public static let sentinel = "\u{1B}_TUI_CURSOR\u{1B}\\"

    public static func insert(into line: String, atVisibleColumn column: Int) -> String {
        let (prefix, suffix) = splitAtVisibleColumn(line, column: column)
        return prefix + sentinel + suffix
    }

    public static func strip(from line: String) -> String {
        line.replacingOccurrences(of: sentinel, with: "")
    }

    public static func locate(in lines: [String]) -> (row: Int, column: Int)? {
        for (rowIndex, line) in lines.enumerated() {
            if let range = line.range(of: sentinel) {
                let before = String(line[..<range.lowerBound])
                let column = ANSIWidth.visibleWidth(of: before)
                return (rowIndex, column)
            }
        }
        return nil
    }

    private static func splitAtVisibleColumn(_ line: String, column: Int) -> (String, String) {
        var visible = 0
        var index = line.startIndex
        var activeEscape = false
        var escapeBuffer = ""

        while index < line.endIndex {
            let ch = line[index]
            if ch == "\u{1B}" {
                activeEscape = true
                escapeBuffer = String(ch)
                index = line.index(after: index)
                continue
            }
            if activeEscape {
                escapeBuffer.append(ch)
                if ch == "m" || ch == "\\" || ch == "\u{7}" {
                    activeEscape = false
                    escapeBuffer = ""
                }
                index = line.index(after: index)
                continue
            }
            let charWidth = ANSIWidth.characterWidth(ch)
            if visible + charWidth > column {
                return (String(line[..<index]), String(line[index...]))
            }
            visible += charWidth
            index = line.index(after: index)
        }
        return (line, "")
    }
}
