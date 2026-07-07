import Foundation

public enum ANSIStyle: Sendable {
    public static let lineResetSuffix = TUIEscapes.styleReset + TUIEscapes.hyperlinkReset

    public static func finishLine(_ line: String) -> String {
        if line.isEmpty { return lineResetSuffix }
        if line.hasSuffix(lineResetSuffix) { return line }
        return line + lineResetSuffix
    }

    public static func styled(_ text: String, fg: Int? = nil, bold: Bool = false, dim: Bool = false, reverse: Bool = false) -> String {
        let open = TUIEscapes.sgr(fg: fg, bold: bold, dim: dim, reverse: reverse)
        if open.isEmpty { return text }
        return open + text + TUIEscapes.styleReset
    }

    public static func dim(_ text: String) -> String {
        styled(text, dim: true)
    }

    public static func bold(_ text: String) -> String {
        styled(text, bold: true)
    }

    public static func reverse(_ text: String) -> String {
        styled(text, reverse: true)
    }

    public static func color(_ text: String, fg: Int) -> String {
        styled(text, fg: fg)
    }

    public static func ensureWidthBound(_ lines: [String], width: Int, context: String) -> [String] {
        for (index, line) in lines.enumerated() {
            let visible = ANSIWidth.visibleWidth(of: CursorMarker.strip(from: line))
            if visible > width {
                preconditionFailure("Component '\(context)' line \(index) exceeds width \(width): visible=\(visible)")
            }
        }
        return lines
    }
}
