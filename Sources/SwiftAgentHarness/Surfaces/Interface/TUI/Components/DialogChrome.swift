import Foundation

/// Border and content helpers shared by modal dialogs.
///
/// Every line these produce occupies exactly `width` visible columns, so a dialog can
/// never overshoot the frame it is composited into — the failure mode that turned a
/// narrow terminal into a process abort.
public enum DialogChrome: Sendable {
    public static func top(title: String?, width: Int) -> String {
        border(left: "┌", right: "┐", title: title, width: width)
    }

    public static func divider(width: Int) -> String {
        border(left: "├", right: "┤", title: nil, width: width)
    }

    public static func bottom(width: Int) -> String {
        border(left: "└", right: "┘", title: nil, width: width)
    }

    /// Wraps one content line in side borders, padded or clipped to `width`.
    public static func content(_ line: String, width: Int) -> String {
        guard width >= 2 else { return ANSITruncate.fit(line, toWidth: max(0, width), ellipsis: "") }
        return "│" + ANSITruncate.fit(line, toWidth: width - 2) + "│"
    }

    /// Visible column at which content starts, relative to the dialog's left edge.
    public static let contentColumnOffset = 1

    private static func border(left: String, right: String, title: String?, width: Int) -> String {
        guard width >= 2 else { return String(repeating: "─", count: max(0, width)) }
        let interior = width - 2
        guard let title, !title.isEmpty, interior > 0 else {
            return left + String(repeating: "─", count: interior) + right
        }
        let label = ANSITruncate.truncate(" \(title) ", toWidth: interior, ellipsis: "")
        let remaining = max(0, interior - ANSIWidth.visibleWidth(of: label))
        return left + label + String(repeating: "─", count: remaining) + right
    }
}
