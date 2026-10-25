#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import SwiftAgentHarness

/// Reads the live accessibility tree and performs semantic element actions.
///
/// AX calls are synchronous, blocking IPC, so this actor runs on its own serial queue rather than the Swift
/// cooperative pool, which a slow app would starve. `AXUIElement` is not `Sendable`: live elements stay inside
/// the actor, and only value snapshots and opaque refs leave it.
actor MacAccessibilityReader {
    private let queue = DispatchSerialQueue(label: "SwiftAgentHarness.computer-use.accessibility")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private struct Retained {
        var elements: [String: AXUIElement]
        var attributes: [String: MacAXAttributes]
    }

    private var retained: [ObservationID: Retained] = [:]
    private var retainedOrder: [ObservationID] = []
    private let retainedLimit: Int
    private var configured = false
    private var manualAccessibilityEnabled: Set<pid_t> = []

    init(retainedObservations: Int = 8) {
        retainedLimit = max(1, retainedObservations)
    }

    struct WindowSnapshot: Sendable {
        var rendering: MacAXRendering
        var truncated: String?
        var windowFrame: CGRect?
    }

    /// The focused window of an app, rendered for the model and retained for acting on its refs.
    func snapshotFocusedWindow(
        pid: pid_t,
        app: AppIdentity,
        observationID: ObservationID,
        budget: MacAXTraversalBudget = .default
    ) -> WindowSnapshot? {
        configureOnce()
        let appElement = AXUIElementCreateApplication(pid)
        enableManualAccessibility(appElement, pid: pid)
        guard let window = Self.copyElement(appElement, kAXFocusedWindowAttribute)
            ?? Self.copyElements(appElement, kAXWindowsAttribute).first else { return nil }
        let source = LiveAXSource()
        let snapshot = MacAXTraversal.snapshot(root: window, source: source, budget: budget)
        guard let root = snapshot.root else { return nil }
        let rendering = MacAXTreeRenderer.render(root, observationID: observationID, app: app)
        var elements: [String: AXUIElement] = [:]
        var attributes: [String: MacAXAttributes] = [:]
        let nodes = Self.flatten(root)
        for (ref, nodeID) in rendering.nodeIDByRef {
            if let element = snapshot.elements[nodeID] { elements[ref] = element }
            if let node = nodes[nodeID] { attributes[ref] = node.attributes }
        }
        retain(Retained(elements: elements, attributes: attributes), for: observationID)
        return WindowSnapshot(rendering: rendering, truncated: snapshot.truncated, windowFrame: root.attributes.frame)
    }

    enum Resolution: Sendable, Equatable {
        case resolved(frame: CGRect?)
        case refused(String)
    }

    /// Re-reads a cited element and compares it to its snapshot.
    func resolve(ref: String, observation: ObservationID) -> Resolution {
        guard let entry = retained[observation], let element = entry.elements[ref], let snapshot = entry.attributes[ref] else {
            return .refused("element \(ref) of observation \(observation) is not retained; observe again")
        }
        if let drift = MacAXDriftCheck.drift(snapshot: snapshot, live: LiveAXSource().read(element)) {
            return .refused("element \(ref) changed since observation \(observation): \(drift)")
        }
        return .resolved(frame: LiveAXSource().read(element)?.frame)
    }

    enum SemanticResult: Sendable, Equatable {
        case performed(evidence: String)
        /// The call reported an error that can mean success (a modal ran past the timeout). Observe, never retry.
        case unverifiable(evidence: String)
        case unsupported(String)
        case refused(String)
    }

    func press(ref: String, observation: ObservationID) -> SemanticResult {
        perform(ref: ref, observation: observation) { element in
            guard Self.actions(element).contains(kAXPressAction as String) else { return .unsupported("element has no press action") }
            return Self.result(AXUIElementPerformAction(element, kAXPressAction as CFString), action: "AX press")
        }
    }

    func setValue(ref: String, observation: ObservationID, value: String) -> SemanticResult {
        perform(ref: ref, observation: observation) { element in
            var settable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue else {
                return .unsupported("element's value is not settable")
            }
            let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
            guard status == .success else { return Self.result(status, action: "AX set value") }
            // Some inputs accept the write without firing input events; the read-back is the evidence.
            let readBack = Self.copyString(element, kAXValueAttribute)
            return readBack == value
                ? .performed(evidence: "value read back")
                : .unverifiable(evidence: "value did not read back as written")
        }
    }

    func focus(ref: String, observation: ObservationID) -> SemanticResult {
        perform(ref: ref, observation: observation) { element in
            Self.result(AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue), action: "AX focus")
        }
    }

    /// Walks the app's menu bar by item titles, pressing each level.
    func selectMenu(pid: pid_t, path: [String]) -> SemanticResult {
        configureOnce()
        let appElement = AXUIElementCreateApplication(pid)
        guard let menuBar = Self.copyElement(appElement, kAXMenuBarAttribute) else { return .unsupported("app has no menu bar") }
        var container = menuBar
        for (depth, title) in path.enumerated() {
            let items = Self.menuItems(in: container)
            guard let item = items.first(where: { Self.copyString($0, kAXTitleAttribute)?.caseInsensitiveCompare(title) == .orderedSame }) else {
                return .refused("no menu item \"\(title)\" at \(path.prefix(depth).joined(separator: " > "))")
            }
            let status = AXUIElementPerformAction(item, kAXPressAction as CFString)
            if depth == path.count - 1 { return Self.result(status, action: "menu \(path.joined(separator: " > "))") }
            guard status == .success || status == .cannotComplete else { return Self.result(status, action: "open menu \(title)") }
            container = item
        }
        return .refused("empty menu path")
    }

    func frame(ref: String, observation: ObservationID) -> CGRect? {
        retained[observation]?.attributes[ref]?.frame
    }

    // MARK: - Private

    private func perform(ref: String, observation: ObservationID, _ body: (AXUIElement) -> SemanticResult) -> SemanticResult {
        switch resolve(ref: ref, observation: observation) {
        case .refused(let reason): return .refused(reason)
        case .resolved:
            guard let element = retained[observation]?.elements[ref] else { return .refused("element \(ref) is not retained") }
            return body(element)
        }
    }

    private func retain(_ entry: Retained, for observation: ObservationID) {
        if retained.updateValue(entry, forKey: observation) == nil { retainedOrder.append(observation) }
        while retainedOrder.count > retainedLimit {
            retained.removeValue(forKey: retainedOrder.removeFirst())
        }
    }

    private func configureOnce() {
        guard !configured else { return }
        configured = true
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
    }

    /// Chromium and Electron build their trees lazily; this asks them to build it. `AXEnhancedUserInterface` is
    /// avoided because it changes window animation and positioning.
    private func enableManualAccessibility(_ appElement: AXUIElement, pid: pid_t) {
        guard manualAccessibilityEnabled.insert(pid).inserted else { return }
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private static func flatten(_ node: MacAXNode) -> [Int: MacAXNode] {
        var nodes = [node.id: node]
        for child in node.children { nodes.merge(flatten(child)) { first, _ in first } }
        return nodes
    }

    private static func menuItems(in container: AXUIElement) -> [AXUIElement] {
        let children = copyElements(container, kAXChildrenAttribute)
        // A menu bar item's children are its menu; a menu's children are its items.
        if children.count == 1, copyString(children[0], kAXRoleAttribute) == kAXMenuRole as String {
            return copyElements(children[0], kAXChildrenAttribute)
        }
        return children
    }

    private static func result(_ status: AXError, action: String) -> SemanticResult {
        switch status {
        case .success: return .performed(evidence: action)
        case .cannotComplete: return .unverifiable(evidence: "\(action) timed out, which can mean it succeeded")
        case .actionUnsupported, .attributeUnsupported: return .unsupported("\(action) is not supported")
        case .invalidUIElement: return .refused("the element is gone")
        default: return .unverifiable(evidence: "\(action) returned AX error \(status.rawValue)")
        }
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    static func copyElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let array = value as? [AnyObject] else { return [] }
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? unsafeDowncast(item, to: AXUIElement.self) : nil
        }
    }

    static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

