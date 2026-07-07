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

    public init(base: any TUIComponent, overlay: (any TUIComponent)? = nil, anchor: OverlayAnchor = .center) {
        self.base = base
        self.overlay = overlay
        self.anchor = anchor
    }

    public func show(_ component: any TUIComponent) {
        overlay = component
        invalidate()
    }

    public func dismissOverlay() {
        overlay = nil
        invalidate()
    }

    public func render(width: Int) -> [String] {
        let baseLines = base.render(width: width)
        guard let overlayComponent = overlay else { return baseLines }
        let overlayLines = overlayComponent.render(width: min(width - 4, max(20, width * 3 / 4)))
        return composite(base: baseLines, overlay: overlayLines, width: width)
    }

    public func handleInput(_ data: String) {
        if let overlay {
            if data == "\u{1B}" {
                dismissOverlay()
                return
            }
            overlay.handleInput(data)
            if let focusable = overlay as? Focusable, focusable.isFocused {
                return
            }
        }
        base.handleInput(data)
    }

    public func invalidate() {
        base.invalidate()
        overlay?.invalidate()
    }

    private func composite(base: [String], overlay: [String], width: Int) -> [String] {
        guard !base.isEmpty else { return overlay }
        var result = base
        let overlayWidth = overlay.map { ANSIWidth.visibleWidth(of: $0) }.max() ?? 0
        let (startRow, startCol) = anchorPosition(
            baseLineCount: base.count,
            overlayLineCount: overlay.count,
            overlayWidth: overlayWidth,
            frameWidth: width
        )
        for (offset, line) in overlay.enumerated() {
            let row = startRow + offset
            guard row >= 0, row < result.count else { continue }
            let baseLine = result[row]
            let prefix = prefixSlice(baseLine, length: startCol)
            let suffixStart = startCol + overlayWidth
            let suffix = suffixSlice(baseLine, fromVisibleColumn: suffixStart)
            result[row] = ANSIStyle.finishLine(prefix + line + suffix)
        }
        return result
    }

    private func anchorPosition(baseLineCount: Int, overlayLineCount: Int, overlayWidth: Int, frameWidth: Int) -> (Int, Int) {
        switch anchor {
        case .topLeft: return (0, 0)
        case .topRight: return (0, max(0, frameWidth - overlayWidth))
        case .bottomLeft: return (max(0, baseLineCount - overlayLineCount), 0)
        case .bottomRight: return (max(0, baseLineCount - overlayLineCount), max(0, frameWidth - overlayWidth))
        case .center:
            return (max(0, (baseLineCount - overlayLineCount) / 2), max(0, (frameWidth - overlayWidth) / 2))
        case .percentage(let x, let y):
            let col = max(0, Int(Double(frameWidth) * x))
            let row = max(0, Int(Double(baseLineCount) * y))
            return (row, col)
        }
    }

    private func prefixSlice(_ line: String, length: Int) -> String {
        guard length > 0 else { return "" }
        return ANSITruncate.truncate(line, toWidth: length, ellipsis: "")
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
