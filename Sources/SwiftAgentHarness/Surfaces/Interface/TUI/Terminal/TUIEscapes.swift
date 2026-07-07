import Foundation

/// Shared ANSI escape sequences used by the TUI renderer.
public enum TUIEscapes: Sendable {
    public static let esc = "\u{1B}"
    public static let syncStart = "\u{1B}[?2026h"
    public static let syncEnd = "\u{1B}[?2026l"
    public static let hideCursor = "\u{1B}[?25l"
    public static let showCursor = "\u{1B}[?25h"
    public static let clearLine = "\u{1B}[2K"
    public static let clearFromCursor = "\u{1B}[J"
    public static let clearScreen = "\u{1B}[2J"
    public static let home = "\u{1B}[H"
    public static let styleReset = "\u{1B}[0m"
    public static let hyperlinkReset = "\u{1B}]8;;\u{7}"
    public static let bracketedPasteOn = "\u{1B}[?2004h"
    public static let bracketedPasteOff = "\u{1B}[?2004l"
    public static let syncOutputOn = "\u{1B}[?2026h"
    public static let syncOutputOff = "\u{1B}[?2026l"

    public static func moveTo(row: Int, column: Int) -> String {
        "\(esc)[\(row);\(column)H"
    }

    public static func moveUp(_ lines: Int) -> String {
        guard lines > 0 else { return "" }
        return "\(esc)[\(lines)A"
    }

    public static func moveDown(_ lines: Int) -> String {
        guard lines > 0 else { return "" }
        return "\(esc)[\(lines)B"
    }

    public static func moveForward(_ columns: Int) -> String {
        guard columns > 0 else { return "" }
        return "\(esc)[\(columns)C"
    }

    public static func moveBackward(_ columns: Int) -> String {
        guard columns > 0 else { return "" }
        return "\(esc)[\(columns)D"
    }

    public static func sgr(fg: Int? = nil, bold: Bool = false, dim: Bool = false, reverse: Bool = false) -> String {
        var parts: [String] = []
        if bold { parts.append("1") }
        if dim { parts.append("2") }
        if reverse { parts.append("7") }
        if let fg { parts.append("38;5;\(fg)") }
        guard !parts.isEmpty else { return "" }
        return "\(esc)[\(parts.joined(separator: ";"))m"
    }

    public static func hyperlink(_ url: String, label: String) -> String {
        "\(esc)]8;;\(url)\(esc)\\\(label)\(esc)]8;;\(esc)\\"
    }
}
