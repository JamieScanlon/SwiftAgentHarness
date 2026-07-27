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

    /// Splits `line` at the given visible column, never inside an escape sequence.
    ///
    /// Delegates escape skipping to ``ANSIWidth/skipEscape(in:from:)`` rather than
    /// running a bespoke state machine. The previous hand-rolled version treated only
    /// `m`, `\` and `BEL` as terminators, so a `CSI 2K` in the line left it stuck in
    /// escape mode for the remainder (marker pinned to end of line) and an OSC-8 URL
    /// containing the letter `m` exited escape mode early (URL characters counted as
    /// visible). Either way the hardware cursor landed in the wrong column.
    private static func splitAtVisibleColumn(_ line: String, column: Int) -> (String, String) {
        var visible = 0
        var index = line.startIndex

        while index < line.endIndex {
            let ch = line[index]
            if ch == "\u{1B}" {
                index = ANSIWidth.skipEscape(in: line, from: index)
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
