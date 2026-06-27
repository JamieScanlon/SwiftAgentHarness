import Foundation

public final class ReasoningViewComponent: TUIComponent {
    public var text: String
    public var collapsed: Bool

    public init(text: String = "", collapsed: Bool = true) {
        self.text = text
        self.collapsed = collapsed
    }

    public func append(_ fragment: String) {
        text += fragment
        invalidate()
    }

    private var dirty = false
    public func invalidate() { dirty = true }

    public func render(width: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        let header = collapsed
            ? ANSIStyle.dim("▸ reasoning (\(text.count) chars)")
            : ANSIStyle.dim("▾ reasoning")
        var lines = [ANSIStyle.finishLine(ANSITruncate.truncate(header, toWidth: width))]
        if !collapsed {
            lines.append(contentsOf: ANSIWrap.wrap(ANSIStyle.dim(text), width: width))
        }
        return lines
    }

    public func handleInput(_ data: String) {
        if data == " " || data == "\r" {
            collapsed.toggle()
            invalidate()
        }
    }
}
