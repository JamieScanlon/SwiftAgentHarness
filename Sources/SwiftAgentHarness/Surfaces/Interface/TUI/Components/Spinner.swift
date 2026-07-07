import Foundation

public final class SpinnerComponent: TUIComponent {
    public var label: String
    public private(set) var frameIndex: Int = 0
    private let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    public init(label: String = "Working") {
        self.label = label
    }

    public func tick() {
        frameIndex = (frameIndex + 1) % frames.count
        invalidate()
    }

    private var dirty = false
    public func invalidate() { dirty = true }

    public func render(width: Int) -> [String] {
        let glyph = frames[frameIndex]
        let line = ANSIStyle.dim("\(glyph) \(label)")
        return [ANSIStyle.finishLine(ANSITruncate.truncate(line, toWidth: width))]
    }
}
