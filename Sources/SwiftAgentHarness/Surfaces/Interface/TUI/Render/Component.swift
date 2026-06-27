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
    public static func render(_ component: any TUIComponent, width: Int, context: String) -> [String] {
        let lines = component.render(width: width)
        for (index, line) in lines.enumerated() {
            let visible = ANSIWidth.visibleWidth(of: CursorMarker.strip(from: line))
            if visible > width {
                preconditionFailure("Component '\(context)' line \(index) exceeds width \(width): visible=\(visible)")
            }
        }
        return lines
    }
}
