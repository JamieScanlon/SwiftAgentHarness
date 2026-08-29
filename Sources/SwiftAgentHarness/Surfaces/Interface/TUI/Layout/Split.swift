import Foundation

public enum SplitOrientation: Sendable {
    case horizontal
    case vertical
}

/// Resizable multi-pane split with focus traversal between panes.
public final class SplitComponent: TUIComponent, Focusable {
    public var orientation: SplitOrientation
    public var ratio: Double
    public var primary: any TUIComponent
    public var secondary: any TUIComponent
    public var isFocused: Bool = false
    public private(set) var focusedPane: Int = 0
    /// Column budget consumed by the vertical separator in a horizontal split.
    private static let separator = "│"

    public init(
        orientation: SplitOrientation = .horizontal,
        ratio: Double = 0.6,
        primary: any TUIComponent,
        secondary: any TUIComponent
    ) {
        self.orientation = orientation
        self.ratio = min(0.9, max(0.1, ratio))
        self.primary = primary
        self.secondary = secondary
    }

    public func focusPrimary() {
        focusedPane = 0
        FocusTraversal.setFocus(true, on: primary)
        FocusTraversal.setFocus(false, on: secondary)
    }

    public func focusSecondary() {
        focusedPane = 1
        FocusTraversal.setFocus(false, on: primary)
        FocusTraversal.setFocus(true, on: secondary)
    }

    public func render(width: Int) -> [String] {
        guard width > 0 else { return [] }
        switch orientation {
        case .horizontal:
            let separatorWidth = ANSIWidth.visibleWidth(of: Self.separator)
            // Below the minimum for two panes plus a separator, degrade to the primary
            // pane instead of emitting a line wider than the frame.
            guard width >= separatorWidth + 2 else {
                return TUIComponentRender.renderClamped(primary, width: width)
            }
            let usable = width - separatorWidth
            let primaryWidth = max(1, min(usable - 1, Int(Double(usable) * ratio)))
            let secondaryWidth = max(1, usable - primaryWidth)
            let primaryLines = TUIComponentRender.renderClamped(primary, width: primaryWidth)
            let secondaryLines = TUIComponentRender.renderClamped(secondary, width: secondaryWidth)
            return zipLines(
                primaryLines,
                secondaryLines,
                leftWidth: primaryWidth,
                rightWidth: secondaryWidth
            )

        case .vertical:
            // Render each child exactly once. The previous implementation rendered both
            // children an extra time purely to estimate a height, so every frame cost
            // four renders instead of two.
            let primaryLines = TUIComponentRender.renderClamped(primary, width: width)
            let secondaryLines = TUIComponentRender.renderClamped(secondary, width: width)
            let total = max(1, primaryLines.count + secondaryLines.count)
            let primaryHeight = max(1, min(primaryLines.count, Int(Double(total) * ratio)))
            var lines = Array(primaryLines.prefix(primaryHeight))
            lines.append(ANSIStyle.finishLine(String(repeating: "─", count: width)))
            lines.append(contentsOf: secondaryLines)
            return lines
        }
    }

    public func handleInput(_ data: String) {
        if data == "\u{1B}[Z" || data == "\u{09}" {
            var pane = focusedPane
            FocusTraversal.focusNext(in: 2, selectedIndex: &pane)
            if pane == 0 { focusPrimary() } else { focusSecondary() }
            return
        }
        if focusedPane == 0 {
            primary.handleInput(data)
        } else {
            secondary.handleInput(data)
        }
    }

    public func invalidate() {
        primary.invalidate()
        secondary.invalidate()
    }

    /// Lays panes out at the widths they were *rendered* at.
    ///
    /// The previous version rendered at `ratio` and then laid out at a hard-coded 50/50,
    /// so at the default 0.6 ratio every primary-pane line was re-truncated from 60% to
    /// 50% of the frame — silently chopping the last ~10% of every transcript line.
    private func zipLines(
        _ left: [String],
        _ right: [String],
        leftWidth: Int,
        rightWidth: Int
    ) -> [String] {
        let height = max(left.count, right.count)
        var lines: [String] = []
        for row in 0..<height {
            let leftLine = row < left.count ? left[row] : ""
            let rightLine = row < right.count ? right[row] : ""
            let leftPart = ANSITruncate.fit(leftLine, toWidth: leftWidth)
            let rightPart = ANSITruncate.fit(rightLine, toWidth: rightWidth)
            lines.append(ANSIStyle.finishLine(leftPart + Self.separator + rightPart))
        }
        return lines
    }
}
