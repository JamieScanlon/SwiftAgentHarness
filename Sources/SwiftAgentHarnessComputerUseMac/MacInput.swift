#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import SwiftAgentHarness

/// One synthesized input event, before it is posted.
enum MacInputEvent: Equatable, Sendable {
    case mouseMove(CGPoint)
    case mouseDown(CGPoint, MouseButton, Int, CGEventFlags)
    case mouseUp(CGPoint, MouseButton, Int, CGEventFlags)
    case mouseDrag(CGPoint, MouseButton, CGEventFlags)
    case keyDown(CGKeyCode, CGEventFlags)
    case keyUp(CGKeyCode, CGEventFlags)
    case unicode(String)
    case scroll(at: CGPoint, wheelY: Int32, wheelX: Int32, unit: ScrollUnit)
    case pause(milliseconds: Int)
}

/// Turns canonical actions into event sequences. Pure, so ordering, click states, and release are testable.
enum MacInputPlanner {
    /// Settle time between moving the pointer and pressing.
    static let settleMilliseconds = 50

    static func click(at point: CGPoint, button: MouseButton, count: Int, modifiers: [KeyModifier]) -> [MacInputEvent] {
        let flags = MacKeyMapping.flags(for: modifiers)
        var events: [MacInputEvent] = [.mouseMove(point), .pause(milliseconds: settleMilliseconds)]
        for state in 1...max(1, min(count, 3)) {
            events.append(.mouseDown(point, button, state, flags))
            events.append(.mouseUp(point, button, state, flags))
        }
        return events
    }

    static func move(to point: CGPoint) -> [MacInputEvent] {
        [.mouseMove(point)]
    }

    /// Modifiers go down first and come up last, in reverse; the key repeats inside one modifier hold.
    static func key(_ combo: KeyCombo, repeatCount: Int) -> [MacInputEvent]? {
        guard let mapped = MacKeyMapping.event(for: combo) else { return nil }
        let modifiers = combo.modifiers.sorted()
        var events: [MacInputEvent] = []
        var flags: CGEventFlags = []
        for modifier in modifiers {
            flags.insert(MacKeyMapping.flags(for: [modifier]))
            events.append(.keyDown(MacKeyMapping.keyCode(for: modifier), flags))
        }
        for _ in 0..<max(1, repeatCount) {
            events.append(.keyDown(mapped.keyCode, mapped.flags))
            events.append(.keyUp(mapped.keyCode, mapped.flags))
        }
        for modifier in modifiers.reversed() {
            flags.remove(MacKeyMapping.flags(for: [modifier]))
            events.append(.keyUp(MacKeyMapping.keyCode(for: modifier), flags))
        }
        return events
    }

    static func hold(_ combo: KeyCombo, milliseconds: Int) -> [MacInputEvent]? {
        guard let plan = key(combo, repeatCount: 1), let mapped = MacKeyMapping.event(for: combo) else { return nil }
        let pressIndex = plan.firstIndex(of: .keyDown(mapped.keyCode, mapped.flags)) ?? plan.endIndex
        var events = Array(plan[..<plan.index(after: pressIndex)])
        events.append(.pause(milliseconds: max(0, milliseconds)))
        events.append(contentsOf: plan[plan.index(after: pressIndex)...])
        return events
    }

    static func type(_ text: String) -> [MacInputEvent] {
        MacTextChunker.chunks(text).map { .unicode($0) }
    }

    /// Positive `dy` scrolls content down, which CoreGraphics expresses as a negative wheel delta.
    static func scroll(at point: CGPoint, dx: Double, dy: Double, unit: ScrollUnit) -> [MacInputEvent] {
        [.scroll(at: point, wheelY: Int32((-dy).rounded()), wheelX: Int32((-dx).rounded()), unit: unit)]
    }

    static func drag(_ path: [CGPoint], modifiers: [KeyModifier]) -> [MacInputEvent] {
        guard let first = path.first, let last = path.last else { return [] }
        let flags = MacKeyMapping.flags(for: modifiers)
        var events: [MacInputEvent] = [.mouseMove(first), .pause(milliseconds: settleMilliseconds), .mouseDown(first, .left, 1, flags)]
        for point in path.dropFirst() {
            events.append(.mouseDrag(point, .left, flags))
        }
        events.append(.mouseUp(last, .left, 1, flags))
        return events
    }
}

enum MacDeliveryRung: String, Sendable, Equatable {
    /// AX action: no focus or cursor change, verifiable by read-back.
    case semantic
    /// Events posted to the target process.
    case process
    /// Global events with the app activated; interrupts the user, so it needs consent on the lease.
    case foreground
}

enum MacDeliveryPlanner {
    static func rungs(semanticAvailable: Bool, foregroundAllowed: Bool) -> [MacDeliveryRung] {
        var rungs: [MacDeliveryRung] = semanticAvailable ? [.semantic, .process] : [.process]
        if foregroundAllowed { rungs.append(.foreground) }
        return rungs
    }
}

/// Keys and buttons currently held down, so cleanup can release every one. A stuck modifier on the user's
/// machine is a support incident.
struct MacHeldInput: Equatable {
    private(set) var keys: [CGKeyCode] = []
    private(set) var buttons: [MouseButton] = []

    mutating func apply(_ event: MacInputEvent) {
        switch event {
        case .keyDown(let code, _): if !keys.contains(code) { keys.append(code) }
        case .keyUp(let code, _): keys.removeAll { $0 == code }
        case .mouseDown(_, let button, _, _): if !buttons.contains(button) { buttons.append(button) }
        case .mouseUp(_, let button, _, _): buttons.removeAll { $0 == button }
        default: break
        }
    }

