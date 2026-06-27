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

    public func focusPrimary() { focusedPane = 0 }
    public func focusSecondary() { focusedPane = 1 }

    public func render(width: Int) -> [String] {
        switch orientation {
        case .horizontal:
            let primaryWidth = max(1, Int(Double(width) * ratio))
            let secondaryWidth = max(1, width - primaryWidth - 1)
            let primaryLines = primary.render(width: primaryWidth)
            let secondaryLines = secondary.render(width: secondaryWidth)
            return zipLines(primaryLines, secondaryLines, separator: "│", totalWidth: width)
        case .vertical:
            let primaryHeight = max(1, Int(Double(terminalRowsEstimate(width: width)) * ratio))
            let primaryLines = primary.render(width: width)
            let secondaryLines = secondary.render(width: width)
            var lines = Array(primaryLines.prefix(primaryHeight))
            lines.append(ANSIStyle.finishLine(String(repeating: "─", count: max(0, width))))
            lines.append(contentsOf: secondaryLines)
            return lines
        }
    }

    public func handleInput(_ data: String) {
        if data == "\u{1B}[Z" || data == "\u{09}" {
            FocusTraversal.focusNext(in: 2, selectedIndex: &focusedPane)
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

    private func terminalRowsEstimate(width: Int) -> Int {
        max(primary.render(width: width).count + secondary.render(width: width).count, 1)
    }

    private func zipLines(_ left: [String], _ right: [String], separator: String, totalWidth: Int) -> [String] {
        let height = max(left.count, right.count)
        let sepWidth = ANSIWidth.visibleWidth(of: separator)
        let leftWidth = max(1, (totalWidth - sepWidth) / 2)
        let rightWidth = max(1, totalWidth - leftWidth - sepWidth)
        var lines: [String] = []
        for row in 0..<height {
            let l = row < left.count ? left[row] : ""
            let r = row < right.count ? right[row] : ""
            let leftPart = pad(ANSITruncate.truncate(l, toWidth: leftWidth), to: leftWidth)
            let rightPart = pad(ANSITruncate.truncate(r, toWidth: rightWidth), to: rightWidth)
            lines.append(ANSIStyle.finishLine(leftPart + separator + rightPart))
        }
        return lines
    }

    private func pad(_ text: String, to width: Int) -> String {
        let visible = ANSIWidth.visibleWidth(of: text)
        if visible >= width { return text }
        return text + String(repeating: " ", count: width - visible)
    }
}
