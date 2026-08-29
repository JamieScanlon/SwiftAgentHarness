import Foundation

/// Terminal rendering and decision collection for a portable ``ApprovalPresentation``.
///
/// Classification and lifecycle stay core-owned; this component's whole job is to render
/// the presentation and report the chosen action id back through ``onDecision``.
public final class ApprovalDialogComponent: TUIComponent, Focusable {
    public var presentation: ApprovalPresentation
    public var approvalID: String
    public var selectedButtonIndex: Int
    public var isFocused: Bool = true
    /// Callback form, kept for hosts that build the dialog themselves.
    public var onDecision: ((String) -> Void)?
    /// Pull form. ``TUIApp`` uses this so a decision is observable synchronously after
    /// the keystroke that produced it, rather than arriving on a detached task whose
    /// completion nothing can await.
    public private(set) var pendingDecision: String?

    public func takeDecision() -> String? {
        defer { pendingDecision = nil }
        return pendingDecision
    }

    /// Maximum dialog width; narrower frames shrink the dialog rather than overflowing.
    public static let maximumWidth = 60

    public init(presentation: ApprovalPresentation, approvalID: String, selectedButtonIndex: Int = 0) {
        self.presentation = presentation
        self.approvalID = approvalID
        self.selectedButtonIndex = selectedButtonIndex
    }

    public func render(width: Int) -> [String] {
        guard width >= 4 else {
            return [ANSITruncate.fit(ANSIStyle.dim("approval"), toWidth: max(0, width), ellipsis: "")]
        }
        let boxWidth = min(width, Self.maximumWidth)
        let innerWidth = boxWidth - 2

        var lines: [String] = [ANSIStyle.finishLine(DialogChrome.top(title: "Approval Required", width: boxWidth))]

        for block in presentation.blocks {
            switch block {
            case .text(let value):
                for wrapped in ANSIWrap.wrap(value, width: innerWidth) {
                    lines.append(ANSIStyle.finishLine(DialogChrome.content(wrapped, width: boxWidth)))
                }
            case .context(let value):
                for wrapped in ANSIWrap.wrap(ANSIStyle.dim(value), width: innerWidth) {
                    lines.append(ANSIStyle.finishLine(DialogChrome.content(wrapped, width: boxWidth)))
                }
            case .buttons:
                break
            }
        }

        let buttons = presentation.buttons
        if buttons.isEmpty {
            let fallback = presentation.textFallback(approvalID: approvalID)
            for wrapped in ANSIWrap.wrap(fallback, width: innerWidth) {
                lines.append(ANSIStyle.finishLine(DialogChrome.content(wrapped, width: boxWidth)))
            }
        } else {
            lines.append(ANSIStyle.finishLine(buttonLine(buttons: buttons, boxWidth: boxWidth)))
        }

        lines.append(ANSIStyle.finishLine(DialogChrome.bottom(width: boxWidth)))
        return lines
    }

    public func handleInput(_ data: String) {
        let buttons = presentation.buttons
        guard !buttons.isEmpty else { return }
        switch data {
        case "\u{1B}[C", "\u{1B}[B", "\u{09}":
            selectedButtonIndex = (selectedButtonIndex + 1) % buttons.count
        case "\u{1B}[D", "\u{1B}[A", "\u{1B}[Z":
            selectedButtonIndex = (selectedButtonIndex - 1 + buttons.count) % buttons.count
        case "\r", "\n", " ":
            let decision = buttons[selectedButtonIndex].id
            pendingDecision = decision
            onDecision?(decision)
        default:
            break
        }
        invalidate()
    }

    private var dirty = false
    public func invalidate() { dirty = true }

    /// Builds the button row and anchors the hardware cursor on the selected button, so
    /// the terminal cursor follows keyboard focus into the dialog instead of staying
    /// parked on the composer underneath it.
    private func buttonLine(buttons: [ApprovalButton], boxWidth: Int) -> String {
        var rendered = ""
        var cursorColumn: Int?
        for (index, button) in buttons.enumerated() {
            if index > 0 { rendered += " " }
            if index == selectedButtonIndex {
                cursorColumn = ANSIWidth.visibleWidth(of: rendered)
                rendered += ANSIStyle.reverse(" \(button.label) ")
            } else {
                rendered += " \(button.label) "
            }
        }
        var line = DialogChrome.content(rendered, width: boxWidth)
        if let cursorColumn, isFocused {
            line = embedCursorMarker(in: line, visibleColumn: DialogChrome.contentColumnOffset + cursorColumn)
        }
        return line
    }
}
