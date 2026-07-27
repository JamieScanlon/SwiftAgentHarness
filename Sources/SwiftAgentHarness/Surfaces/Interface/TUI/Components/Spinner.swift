import Foundation

public final class SpinnerComponent: TUIComponent {
    public var label: String
    public private(set) var frameIndex: Int = 0
    private let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    public init(label: String = "Working") {
        self.label = label
    }

    /// The current frame glyph, without the label.
    public var glyph: String { frames[frameIndex] }

    public func tick() {
        frameIndex = (frameIndex + 1) % frames.count
        invalidate()
    }

    private var dirty = false
    public func invalidate() { dirty = true }

    public func render(width: Int) -> [String] {
        let line = label.isEmpty ? ANSIStyle.dim(glyph) : ANSIStyle.dim("\(glyph) \(label)")
        return [ANSIStyle.finishLine(ANSITruncate.truncate(line, toWidth: width))]
    }
}
