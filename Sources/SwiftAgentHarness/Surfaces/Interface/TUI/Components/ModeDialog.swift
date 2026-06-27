import Foundation

public struct ModeOption: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var detail: String?

    public init(id: String, label: String, detail: String? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
    }
}

public final class ModeDialogComponent: TUIComponent, Focusable {
    public var title: String
    public var options: [ModeOption]
    public var selectedIndex: Int
    public var isFocused: Bool = true
    public var onSelect: ((ModeOption) -> Void)?

    public init(title: String, options: [ModeOption], selectedIndex: Int = 0) {
        self.title = title
        self.options = options
        self.selectedIndex = selectedIndex
    }

    public func render(width: Int) -> [String] {
        let innerWidth = max(20, min(width, 50))
        var lines: [String] = []
        lines.append(ANSIStyle.finishLine("┌\(String(repeating: "─", count: max(0, innerWidth - 2)))┐"))
        lines.append(ANSIStyle.finishLine("│ \(ANSITruncate.truncate(ANSIStyle.bold(title), toWidth: innerWidth - 4)) │"))
        lines.append(ANSIStyle.finishLine("├\(String(repeating: "─", count: max(0, innerWidth - 2)))┤"))
        for (index, option) in options.enumerated() {
            let marker = index == selectedIndex ? "▸" : " "
            var label = "\(marker) \(option.label)"
            if let detail = option.detail { label += ANSIStyle.dim(" — \(detail)") }
            lines.append(ANSIStyle.finishLine("│ \(ANSITruncate.truncate(label, toWidth: innerWidth - 4)) │"))
        }
        lines.append(ANSIStyle.finishLine("└\(String(repeating: "─", count: max(0, innerWidth - 2)))┘"))
        return lines
    }

    public func handleInput(_ data: String) {
        guard !options.isEmpty else { return }
        switch data {
        case "\u{1B}[A", "\u{1B}[D":
            selectedIndex = (selectedIndex - 1 + options.count) % options.count
        case "\u{1B}[B", "\u{1B}[C", "\u{09}":
            selectedIndex = (selectedIndex + 1) % options.count
        case "\r", "\n":
            onSelect?(options[selectedIndex])
        default:
            break
        }
        invalidate()
    }

    private var dirty = false
    public func invalidate() { dirty = true }
}
