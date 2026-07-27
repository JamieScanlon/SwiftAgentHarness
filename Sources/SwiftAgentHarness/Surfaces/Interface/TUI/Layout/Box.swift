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
        guard width > 2 else { return TUIComponentRender.renderClamped(child, width: max(1, width)) }
        let innerWidth = width - 2
        let innerLines = TUIComponentRender.renderClamped(child, width: innerWidth)
        switch border {
        case .none:
            return innerLines.map { ANSIStyle.finishLine($0) }
        case .single:
            var lines: [String] = []
            lines.append(ANSIStyle.finishLine(boxLine("┌", "─", "┐", width: width, title: title)))
            for inner in innerLines {
                lines.append(ANSIStyle.finishLine("│\(ANSITruncate.fit(inner, toWidth: innerWidth))│"))
            }
            lines.append(ANSIStyle.finishLine(boxLine("└", "─", "┘", width: width)))
            return lines
        }
    }

    public func handleInput(_ data: String) { child.handleInput(data) }
    public func invalidate() { child.invalidate() }

    private func boxLine(_ left: String, _ fill: String, _ right: String, width: Int, title: String? = nil) -> String {
        let interior = max(0, width - 2)
        guard let title, !title.isEmpty else {
            return left + String(repeating: fill, count: interior) + right
        }
        // Measure the label in visible columns, not `String.count`: a CJK title counts
        // one per character and occupies two, so the border overshoots `width` and trips
        // the width invariant — which aborts the process and leaves the tty in raw mode.
        let label = ANSITruncate.truncate(" \(title) ", toWidth: interior, ellipsis: "")
        let labelWidth = ANSIWidth.visibleWidth(of: label)
        let remaining = max(0, interior - labelWidth)
        return left + label + String(repeating: fill, count: remaining) + right
    }
}
