import Foundation

public enum StackDirection: Sendable {
    case vertical
    case horizontal
}

public final class StackComponent: TUIComponent {
    public var direction: StackDirection
    public var children: [any TUIComponent]
    public var spacing: Int

    public init(direction: StackDirection = .vertical, spacing: Int = 0, children: [any TUIComponent]) {
        self.direction = direction
        self.spacing = spacing
        self.children = children
    }

    public func render(width: Int) -> [String] {
        switch direction {
        case .vertical:
            var lines: [String] = []
            for (index, child) in children.enumerated() {
                lines.append(contentsOf: child.render(width: width))
                if spacing > 0, index + 1 < children.count {
                    lines.append(contentsOf: Array(repeating: ANSIStyle.finishLine(""), count: spacing))
                }
            }
            return lines
        case .horizontal:
            let count = max(1, children.count)
            let slice = max(1, width / count)
            let rowParts: [[String]] = children.map { $0.render(width: slice) }
            let height = rowParts.map(\.count).max() ?? 0
            var lines: [String] = []
            for row in 0..<height {
                var parts: [String] = []
                for col in 0..<rowParts.count {
                    let colLines = rowParts[col]
                    let text = row < colLines.count ? colLines[row] : ""
                    parts.append(ANSITruncate.truncate(text, toWidth: slice))
                }
                lines.append(ANSIStyle.finishLine(parts.joined()))
            }
            return lines
        }
    }

    public func handleInput(_ data: String) {
        for child in children { child.handleInput(data) }
    }

    public func invalidate() {
        for child in children { child.invalidate() }
    }
}
