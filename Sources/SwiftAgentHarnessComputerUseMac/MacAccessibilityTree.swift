#if os(macOS)
import CoreGraphics
import Foundation
import SwiftAgentHarness

/// The attributes read for one element in a single batched call.
struct MacAXAttributes: Sendable, Hashable {
    var role: String
    var subrole: String?
    var title: String?
    var value: String?
    var description: String?
    var identifier: String?
    /// CoreGraphics global points, from `AXPosition` + `AXSize`.
    var frame: CGRect?
    var enabled: Bool
    var focused: Bool

    init(
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        description: String? = nil,
        identifier: String? = nil,
        frame: CGRect? = nil,
        enabled: Bool = true,
        focused: Bool = false
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.description = description
        self.identifier = identifier
        self.frame = frame
        self.enabled = enabled
        self.focused = focused
    }

    var label: String? {
        [title, description].compactMap { $0 }.first { !$0.isEmpty }
    }
}

/// Where a traversal reads from: the live AX API, or a fixture in tests.
protocol MacAXTreeSource {
    associatedtype Element
    func read(_ element: Element) -> MacAXAttributes?
    func children(of element: Element) -> [Element]
}

/// Bounds on one traversal. Unbounded traversal is the most common way AX automation hangs.
struct MacAXTraversalBudget: Sendable, Hashable {
    var maxDepth: Int
    var maxNodes: Int
    var maxChildren: Int
    /// Checked between calls; a messaging timeout cannot interrupt a call already in progress.
    var deadline: Duration

    static let `default` = MacAXTraversalBudget(maxDepth: 12, maxNodes: 1_000, maxChildren: 300, deadline: .milliseconds(1_500))
}

struct MacAXNode: Sendable, Hashable {
    var id: Int
    var attributes: MacAXAttributes
    var children: [MacAXNode]

    var count: Int {
        1 + children.reduce(0) { $0 + $1.count }
    }
}

struct MacAXSnapshot<Element> {
    var root: MacAXNode?
    /// Live elements by node id, for acting on refs later.
    var elements: [Int: Element]
    /// Why the tree is partial.
    var truncated: String?
}

enum MacAXTraversal {
    static func snapshot<Source: MacAXTreeSource>(
        root: Source.Element,
        source: Source,
        budget: MacAXTraversalBudget,
        clock: ContinuousClock = ContinuousClock()
    ) -> MacAXSnapshot<Source.Element> {
        let start = clock.now
        var elements: [Int: Source.Element] = [:]
        var reasons: [String] = []
        var nextID = 0

        func note(_ reason: String) {
            if !reasons.contains(reason) { reasons.append(reason) }
        }

        func visit(_ element: Source.Element, depth: Int) -> MacAXNode? {
            if clock.now - start >= budget.deadline {
                note("traversal deadline reached")
                return nil
            }
            if nextID >= budget.maxNodes {
                note("node budget of \(budget.maxNodes) reached")
                return nil
            }
            guard let attributes = source.read(element) else { return nil }
            let id = nextID
            nextID += 1
            elements[id] = element
            var node = MacAXNode(id: id, attributes: attributes, children: [])
            guard depth < budget.maxDepth else {
                if !source.children(of: element).isEmpty { note("depth limit of \(budget.maxDepth) reached") }
                return node
            }
            var children = source.children(of: element)
            if children.count > budget.maxChildren {
                note("children capped at \(budget.maxChildren) per element")
                children = Array(children.prefix(budget.maxChildren))
            }
            for child in children {
                if let built = visit(child, depth: depth + 1) {
                    node.children.append(built)
                }
            }
            return node
        }

        let rootNode = visit(root, depth: 0)
        return MacAXSnapshot(
            root: rootNode,
            elements: elements,
            truncated: reasons.isEmpty ? nil : reasons.joined(separator: "; ")
        )
    }
}

struct MacAXRendering: Sendable {
    var text: String
    var elements: [String: ElementRef]
    /// The traversal node behind each ref.
    var nodeIDByRef: [String: Int]
}

