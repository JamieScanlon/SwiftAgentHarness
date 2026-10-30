#if os(macOS)
import AppKit
import Foundation
import SwiftAgentHarness

/// What the "agent active" HUD says. Kept apart from the panel so it can be tested without a window server.
public struct MacAgentActiveHUDState: Sendable, Equatable {
    public private(set) var isVisible = false
    public private(set) var title = ""
    public private(set) var detail = ""
    /// A one-step announcement, such as a foreground escalation.
    public private(set) var notice: String?
    public var stopHint: String
    private var lifecycleID: String?

    public init(stopHint: String = "Press Esc or click Stop to stop the agent") {
        self.stopHint = stopHint
    }

    public mutating func apply(_ activity: ComputerUseSurfaceIntentPayload) {
        if activity.status == .ended {
            guard activity.lifecycleID == lifecycleID else { return }
            self = MacAgentActiveHUDState(stopHint: stopHint)
            return
        }
        lifecycleID = activity.lifecycleID
        isVisible = true
        notice = nil
        let target = activity.target ?? "this Mac"
        if activity.status == .takenOver {
            title = "You have control of \(target)"
        } else {
            title = "Agent is using \(target)"
        }
        var parts: [String] = []
        if let step = activity.step, let maxSteps = activity.maxSteps {
            parts.append("Step \(step) of \(maxSteps)" + (activity.extensionsPhrase.map { ", \($0)" } ?? ""))
        }
        if let app = activity.app { parts.append(app) }
        if let action = activity.action { parts.append(action) }
        detail = parts.joined(separator: " · ")
    }

    /// Background delivery was escalated to the foreground: the agent activated `app` and posts global input.
    public mutating func noteForegroundDelivery(app: String?) {
        guard isVisible else { return }
        notice = "Brought \(app ?? "an app") to the front to type and click"
    }
}

/// The OS-level indicator that the agent is in control of the host desktop and how to stop it, visible for the
/// whole session. It floats over every space, never takes focus, and is excluded from screen captures, so the
/// model never reads it back.
///
/// Feed it from ``ComputerUseConfiguration/activityObserver`` and the target's
/// ``MacHostDisplayTarget/Configuration/onForegroundDelivery``.
@MainActor
public final class MacAgentActiveHUD {
    public private(set) var state: MacAgentActiveHUDState
    private let onStop: (@MainActor () -> Void)?
    private var panel: NSPanel?
    private var titleLabel: NSTextField?
    private var detailLabel: NSTextField?
    private var noticeLabel: NSTextField?
    private var hintLabel: NSTextField?
    private var stopTarget: StopButtonTarget?

    /// - Parameter onStop: Bound to the Stop button, typically the conversation's computer-use stop.
    public init(state: MacAgentActiveHUDState = MacAgentActiveHUDState(), onStop: (@MainActor () -> Void)? = nil) {
        self.state = state
        self.onStop = onStop
    }

    public func apply(_ activity: ComputerUseSurfaceIntentPayload) {
        state.apply(activity)
        refresh()
    }

    public func noteForegroundDelivery(app: String?) {
        state.noteForegroundDelivery(app: app)
        refresh()
    }

    private func refresh() {
        guard state.isVisible else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? install()
        titleLabel?.stringValue = state.title
        detailLabel?.stringValue = state.detail
        detailLabel?.isHidden = state.detail.isEmpty
        noticeLabel?.stringValue = state.notice ?? ""
        noticeLabel?.isHidden = state.notice == nil
        hintLabel?.stringValue = state.stopHint
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
        Self.position(panel)
        panel.orderFrontRegardless()
    }

    private func install() -> NSPanel {
        let panel = Self.makePanel()
        let title = NSTextField(labelWithString: "")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let detail = NSTextField(labelWithString: "")
        detail.textColor = .secondaryLabelColor
        let notice = NSTextField(labelWithString: "")
        notice.textColor = .systemOrange
        let hint = NSTextField(labelWithString: "")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor

        let text = NSStackView(views: [title, detail, notice, hint])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        var views: [NSView] = [text]
        if let onStop {
            let target = StopButtonTarget(action: onStop)
            let stop = NSButton(title: "Stop", target: target, action: #selector(StopButtonTarget.stop))
            stop.bezelStyle = .rounded
            stop.hasDestructiveAction = true
            stopTarget = target
            views.append(stop)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            row.topAnchor.constraint(equalTo: background.topAnchor),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background

        self.panel = panel
        titleLabel = title
        detailLabel = detail
        noticeLabel = notice
        hintLabel = hint
        return panel
    }

    static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 72),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        // Never captured: the model must not read its own indicator off the screen.
        panel.sharingType = .none
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        return panel
    }

    private static func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12))
    }
}

@MainActor
private final class StopButtonTarget: NSObject {
    let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func stop() {
        action()
    }
}
#endif
