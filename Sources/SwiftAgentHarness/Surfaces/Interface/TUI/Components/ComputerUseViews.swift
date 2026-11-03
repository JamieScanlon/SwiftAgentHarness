import Foundation

/// Terminal shortcuts for the computer-use controls. All of them work while a dialog is open.
public enum ComputerUseShortcut: Sendable {
    /// Ctrl-T: take over the screen, or hand it back.
    public static let toggleTakeover = "\u{14}"
    /// Ctrl-X: stop every computer-use session in this conversation.
    public static let stop = "\u{18}"
    /// Ctrl-O: show a fresh live-view link for each session whose target serves one.
    public static let liveView = "\u{0F}"
    /// Ctrl-G: share a view-only link to each session whose target serves a live view, or stop sharing.
    public static let share = "\u{07}"
}

/// The "agent is using <target>" line, shown between the transcript and the status line while a computer-use
/// specialist runs, with clickable live-view and share links under it once they're minted. Renders nothing otherwise.
public final class ComputerUseIndicatorComponent: TUIComponent {
    /// Latest activity per specialist run, in arrival order.
    public private(set) var sessions: [ComputerUseSurfaceIntentPayload] = []
    private var liveViews: [String: DisplayLiveView] = [:]
    /// Observer links per shared run. A run stays shared after its link stops admitting viewers, since those
    /// already watching keep their view.
    private var observerLinks: [String: DisplayLiveView] = [:]
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    public var isActive: Bool { !sessions.isEmpty }
    public var isTakenOver: Bool { sessions.contains { $0.status == .takenOver } }
    /// Whether any run has been shared with observers and not stopped since.
    public var isSharing: Bool { !observerLinks.isEmpty }

    /// Runs whose target serves a live view.
    public var liveViewSessions: [String] {
        sessions.compactMap { $0.liveView == true ? $0.lifecycleID : nil }
    }

    public func apply(_ activity: ComputerUseSurfaceIntentPayload) {
        let key = Self.key(activity)
        let index = sessions.firstIndex { Self.key($0) == key }
        if activity.status == .ended {
            if let index { sessions.remove(at: index) }
            liveViews[key] = nil
            observerLinks[key] = nil
        } else if let index {
            sessions[index] = activity
        } else {
            sessions.append(activity)
        }
    }

    /// Shows `link` under its run's line, replacing any earlier one. Ignored once the run has ended, or when the
    /// link isn't a plain http(s) URL: it is written into an escape sequence.
    public func setLiveView(_ link: DisplayLiveView, for lifecycleID: String) {
        guard accepts(link, for: lifecycleID) else { return }
        liveViews[lifecycleID] = link
    }

    /// The run's link while it can still admit a viewer.
    public func liveView(for lifecycleID: String) -> DisplayLiveView? {
        liveViews[lifecycleID].flatMap { $0.expiresAt > now() ? $0 : nil }
    }

    /// Marks the run shared and shows `link` for passing on, under the same rules as ``setLiveView(_:for:)``.
    public func setObserverLink(_ link: DisplayLiveView, for lifecycleID: String) {
        guard accepts(link, for: lifecycleID) else { return }
        observerLinks[lifecycleID] = link
    }

    /// The run's observer link while it can still admit a viewer.
    public func observerLink(for lifecycleID: String) -> DisplayLiveView? {
        observerLinks[lifecycleID].flatMap { $0.expiresAt > now() ? $0 : nil }
    }

    /// Runs shared with observers.
    public var sharedSessions: [String] {
        sessions.compactMap { activity in activity.lifecycleID.flatMap { observerLinks[$0] == nil ? nil : $0 } }
    }

    public func stopSharing(_ lifecycleID: String) {
        observerLinks[lifecycleID] = nil
    }

    public func clear() {
        sessions.removeAll()
        liveViews.removeAll()
        observerLinks.removeAll()
    }