/// The compact text the model reads. Keeps elements that are actionable or carry text, flattens text-less
/// layout groups, drops zero-size nodes, and truncates long values. Frames go to the side table, not the text.
enum MacAXTreeRenderer {
    static let actionableRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXTextField",
        "AXTextArea", "AXSecureTextField", "AXSearchField", "AXSlider", "AXIncrementor", "AXLink", "AXMenuItem",
        "AXMenuBarItem", "AXTab", "AXCell", "AXRow", "AXDisclosureTriangle", "AXColorWell", "AXSwitch",
    ]
    static let layoutRoles: Set<String> = ["AXGroup", "AXScrollArea", "AXSplitGroup", "AXLayoutArea", "AXUnknown", "AXSplitter"]
    static let maxValueCharacters = 80

    static func render(_ root: MacAXNode, observationID: ObservationID, app: AppIdentity?) -> MacAXRendering {
        var lines: [String] = []
        var elements: [String: ElementRef] = [:]
        var nodeIDByRef: [String: Int] = [:]
        var counter = 0

        var header = displayRole(root.attributes.role)
        if let label = root.attributes.label { header += " \(quoted(label))" }
        if let app { header += " app=\(app.bundleID)" }
        header += " obs=\(observationID)"
        lines.append(header)

        func hasText(_ attributes: MacAXAttributes) -> Bool {
            attributes.label != nil || !(attributes.value ?? "").isEmpty
        }

        func renderChildren(of node: MacAXNode, depth: Int) -> [String] {
            node.children.flatMap { render($0, depth: depth) }
        }

        func render(_ node: MacAXNode, depth: Int) -> [String] {
            let attributes = node.attributes
            if let frame = attributes.frame, frame.width <= 0 || frame.height <= 0 { return [] }
            if layoutRoles.contains(attributes.role), !hasText(attributes) {
                return renderChildren(of: node, depth: depth)
            }
            let keep = actionableRoles.contains(attributes.role) || hasText(attributes)
            let childLines = renderChildren(of: node, depth: depth + 1)
            guard keep || !childLines.isEmpty else { return [] }
            counter += 1
            let ref = "e\(counter)"
            nodeIDByRef[ref] = node.id
            elements[ref] = ElementRef(
                id: ref,
                role: attributes.role,
                subrole: attributes.subrole,
                label: attributes.label,
                frame: attributes.frame.map(DisplayRect.init),
                app: app,
                isSecureInput: attributes.role == "AXSecureTextField" || attributes.subrole == "AXSecureTextField",
                depth: depth,
                isFocused: attributes.focused
            )
            var line = String(repeating: "  ", count: depth) + "[\(ref)] \(displayRole(attributes.role))"
            if let label = attributes.label { line += " \(quoted(label))" }
            if attributes.focused { line += " focused" }
            if !attributes.enabled { line += " disabled" }
            if let value = attributes.value, !value.isEmpty, value != attributes.label {
                line += " value=\(quoted(truncated(value)))"
            }
            return [line] + childLines
        }

        lines.append(contentsOf: renderChildren(of: root, depth: 0))
        return MacAXRendering(text: lines.joined(separator: "\n"), elements: elements, nodeIDByRef: nodeIDByRef)
    }

    static func displayRole(_ role: String) -> String {
        switch role {
        case "AXPopUpButton": return "popup"
        case "AXStaticText": return "text"
        case "AXSecureTextField": return "securefield"
        default:
            let name = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
            return name.lowercased()
        }
    }

    private static func quoted(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped.replacingOccurrences(of: "\n", with: " "))\""
    }

    private static func truncated(_ value: String) -> String {
        guard value.count > maxValueCharacters else { return value }
        let size = value.count >= 1_000
            ? String(format: "%.1fk", Double(value.count) / 1_000)
            : String(value.count)
        return String(value.prefix(40)) + "…(\(size) chars)"
    }
}

/// An element id is valid only with its observation. Before acting, the live element is re-read and compared.
enum MacAXDriftCheck {
    static let frameTolerance: CGFloat = 8

    static func drift(snapshot: MacAXAttributes, live: MacAXAttributes?) -> String? {
        guard let live else { return "the element is gone" }
        if live.role != snapshot.role { return "its role changed from \(snapshot.role) to \(live.role)" }
        if live.label != snapshot.label { return "its label changed" }
        if let before = snapshot.frame, let after = live.frame {
            let moved = abs(before.midX - after.midX) > frameTolerance || abs(before.midY - after.midY) > frameTolerance
            let resized = abs(before.width - after.width) > frameTolerance || abs(before.height - after.height) > frameTolerance
            if moved || resized { return "it moved or resized" }
        }
        return nil
    }
}
#endif