/// The live AX API as a traversal source. One batched attribute read per element.
final class LiveAXSource: MacAXTreeSource {
    private static let attributeNames: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute,
        kAXIdentifierAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute, kAXFocusedAttribute,
        kAXChildrenAttribute,
    ]

    private var lastElement: AXUIElement?
    private var lastChildren: [AXUIElement] = []

    func read(_ element: AXUIElement) -> MacAXAttributes? {
        var values: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(
            element,
            Self.attributeNames as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &values
        )
        guard status == .success, let array = values as? [AnyObject], array.count == Self.attributeNames.count else { return nil }
        func string(_ index: Int) -> String? {
            if let text = array[index] as? String { return text.isEmpty ? nil : text }
            if let number = array[index] as? NSNumber, CFGetTypeID(number) != AXValueGetTypeID() { return number.stringValue }
            return nil
        }
        func bool(_ index: Int) -> Bool? { (array[index] as? NSNumber)?.boolValue }
        func axValue<T>(_ index: Int, _ type: AXValueType, _ empty: T) -> T? {
            let item = array[index]
            guard CFGetTypeID(item) == AXValueGetTypeID() else { return nil }
            var result = empty
            return AXValueGetValue(unsafeDowncast(item, to: AXValue.self), type, &result) ? result : nil
        }
        guard let role = string(0) else { return nil }
        let position = axValue(6, .cgPoint, CGPoint.zero)
        let size = axValue(7, .cgSize, CGSize.zero)
        lastElement = element
        lastChildren = (array[10] as? [AnyObject])?.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? unsafeDowncast(item, to: AXUIElement.self) : nil
        } ?? []
        return MacAXAttributes(
            role: role,
            subrole: string(1),
            title: string(2),
            value: string(3),
            description: string(4),
            identifier: string(5),
            frame: position.flatMap { origin in size.map { CGRect(origin: origin, size: $0) } },
            enabled: bool(8) ?? true,
            focused: bool(9) ?? false
        )
    }

    func children(of element: AXUIElement) -> [AXUIElement] {
        if let lastElement, CFEqual(lastElement, element) { return lastChildren }
        return MacAccessibilityReader.copyElements(element, kAXChildrenAttribute)
    }
}
#endif