    func releaseEvents(at point: CGPoint) -> [MacInputEvent] {
        buttons.reversed().map { .mouseUp(point, $0, 1, []) } + keys.reversed().map { .keyUp($0, []) }
    }
}

enum MacInputDelivery: Sendable, Equatable {
    case process(pid_t)
    case foreground
}

/// Where synthesized events go. Tests substitute a recorder so nothing reaches the user's apps.
protocol MacEventPosting: Sendable {
    func post(_ event: CGEvent, delivery: MacInputDelivery)
}

struct LiveMacEventPoster: MacEventPosting {
    func post(_ event: CGEvent, delivery: MacInputDelivery) {
        switch delivery {
        case .process(let pid): event.postToPid(pid)
        case .foreground: event.post(tap: .cghidEventTap)
        }
    }
}

/// Posts planned events with a private event source, so synthetic modifiers neither leak into nor pick up the
/// user's physical keyboard state.
actor MacInputInjector {
    typealias Delivery = MacInputDelivery

    private let source = CGEventSource(stateID: .privateState)
    private let poster: any MacEventPosting
    private var held = MacHeldInput()
    private var lastPoint: CGPoint = .zero
    private var lastDelivery: Delivery?

    init(poster: any MacEventPosting = LiveMacEventPoster()) {
        self.poster = poster
    }

    func post(_ events: [MacInputEvent], delivery: Delivery) async {
        lastDelivery = delivery
        for event in events {
            if case .pause(let milliseconds) = event {
                try? await Task.sleep(for: .milliseconds(milliseconds))
                continue
            }
            for cgEvent in makeEvents(event) {
                poster.post(cgEvent, delivery: delivery)
            }
            held.apply(event)
            switch event {
            case .mouseMove(let point), .mouseDown(let point, _, _, _), .mouseUp(let point, _, _, _), .mouseDrag(let point, _, _):
                lastPoint = point
            default:
                break
            }
        }
    }

    /// Releases anything still held, through the delivery that pressed it. Idempotent; run on every exit path.
    func releaseAll() async {
        let release = held.releaseEvents(at: lastPoint)
        guard !release.isEmpty, let lastDelivery else { return }
        await post(release, delivery: lastDelivery)
    }

    var currentPoint: CGPoint { lastPoint }

    private func makeEvents(_ event: MacInputEvent) -> [CGEvent] {
        switch event {
        case .mouseMove(let point):
            return [CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)].compactMap { $0 }
        case .mouseDown(let point, let button, let state, let flags):
            return mouse(Self.downType(button), point, button, state: state, flags: flags)
        case .mouseUp(let point, let button, let state, let flags):
            return mouse(Self.upType(button), point, button, state: state, flags: flags)
        case .mouseDrag(let point, let button, let flags):
            return mouse(Self.dragType(button), point, button, state: 1, flags: flags)
        case .keyDown(let code, let flags):
            return key(code, down: true, flags: flags)
        case .keyUp(let code, let flags):
            return key(code, down: false, flags: flags)
        case .unicode(let text):
            let units = Array(text.utf16)
            return [true, false].compactMap { down in
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { return nil }
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                return event
            }
        case .scroll(let point, let wheelY, let wheelX, let unit):
            guard let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: unit == .line ? .line : .pixel,
                wheelCount: 2,
                wheel1: wheelY,
                wheel2: wheelX,
                wheel3: 0
            ) else { return [] }
            event.location = point
            return [event]
        case .pause:
            return []
        }
    }

    private func mouse(_ type: CGEventType, _ point: CGPoint, _ button: MouseButton, state: Int, flags: CGEventFlags) -> [CGEvent] {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: Self.cgButton(button)) else {
            return []
        }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(state))
        event.flags = flags
        return [event]
    }

    private func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) -> [CGEvent] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return [] }
        event.flags = flags
        return [event]
    }

    private static func cgButton(_ button: MouseButton) -> CGMouseButton {
        switch button {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }

    private static func downType(_ button: MouseButton) -> CGEventType {
        switch button {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .middle: return .otherMouseDown
        }
    }

    private static func upType(_ button: MouseButton) -> CGEventType {
        switch button {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }

    private static func dragType(_ button: MouseButton) -> CGEventType {
        switch button {
        case .left: return .leftMouseDragged
        case .right: return .rightMouseDragged
        case .middle: return .otherMouseDragged
        }
    }
}

/// A running app as the harness identifies it.
struct MacRunningApp: Sendable, Equatable {
    var pid: pid_t
    var identity: AppIdentity
    var launchDate: Date?
}

/// Launching, revealing, and identifying apps without stealing focus.
@MainActor
enum MacAppControl {
    static func runningApp(pid: pid_t) -> MacRunningApp? {
        NSRunningApplication(processIdentifier: pid).flatMap(describe)
    }

    static func frontmostApp() -> MacRunningApp? {
        NSWorkspace.shared.frontmostApplication.flatMap(describe)
    }

    static func runningApps(bundleIDs: Set<String>) -> [MacRunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier.map(bundleIDs.contains) ?? false }
            .compactMap(describe)
    }

    static func launch(bundleID: String, background: Bool) async throws -> MacRunningApp? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw MacAppControlError.appNotInstalled(bundleID)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = !background
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return describe(app)
    }

    static func open(_ url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.open(url, configuration: configuration)
    }

    @discardableResult
    static func activate(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.activate() ?? false
    }

    static func describe(_ app: NSRunningApplication) -> MacRunningApp? {
        guard let bundleID = app.bundleIdentifier else { return nil }
        let category = app.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String }
        return MacRunningApp(
            pid: app.processIdentifier,
            identity: AppIdentity(bundleID: bundleID, category: category),
            launchDate: app.launchDate
        )
    }
}

enum MacAppControlError: Error, Sendable, Equatable {
    case appNotInstalled(String)
}
#endif
