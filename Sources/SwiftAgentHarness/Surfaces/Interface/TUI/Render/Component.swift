import Foundation

/// Minimal component contract: render one string per line, each ≤ width.
public protocol TUIComponent {
    func render(width: Int) -> [String]
    func handleInput(_ data: String)
    func invalidate()
}

public extension TUIComponent {
    func handleInput(_ data: String) {}
    func invalidate() {}
}

public enum TUIComponentError: Error, Equatable, Sendable {
    case widthViolation(component: String, line: Int, visibleWidth: Int, maxWidth: Int)
}

public enum TUIComponentRender {
    /// Renders `component` and enforces the line ≤ width invariant the renderer relies on.
    ///
    /// Single implementation, shared with ``ANSIStyle/ensureWidthBound(_:width:context:)``
    /// so container components can enforce the same bound on their children's output
    /// instead of trusting it.
    public static func render(_ component: any TUIComponent, width: Int, context: String) -> [String] {
        ANSIStyle.ensureWidthBound(component.render(width: width), width: width, context: context)
    }

    /// Renders a child inside a container, clamping any over-wide line to `width`
    /// rather than trapping.
    ///
    /// Containers own their children's geometry, so a child that overshoots is a layout
    /// bug the container can absorb — and absorbing it is strictly better than aborting
    /// a process that has the user's terminal in raw mode.
    public static func renderClamped(_ component: any TUIComponent, width: Int) -> [String] {
        guard width > 0 else { return [] }
        return component.render(width: width).map { line in
            ANSIWidth.visibleWidth(of: CursorMarker.strip(from: line)) > width
                ? ANSITruncate.truncate(line, toWidth: width)
                : line
        }
    }
}
