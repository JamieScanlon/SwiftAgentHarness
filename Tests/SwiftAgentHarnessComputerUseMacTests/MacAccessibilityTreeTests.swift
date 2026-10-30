#if os(macOS)
import CoreGraphics
import Foundation
import Testing
import SwiftAgentHarness
@testable import SwiftAgentHarnessComputerUseMac

/// A synthetic accessibility tree keyed by integer ids.
struct FakeAXSource: MacAXTreeSource {
    var attributes: [Int: MacAXAttributes]
    var children: [Int: [Int]]

    func read(_ element: Int) -> MacAXAttributes? { attributes[element] }
    func children(of element: Int) -> [Int] { children[element] ?? [] }
}

@Suite("macOS accessibility tree")
struct MacAccessibilityTreeTests {
    private func attributes(
        _ role: String,
        title: String? = nil,
        value: String? = nil,
        frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 20),
        focused: Bool = false,
        subrole: String? = nil,
        enabled: Bool = true
    ) -> MacAXAttributes {
        MacAXAttributes(role: role, subrole: subrole, title: title, value: value, frame: frame, enabled: enabled, focused: focused)
    }

    /// window → toolbar → [Bold button, Font popup], group → textarea, Save button, a zero-size button.
    private var textEdit: FakeAXSource {
        FakeAXSource(
            attributes: [
                0: attributes("AXWindow", title: "Untitled — TextEdit", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
                1: attributes("AXToolbar", frame: CGRect(x: 0, y: 0, width: 800, height: 40)),
                2: attributes("AXButton", title: "Bold"),
                3: attributes("AXPopUpButton", title: "Font", value: "Helvetica"),
                4: attributes("AXGroup", frame: CGRect(x: 0, y: 40, width: 800, height: 500)),
                5: attributes("AXTextArea", value: String(repeating: "Hello world ", count: 100), frame: CGRect(x: 0, y: 40, width: 800, height: 500), focused: true),
                6: attributes("AXButton", title: "Save"),
                7: attributes("AXButton", title: "Ghost", frame: .zero),
                8: attributes("AXTextField", title: "Password", subrole: "AXSecureTextField"),
            ],
            children: [0: [1, 4, 6, 7, 8], 1: [2, 3], 4: [5]]
        )
    }

    @Test("Traversal reads the whole tree when it fits the budget")
    func fullTraversal() {
        let result = MacAXTraversal.snapshot(root: 0, source: textEdit, budget: .default)
        #expect(result.root?.count == 9)
        #expect(result.truncated == nil)
    }

    @Test("Node, depth, and child budgets return a partial tree with the reason")
    func budgets() {
        let nodes = MacAXTraversal.snapshot(root: 0, source: textEdit, budget: MacAXTraversalBudget(maxDepth: 12, maxNodes: 3, maxChildren: 300, deadline: .seconds(5)))
        #expect(nodes.root?.count == 3)
        #expect(nodes.truncated?.contains("node budget") == true)
        let depth = MacAXTraversal.snapshot(root: 0, source: textEdit, budget: MacAXTraversalBudget(maxDepth: 1, maxNodes: 1000, maxChildren: 300, deadline: .seconds(5)))
        #expect(depth.root?.children.allSatisfy(\.children.isEmpty) == true)
        #expect(depth.truncated?.contains("depth") == true)
        let wide = MacAXTraversal.snapshot(root: 0, source: textEdit, budget: MacAXTraversalBudget(maxDepth: 12, maxNodes: 1000, maxChildren: 2, deadline: .seconds(5)))
        #expect(wide.root?.children.count == 2)
        #expect(wide.truncated?.contains("children") == true)
    }

    @Test("The deadline is checked between reads and stops the traversal")
    func deadline() {
        let result = MacAXTraversal.snapshot(root: 0, source: textEdit, budget: MacAXTraversalBudget(maxDepth: 12, maxNodes: 1000, maxChildren: 300, deadline: .zero))
        #expect(result.truncated?.contains("deadline") == true)
    }

    @Test("The compact text keeps actionable and text-bearing elements with refs; frames stay in the side table")
    func rendering() throws {
        let snapshot = MacAXTraversal.snapshot(root: 0, source: textEdit, budget: .default)
        let app = AppIdentity(bundleID: "com.apple.TextEdit")
        let rendered = MacAXTreeRenderer.render(try #require(snapshot.root), observationID: "o_1", app: app)
        let lines = rendered.text.split(separator: "\n").map(String.init)
        #expect(lines.first == "window \"Untitled — TextEdit\" app=com.apple.TextEdit obs=o_1")
        #expect(rendered.text.contains("button \"Bold\""))
        #expect(rendered.text.contains("popup \"Font\" value=\"Helvetica\""))
        #expect(rendered.text.contains("textarea focused value=\"Hello world"))
        #expect(rendered.text.contains("…(1.2k chars)"))
        #expect(!rendered.text.contains("Ghost"))
        #expect(!rendered.text.contains("group"))
        #expect(!rendered.text.contains("x:"))

        let save = try #require(rendered.elements.values.first { $0.label == "Save" })
        #expect(save.role == "AXButton")
        #expect(save.app == app)
        #expect(save.frame != nil)
        #expect(rendered.text.contains("[\(save.id)] button \"Save\""))
        let password = try #require(rendered.elements.values.first { $0.label == "Password" })
        #expect(password.isSecureInput)
        #expect(rendered.nodeIDByRef[save.id] == 6)
    }

    @Test("Elements record their depth as rendered and whether they have focus, for the state digest")
    func depthAndFocus() throws {
        let snapshot = MacAXTraversal.snapshot(root: 0, source: textEdit, budget: .default)
        let rendered = MacAXTreeRenderer.render(try #require(snapshot.root), observationID: "o_1", app: nil)
        let bold = try #require(rendered.elements.values.first { $0.label == "Bold" })
        let save = try #require(rendered.elements.values.first { $0.label == "Save" })
        let text = try #require(rendered.elements.values.first { $0.role == "AXTextArea" })
        #expect(save.depth == 0)
        #expect(bold.depth == 1)
        // The layout group without text is flattened, so the text area renders at the group's depth.
        #expect(text.depth == 0)
        #expect(text.isFocused)
        #expect(rendered.elements.values.filter(\.isFocused).count == 1)
    }

    @Test("Drift: a different role, a different label, or a moved frame refuses the element")
    func drift() {
        let snapshot = attributes("AXButton", title: "Save", frame: CGRect(x: 10, y: 10, width: 80, height: 24))
        #expect(MacAXDriftCheck.drift(snapshot: snapshot, live: snapshot) == nil)
        #expect(MacAXDriftCheck.drift(snapshot: snapshot, live: attributes("AXButton", title: "Save", frame: CGRect(x: 12, y: 11, width: 80, height: 24))) == nil)
        #expect(MacAXDriftCheck.drift(snapshot: snapshot, live: attributes("AXLink", title: "Save", frame: snapshot.frame!)) != nil)
        #expect(MacAXDriftCheck.drift(snapshot: snapshot, live: attributes("AXButton", title: "Delete", frame: snapshot.frame!)) != nil)
        #expect(MacAXDriftCheck.drift(snapshot: snapshot, live: attributes("AXButton", title: "Save", frame: CGRect(x: 300, y: 10, width: 80, height: 24))) != nil)
        #expect(MacAXDriftCheck.drift(snapshot: snapshot, live: nil) != nil)
    }
}
#endif
