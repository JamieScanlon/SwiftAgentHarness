import Foundation

public enum StackDirection: Sendable {
    case vertical
    case horizontal
}

public final class StackComponent: TUIComponent {
    public var direction: StackDirection
    public var children: [any TUIComponent]
    public var spacing: Int
    /// Explicit input target. When nil, input goes to the first focused child.
    public var focusedIndex: Int?

    public init(
        direction: StackDirection = .vertical,
        spacing: Int = 0,
        focusedIndex: Int? = nil,
        children: [any TUIComponent]
    ) {
        self.direction = direction
        self.spacing = spacing
        self.focusedIndex = focusedIndex
        self.children = children
    }

    public func render(width: Int) -> [String] {
        guard width > 0 else { return [] }
        switch direction {
        case .vertical:
            var lines: [String] = []
            for (index, child) in children.enumerated() {
                lines.append(contentsOf: TUIComponentRender.renderClamped(child, width: width))
                if spacing > 0, index + 1 < children.count {
                    lines.append(contentsOf: Array(repeating: ANSIStyle.finishLine(""), count: spacing))
                }
            }
            return lines
        case .horizontal:
            let count = max(1, children.count)
            let slice = max(1, width / count)
            let rowParts: [[String]] = children.map { TUIComponentRender.renderClamped($0, width: slice) }
            let height = rowParts.map(\.count).max() ?? 0
            var lines: [String] = []
            for row in 0..<height {
                var parts: [String] = []
                for col in 0..<rowParts.count {
                    let colLines = rowParts[col]
                    let text = row < colLines.count ? colLines[row] : ""
                    parts.append(ANSITruncate.fit(text, toWidth: slice, ellipsis: ""))
                }
                lines.append(ANSIStyle.finishLine(ANSITruncate.truncate(parts.joined(), toWidth: width, ellipsis: "")))
            }
            return lines
        }
    }

    /// Routes input to exactly one child.
    ///
    /// Broadcasting every keystroke to every child — the previous behaviour — means a
    /// single arrow key moves the composer caret *and* changes a dialog selection *and*
    /// scrolls the transcript.
    public func handleInput(_ data: String) {
        if let focusedIndex, focusedIndex >= 0, focusedIndex < children.count {
            children[focusedIndex].handleInput(data)
            return
        }
        for child in children {
            if let focusable = child as? any Focusable, focusable.isFocused {
                child.handleInput(data)
                return
            }
        }
    }

    public func invalidate() {
        for child in children { child.invalidate() }
    }
}
