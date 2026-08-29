import Foundation

/// Focusable components emit a zero-width cursor marker for hardware cursor / IME placement.
///
/// Class-constrained on purpose: focus is set *through* an existential by containers
/// (`FocusTraversal.setFocus(_:on:)`), and that only propagates to the real component
/// when the conformer is a reference type.
public protocol Focusable: TUIComponent, AnyObject {
    var isFocused: Bool { get set }
}

public extension Focusable {
    func embedCursorMarker(in line: String, visibleColumn: Int) -> String {
        guard isFocused else { return line }
        return CursorMarker.insert(into: line, atVisibleColumn: visibleColumn)
    }
}

/// Propagates focus into embedded inputs inside container components.
///
/// Without this, a container that wraps an input never forwards `focused` down, the
/// input keeps drawing a cursor marker it no longer owns, and the hardware cursor —
/// and with it the IME candidate window — sits on the wrong component.
public enum FocusTraversal {
    public static func focusNext(in count: Int, selectedIndex: inout Int) {
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + 1) % count
    }

    public static func focusPrevious(in count: Int, selectedIndex: inout Int) {
        guard count > 0 else { return }
        selectedIndex = (selectedIndex - 1 + count) % count
    }

    /// Sets focus on `component`, recursing into known container types so focus reaches
    /// the input actually embedded inside them.
    public static func setFocus(_ focused: Bool, on component: any TUIComponent) {
        if let focusable = component as? any Focusable {
            focusable.isFocused = focused
        }
        switch component {
        case let stack as StackComponent:
            if let index = stack.focusedIndex {
                // Focus exactly one child. Focusing all of them re-creates the broadcast
                // problem one layer up: several components would each draw a cursor marker.
                for (offset, child) in stack.children.enumerated() {
                    setFocus(focused && offset == index, on: child)
                }
            } else {
                for child in stack.children { setFocus(focused, on: child) }
            }
        case let box as BoxComponent:
            setFocus(focused, on: box.child)
        case let split as SplitComponent:
            setFocus(focused && split.focusedPane == 0, on: split.primary)
            setFocus(focused && split.focusedPane == 1, on: split.secondary)
        default:
            break
        }
    }

    /// The first focused ``Focusable`` in a component tree, if any.
    public static func focusedComponent(in component: any TUIComponent) -> (any Focusable)? {
        if let focusable = component as? any Focusable, focusable.isFocused {
            return focusable
        }
        switch component {
        case let stack as StackComponent:
            for child in stack.children {
                if let found = focusedComponent(in: child) { return found }
            }
        case let box as BoxComponent:
            return focusedComponent(in: box.child)
        case let split as SplitComponent:
            let pane = split.focusedPane == 0 ? split.primary : split.secondary
            return focusedComponent(in: pane)
        default:
            break
        }
        return nil
    }
}