    private func accepts(_ link: DisplayLiveView, for lifecycleID: String) -> Bool {
        guard sessions.contains(where: { $0.lifecycleID == lifecycleID }),
              let scheme = URL(string: link.url)?.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return false }
        return !link.url.unicodeScalars.contains { $0.value < 0x21 || $0.value == 0x7F || !$0.isASCII }
    }

    private static func key(_ activity: ComputerUseSurfaceIntentPayload) -> String {
        activity.lifecycleID ?? activity.target ?? ""
    }

    public func render(width: Int) -> [String] {
        guard width > 0 else { return [] }
        return sessions.flatMap { activity -> [String] in
            let target = TUITextSanitizer.sanitizeSingleLine(activity.target ?? "the screen")
            let link = activity.lifecycleID.flatMap(liveView(for:))
            let shared = activity.lifecycleID.map { observerLinks[$0] != nil } ?? false
            let observerLink = activity.lifecycleID.flatMap(observerLink(for:))
            var parts: [String]
            var hints: [String]
            if activity.status == .takenOver {
                parts = ["You have control of \(target)"]
                hints = ["^T hand back", "^X stop"]
            } else if activity.status == .waitingForLiveView {
                parts = ["Open the live view to let the agent go on with \(target)"]
                hints = ["^X stop"]
            } else {
                parts = ["Computer use on \(target)"]
                if let step = activity.step, let maxSteps = activity.maxSteps {
                    parts.append("step \(step)/\(maxSteps)" + (activity.extensionsPhrase.map { ", \($0)" } ?? ""))
                }
                if let app = activity.app { parts.append(TUITextSanitizer.sanitizeSingleLine(app)) }
                if let action = activity.action { parts.append(action) }
                hints = ["^T take over", "^X stop"]
            }
            if activity.liveView == true {
                if link == nil { hints.append("^O live view") }
                if !shared { hints.append("^G share") }
            }
            let line = ANSIStyle.color("●", fg: 214) + " " + parts.joined(separator: ANSIStyle.dim(" · ")) + "  "
                + ANSIStyle.dim(hints.joined(separator: " · "))
            var lines = [ANSIStyle.finishLine(ANSITruncate.truncate(line, toWidth: width))]
            if let link {
                let deadline = link.expiresAt.formatted(date: .omitted, time: .shortened)
                // The link is its own label so it can still be copied where the terminal doesn't support hyperlinks.
                let linkLine = "  " + ANSIStyle.dim("Live view ") + TUIEscapes.hyperlink(link.url, label: link.url)
                    + ANSIStyle.dim(" · open by \(deadline)")
                lines.append(ANSIStyle.finishLine(ANSITruncate.truncate(linkLine, toWidth: width)))
            }
            if let observerLink {
                let deadline = observerLink.expiresAt.formatted(date: .omitted, time: .shortened)
                let shareLine = "  " + ANSIStyle.dim("Shared, view only ") + TUIEscapes.hyperlink(observerLink.url, label: observerLink.url)
                    + ANSIStyle.dim(" · open by \(deadline) · ^G stop sharing")
                lines.append(ANSIStyle.finishLine(ANSITruncate.truncate(shareLine, toWidth: width)))
            } else if shared {
                let shareLine = "  " + ANSIStyle.dim("Shared, view only · new viewers can't join; anyone watching still can · ^G stop sharing")
                lines.append(ANSIStyle.finishLine(ANSITruncate.truncate(shareLine, toWidth: width)))
            }
            return lines
        }
    }

    public func invalidate() {}
}

/// A computer-use question to answer in text, or a handoff to take and hand back.
///
/// Decline is Esc (or Ctrl-C); the dialog only reports the user's choice through ``takeResolution()``.
public final class ComputerUseRequestDialogComponent: TUIComponent, Focusable {
    public let request: ComputerUseSurfaceIntentPayload
    /// Whether the indicator shows a live-view link for the request's run, which a handoff then points to.
    public let showsLiveView: Bool
    public var isFocused: Bool = true
    public private(set) var answer = ""
    public var selectedButtonIndex = 0
    private var pendingResolution: ComputerUseRequestResolution?

    public static let maximumWidth = 60

    public init(request: ComputerUseSurfaceIntentPayload, showsLiveView: Bool = false) {
        self.request = request
        self.showsLiveView = showsLiveView
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
            add(ANSIStyle.dim(showsLiveView
                ? "The agent has paused. Use \(target) through the live view link, then hand back control."
                : "The agent has paused. Use \(target), then hand back control."))
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
