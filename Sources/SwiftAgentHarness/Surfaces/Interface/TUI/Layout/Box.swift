import Foundation

public enum BoxBorder: Sendable {
    case none
    case single
}

public final class BoxComponent: TUIComponent {
    public var title: String?
    public var border: BoxBorder
    public var child: any TUIComponent

    public init(title: String? = nil, border: BoxBorder = .single, child: any TUIComponent) {
        self.title = title
        self.border = border
        self.child = child
    }

    public func render(width: Int) -> [String] {
        guard width > 2 else { return child.render(width: max(1, width)) }
        let innerWidth = width - 2
        let innerLines = child.render(width: innerWidth)
        switch border {
        case .none:
            return innerLines.map { ANSIStyle.finishLine($0) }
        case .single:
            var lines: [String] = []
            let top = boxLine("┌", "─", "┐", width: width, title: title)
            lines.append(ANSIStyle.finishLine(top))
            for inner in innerLines {
                let content = ANSITruncate.truncate(inner, toWidth: innerWidth)
                lines.append(ANSIStyle.finishLine("│\(pad(content, to: innerWidth))│"))
            }
            lines.append(ANSIStyle.finishLine(boxLine("└", "─", "┘", width: width)))
            return lines
        }
    }

    public func handleInput(_ data: String) { child.handleInput(data) }
    public func invalidate() { child.invalidate() }

    private func boxLine(_ left: String, _ fill: String, _ right: String, width: Int, title: String? = nil) -> String {
        if let title, !title.isEmpty {
            let label = " \(title) "
            let remaining = max(0, width - 2 - label.count)
            return left + label + String(repeating: fill, count: remaining) + right
        }
        return left + String(repeating: fill, count: max(0, width - 2)) + right
    }

    private func pad(_ text: String, to width: Int) -> String {
        let visible = ANSIWidth.visibleWidth(of: text)
        if visible >= width { return ANSITruncate.truncate(text, toWidth: width) }
        return text + String(repeating: " ", count: width - visible)
    }
}
