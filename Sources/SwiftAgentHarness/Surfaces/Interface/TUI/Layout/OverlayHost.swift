import Foundation

public enum OverlayAnchor: Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case center
    case percentage(x: Double, y: Double)
}

/// Composites modal overlays above a base frame with focus capture.
public final class OverlayHostComponent: TUIComponent, Focusable {
    public var base: any TUIComponent
    public var overlay: (any TUIComponent)?
    public var anchor: OverlayAnchor
    public var isFocused: Bool = false
    /// Fired when the overlay is dismissed (Esc, or an explicit dismiss), so the host can
    /// restore focus to whatever owned it before the modal appeared.
    public var onOverlayDismissed: (() -> Void)?

    public var hasOverlay: Bool { overlay != nil }

    public init(base: any TUIComponent, overlay: (any TUIComponent)? = nil, anchor: OverlayAnchor = .center) {
        self.base = base
        self.overlay = overlay
        self.anchor = anchor
    }

    public func show(_ component: any TUIComponent) {
        overlay = component
        FocusTraversal.setFocus(false, on: base)
        FocusTraversal.setFocus(true, on: component)
        invalidate()
    }

    public func dismissOverlay() {
        guard overlay != nil else { return }
        if let overlay { FocusTraversal.setFocus(false, on: overlay) }
        overlay = nil
        FocusTraversal.setFocus(true, on: base)
        invalidate()
        onOverlayDismissed?()
    }

    public func render(width: Int) -> [String] {
        guard width > 0 else { return [] }
        let baseLines = TUIComponentRender.renderClamped(base, width: width)
        guard let overlayComponent = overlay else { return baseLines }
        let overlayWidth = max(1, min(width, max(20, width * 3 / 4)))
        let overlayLines = TUIComponentRender.renderClamped(overlayComponent, width: overlayWidth)
        return composite(base: baseLines, overlay: overlayLines, width: width)
    }

    /// A modal captures input unconditionally.
    ///
    /// The previous fall-through delivered the same keystroke to the overlay *and* the
    /// base whenever the overlay was not `Focusable` (or was focusable but unfocused) —
    /// so a keypress meant for a dialog also typed into the composer underneath it.
    public func handleInput(_ data: String) {
        guard let overlay else {
            base.handleInput(data)
            return
        }
        if data == "\u{1B}" {
            dismissOverlay()
            return
        }
        overlay.handleInput(data)
    }

    public func invalidate() {
        base.invalidate()
        overlay?.invalidate()
    }

    private func composite(base: [String], overlay: [String], width: Int) -> [String] {
        guard !overlay.isEmpty else { return base }
        var result = base
        let overlayWidth = overlay
            .map { ANSIWidth.visibleWidth(of: CursorMarker.strip(from: $0)) }
            .max() ?? 0

        let (startRow, startCol) = anchorPosition(
            baseLineCount: max(base.count, overlay.count),
            overlayLineCount: overlay.count,
            overlayWidth: overlayWidth,
            frameWidth: width
        )

        // Grow the frame rather than dropping overlay rows that fall past the base:
        // silently truncating a dialog loses its button row, which is the only way to
        // resolve it.
        let requiredRows = startRow + overlay.count
        if result.count < requiredRows {
            result.append(
                contentsOf: Array(repeating: ANSIStyle.finishLine(""), count: requiredRows - result.count)
            )
        }

        for (offset, line) in overlay.enumerated() {
            let row = startRow + offset
            guard row >= 0, row < result.count else { continue }
            let baseLine = result[row]
            // Pad the prefix to the anchor column. `ANSITruncate.truncate` returns short
            // lines unchanged, so using it alone spliced each overlay row at that base
            // row's own width — giving a dialog a different left edge on every line.
            let prefix = ANSITruncate.fit(baseLine, toWidth: startCol, ellipsis: "")
            // Measure this row, not the widest row, or short rows pull the base suffix left.
            let lineWidth = ANSIWidth.visibleWidth(of: CursorMarker.strip(from: line))
            let suffix = suffixSlice(baseLine, fromVisibleColumn: startCol + lineWidth)
            let merged = ANSITruncate.truncate(prefix + line + suffix, toWidth: width, ellipsis: "")
            result[row] = ANSIStyle.finishLine(merged)
        }
        return result
    }

    private func anchorPosition(
        baseLineCount: Int,
        overlayLineCount: Int,
        overlayWidth: Int,
        frameWidth: Int
    ) -> (Int, Int) {
        switch anchor {
        case .topLeft: return (0, 0)
        case .topRight: return (0, max(0, frameWidth - overlayWidth))
        case .bottomLeft: return (max(0, baseLineCount - overlayLineCount), 0)
        case .bottomRight:
            return (max(0, baseLineCount - overlayLineCount), max(0, frameWidth - overlayWidth))
        case .center:
            return (
                max(0, (baseLineCount - overlayLineCount) / 2),
                max(0, (frameWidth - overlayWidth) / 2)
            )
        case .percentage(let x, let y):
            let col = max(0, min(frameWidth, Int(Double(frameWidth) * x)))
            let row = max(0, Int(Double(baseLineCount) * y))
            return (row, col)
        }
    }

    private func suffixSlice(_ line: String, fromVisibleColumn column: Int) -> String {
        let visible = ANSIWidth.visibleWidth(of: line)
        guard column < visible else { return "" }
        var result = ""
        var width = 0
        var index = line.startIndex
        while index < line.endIndex {
            let ch = line[index]
            if ch == "\u{1B}" {
                let end = ANSIWidth.skipEscape(in: line, from: index)
                if width >= column { result += String(line[index..<end]) }
                index = end
                continue
            }
            let charWidth = ANSIWidth.characterWidth(ch)
            if width >= column { result.append(ch) }
            width += charWidth
            index = line.index(after: index)
        }
        return result
    }
}
