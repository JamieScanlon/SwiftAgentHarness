import Foundation

public struct ModeOption: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var detail: String?

    public init(id: String, label: String, detail: String? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
    }
}

public final class ModeDialogComponent: TUIComponent, Focusable {
    public var title: String
    public var options: [ModeOption]
    public var selectedIndex: Int
    public var isFocused: Bool = true
    public var onSelect: ((ModeOption) -> Void)?
    public private(set) var pendingSelection: ModeOption?

    public func takeSelection() -> ModeOption? {
        defer { pendingSelection = nil }
        return pendingSelection
    }

    public static let maximumWidth = 50

    public init(title: String, options: [ModeOption], selectedIndex: Int = 0) {
        self.title = title
        self.options = options
        self.selectedIndex = selectedIndex
    }

    public func render(width: Int) -> [String] {
        guard width >= 4 else {
            return [ANSITruncate.fit(ANSIStyle.dim("mode"), toWidth: max(0, width), ellipsis: "")]
        }
        // Honour the width argument. A `max(20, …)` floor with no final clamp emitted
        // 20-column lines into a narrower frame and aborted the process.
        let boxWidth = min(width, Self.maximumWidth)

        var lines: [String] = [ANSIStyle.finishLine(DialogChrome.top(title: nil, width: boxWidth))]
        lines.append(ANSIStyle.finishLine(DialogChrome.content(" " + ANSIStyle.bold(title), width: boxWidth)))
        lines.append(ANSIStyle.finishLine(DialogChrome.divider(width: boxWidth)))

        for (index, option) in options.enumerated() {
            let marker = index == selectedIndex ? "▸" : " "
            var label = " \(marker) \(option.label)"
            if let detail = option.detail { label += ANSIStyle.dim(" — \(detail)") }
            var line = DialogChrome.content(label, width: boxWidth)
            if index == selectedIndex, isFocused {
                line = embedCursorMarker(in: line, visibleColumn: DialogChrome.contentColumnOffset + 1)
            }
            lines.append(ANSIStyle.finishLine(line))
        }

        lines.append(ANSIStyle.finishLine(DialogChrome.bottom(width: boxWidth)))
        return lines
    }

    public func handleInput(_ data: String) {
        guard !options.isEmpty else { return }
        switch data {
        case "\u{1B}[A", "\u{1B}[D", "\u{1B}[Z":
            selectedIndex = (selectedIndex - 1 + options.count) % options.count
        case "\u{1B}[B", "\u{1B}[C", "\u{09}":
            selectedIndex = (selectedIndex + 1) % options.count
        case "\r", "\n", " ":
            let option = options[selectedIndex]
            pendingSelection = option
            onSelect?(option)
        default:
            break
        }
        invalidate()
    }

    private var dirty = false
    public func invalidate() { dirty = true }
}
