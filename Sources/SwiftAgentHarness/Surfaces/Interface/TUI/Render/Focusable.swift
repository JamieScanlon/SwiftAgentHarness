import Foundation

/// Focusable components emit a zero-width cursor marker for hardware cursor / IME placement.
public protocol Focusable: TUIComponent {
    var isFocused: Bool { get set }
}

public extension Focusable {
    func embedCursorMarker(in line: String, visibleColumn: Int) -> String {
        guard isFocused else { return line }
        return CursorMarker.insert(into: line, atVisibleColumn: visibleColumn)
    }
}

/// Propagates focus into embedded inputs inside container components.
public enum FocusTraversal {
    public static func focusNext(in count: Int, selectedIndex: inout Int) {
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + 1) % count
    }

    public static func focusPrevious(in count: Int, selectedIndex: inout Int) {
        guard count > 0 else { return }
        selectedIndex = (selectedIndex - 1 + count) % count
    }
}
