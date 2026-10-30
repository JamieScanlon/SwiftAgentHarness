import Foundation

/// Terminal shortcuts for the computer-use controls. Both work while a dialog is open.
public enum ComputerUseShortcut: Sendable {
    /// Ctrl-T: take over the screen, or hand it back.
    public static let toggleTakeover = "\u{14}"
    /// Ctrl-X: stop every computer-use session in this conversation.
    public static let stop = "\u{18}"
}

/// The "agent is using <target>" line, shown between the transcript and the status line while a computer-use
/// specialist runs. Renders nothing otherwise.
public final class ComputerUseIndicatorComponent: TUIComponent {
    /// Latest activity per specialist run, in arrival order.
    public private(set) var sessions: [ComputerUseSurfaceIntentPayload] = []

    public init() {}

    public var isActive: Bool { !sessions.isEmpty }
    public var isTakenOver: Bool { sessions.contains { $0.status == .takenOver } }

    public func apply(_ activity: ComputerUseSurfaceIntentPayload) {
        let key = activity.lifecycleID ?? activity.target ?? ""
        let index = sessions.firstIndex { ($0.lifecycleID ?? $0.target ?? "") == key }
        if activity.status == .ended {
            if let index { sessions.remove(at: index) }
        } else if let index {
            sessions[index] = activity
        } else {
            sessions.append(activity)
        }
    }

    public func clear() {
        sessions.removeAll()
    }

    public func render(width: Int) -> [String] {
        guard width > 0 else { return [] }
        return sessions.map { activity in
            let target = TUITextSanitizer.sanitizeSingleLine(activity.target ?? "the screen")
            var parts: [String]
            let hints: String
            if activity.status == .takenOver {
                parts = ["You have control of \(target)"]
                hints = "^T hand back · ^X stop"
            } else {
                parts = ["Computer use on \(target)"]
                if let step = activity.step, let maxSteps = activity.maxSteps {
                    parts.append("step \(step)/\(maxSteps)" + (activity.extensionsPhrase.map { ", \($0)" } ?? ""))
                }
                if let app = activity.app { parts.append(TUITextSanitizer.sanitizeSingleLine(app)) }
                if let action = activity.action { parts.append(action) }
                hints = "^T take over · ^X stop"
            }
            let line = ANSIStyle.color("●", fg: 214) + " " + parts.joined(separator: ANSIStyle.dim(" · ")) + "  " + ANSIStyle.dim(hints)
            return ANSIStyle.finishLine(ANSITruncate.truncate(line, toWidth: width))
        }
    }

    public func invalidate() {}
}

/// A computer-use question to answer in text, or a handoff to take and hand back.
///
/// Decline is Esc (or Ctrl-C); the dialog only reports the user's choice through ``takeResolution()``.
public final class ComputerUseRequestDialogComponent: TUIComponent, Focusable {
    public let request: ComputerUseSurfaceIntentPayload
    public var isFocused: Bool = true
    public private(set) var answer = ""
    public var selectedButtonIndex = 0
    private var pendingResolution: ComputerUseRequestResolution?

    public static let maximumWidth = 60

    public init(request: ComputerUseSurfaceIntentPayload) {
        self.request = request
    }

    public var requestID: String { request.requestID ?? "" }
    private var isQuestion: Bool { request.requestKind != .handoff }

    public func takeResolution() -> ComputerUseRequestResolution? {
        defer { pendingResolution = nil }
        return pendingResolution
    }

    private static let handoffButtons = [
        ApprovalButton(id: "hand-back", label: "Hand back control", style: .primary),
        ApprovalButton(id: "decline", label: "Decline", style: .danger),
    ]

    public func render(width: Int) -> [String] {
        guard width >= 4 else {
            return [ANSITruncate.fit(ANSIStyle.dim("computer use"), toWidth: max(0, width), ellipsis: "")]
        }
        let boxWidth = min(width, Self.maximumWidth)
        let innerWidth = boxWidth - 2
        let target = TUITextSanitizer.sanitizeSingleLine(request.target ?? "the screen")
        var lines = [ANSIStyle.finishLine(DialogChrome.top(
            title: isQuestion ? "Computer use: question" : "Computer use: your turn",
            width: boxWidth
        ))]
        func add(_ text: String) {
            for wrapped in ANSIWrap.wrap(text, width: innerWidth) {
                lines.append(ANSIStyle.finishLine(DialogChrome.content(wrapped, width: boxWidth)))
            }
        }

        let prompt = TUITextSanitizer.sanitizeMultiline(request.prompt ?? "")
        if isQuestion {
            add(ANSIStyle.dim("The agent using \(target) asks:"))
            add(prompt)
            let field = "> " + answer
            var line = DialogChrome.content(ANSITruncate.truncate(field, toWidth: innerWidth), width: boxWidth)
            if isFocused {
                let column = min(ANSIWidth.visibleWidth(of: field), innerWidth - 1)
                line = embedCursorMarker(in: line, visibleColumn: DialogChrome.contentColumnOffset + column)
            }
            lines.append(ANSIStyle.finishLine(line))
            add(ANSIStyle.dim("Enter to send · Esc to decline"))
        } else {
            if let reason = request.reason { add(ANSIStyle.dim("Needs you for: \(TUITextSanitizer.sanitizeSingleLine(reason))")) }
            add(prompt)
            add(ANSIStyle.dim("The agent has paused. Use \(target), then hand back control."))
            lines.append(ANSIStyle.finishLine(buttonLine(boxWidth: boxWidth)))
        }
        lines.append(ANSIStyle.finishLine(DialogChrome.bottom(width: boxWidth)))
        return lines
    }

    public func handleInput(_ data: String) {
        if isQuestion {
            switch data {
            case "\r", "\n":
                let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { pendingResolution = .answered(trimmed) }
            case "\u{7F}", "\u{08}":
                if !answer.isEmpty { answer.removeLast() }
            default:
                // Arrow keys and other sequences carry no text.
                guard !data.hasPrefix("\u{1B}") else { return }
                answer += data.filter { character in
                    character.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
                }
            }
        } else {
            let count = Self.handoffButtons.count
            switch data {
            case "\u{1B}[C", "\u{1B}[B", "\u{09}":
                selectedButtonIndex = (selectedButtonIndex + 1) % count
            case "\u{1B}[D", "\u{1B}[A", "\u{1B}[Z":
                selectedButtonIndex = (selectedButtonIndex - 1 + count) % count
            case "\r", "\n", " ":
                pendingResolution = Self.handoffButtons[selectedButtonIndex].id == "hand-back" ? .handedBack(note: nil) : .declined
            default:
                break
            }
        }
    }

    public func invalidate() {}

    private func buttonLine(boxWidth: Int) -> String {
        var rendered = ""
        var cursorColumn: Int?
        for (index, button) in Self.handoffButtons.enumerated() {
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
