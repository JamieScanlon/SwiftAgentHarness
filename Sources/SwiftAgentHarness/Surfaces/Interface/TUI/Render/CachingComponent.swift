import Foundation

/// Caches render output keyed on width until invalidated.
public final class CachingComponent<C: TUIComponent>: TUIComponent {
    private let wrapped: C
    private let context: String
    private var cachedWidth: Int?
    private var cachedLines: [String] = []
    private var dirty = true

    public init(_ wrapped: C, context: String) {
        self.wrapped = wrapped
        self.context = context
    }

    public var inner: C { wrapped }

    public func render(width: Int) -> [String] {
        if !dirty, cachedWidth == width, !cachedLines.isEmpty {
            return cachedLines
        }
        let lines = TUIComponentRender.render(wrapped, width: width, context: context)
        cachedWidth = width
        cachedLines = lines
        dirty = false
        return lines
    }

    public func handleInput(_ data: String) {
        wrapped.handleInput(data)
        dirty = true
    }

    public func invalidate() {
        wrapped.invalidate()
        dirty = true
        cachedLines = []
        cachedWidth = nil
    }
}
