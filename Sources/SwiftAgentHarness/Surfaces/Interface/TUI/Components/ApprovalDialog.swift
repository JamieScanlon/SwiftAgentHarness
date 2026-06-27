import Foundation

public final class ApprovalDialogComponent: TUIComponent, Focusable {
    public var presentation: ApprovalPresentation
    public var approvalID: String
    public var selectedButtonIndex: Int
    public var isFocused: Bool = true
    public var onDecision: ((String) -> Void)?

    public init(presentation: ApprovalPresentation, approvalID: String, selectedButtonIndex: Int = 0) {
        self.presentation = presentation
        self.approvalID = approvalID
        self.selectedButtonIndex = selectedButtonIndex
    }

    public func render(width: Int) -> [String] {
        let innerWidth = max(20, min(width, 60))
        var lines: [String] = []
        lines.append(ANSIStyle.finishLine(boxLine("┌", "─", "┐", width: innerWidth, title: "Approval Required")))
        for block in presentation.blocks {
            switch block {
            case .text(let value):
                lines.append(contentsOf: boxed(ANSIWrap.wrap(value, width: innerWidth - 2), innerWidth: innerWidth))
            case .context(let value):
                lines.append(contentsOf: boxed(ANSIWrap.wrap(ANSIStyle.dim(value), width: innerWidth - 2), innerWidth: innerWidth))
            case .buttons:
                break
            }
        }
        let buttons = presentation.buttons
        if !buttons.isEmpty {
            let buttonLine = buttons.enumerated().map { index, button in
                if index == selectedButtonIndex {
                    return ANSIStyle.reverse(" \(button.label) ")
                }
                return " \(button.label) "
            }.joined(separator: " ")
            lines.append(contentsOf: boxed([ANSIStyle.finishLine(buttonLine)], innerWidth: innerWidth))
        } else {
            let fallback = presentation.textFallback(approvalID: approvalID)
            lines.append(contentsOf: boxed(ANSIWrap.wrap(fallback, width: innerWidth - 2), innerWidth: innerWidth))
        }
        lines.append(ANSIStyle.finishLine(boxLine("└", "─", "┘", width: innerWidth)))
        return lines.map { ANSITruncate.truncate($0, toWidth: width) }
    }

    public func handleInput(_ data: String) {
        let buttons = presentation.buttons
        guard !buttons.isEmpty else { return }
        switch data {
        case "\u{1B}[C", "\u{09}":
            selectedButtonIndex = (selectedButtonIndex + 1) % buttons.count
        case "\u{1B}[D":
            selectedButtonIndex = (selectedButtonIndex - 1 + buttons.count) % buttons.count
        case "\r", "\n":
            onDecision?(buttons[selectedButtonIndex].id)
        default:
            break
        }
        invalidate()
    }

    private var dirty = false
    public func invalidate() { dirty = true }

    private func boxed(_ innerLines: [String], innerWidth: Int) -> [String] {
        innerLines.map { line in
            let content = ANSITruncate.truncate(line, toWidth: innerWidth - 2)
            let visible = ANSIWidth.visibleWidth(of: content)
            let padding = max(0, innerWidth - 2 - visible)
            return ANSIStyle.finishLine("│\(content)\(String(repeating: " ", count: padding))│")
        }
    }

    private func boxLine(_ left: String, _ fill: String, _ right: String, width: Int, title: String? = nil) -> String {
        if let title, !title.isEmpty {
            let label = " \(title) "
            let remaining = max(0, width - 2 - label.count)
            return left + label + String(repeating: fill, count: remaining) + right
        }
        return left + String(repeating: fill, count: max(0, width - 2)) + right
    }
}
