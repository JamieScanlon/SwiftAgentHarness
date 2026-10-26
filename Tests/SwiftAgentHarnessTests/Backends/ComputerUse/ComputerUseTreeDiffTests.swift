import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use stable refs and tree diffs")
struct ComputerUseTreeDiffTests {
    private static let app = ComputerUseFixtures.textEdit

    /// A tree the way a driver numbers it: pre-order, so an insertion renumbers everything after it.
    private static func tree(_ rows: [(role: String, label: String?, x: Double, value: String?)], observation: ObservationID) -> ObservationTree {
        var lines = ["window app=\(app.bundleID) obs=\(observation)"]
        var elements: [String: ElementRef] = [:]
        for (index, row) in rows.enumerated() {
            let ref = "e\(index + 1)"
            var line = "[\(ref)] \(row.role)"
            if let label = row.label { line += " \"\(label)\"" }
            if let value = row.value { line += " value=\"\(value)\"" }
            lines.append(line)
            elements[ref] = ElementRef(id: ref, role: row.role, label: row.label, frame: DisplayRect(x: row.x, y: 10, width: 40, height: 20), app: app)
        }
        return ObservationTree(text: lines.joined(separator: "\n"), elements: elements, capturedAt: ComputerUseFixtures.epoch)
    }

    private static func observation(_ id: ObservationID, _ rows: [(role: String, label: String?, x: Double, value: String?)]) -> DisplayObservation {
        var observation = ComputerUseFixtures.observation(id: id, withImage: false)
        observation.tree = tree(rows, observation: id)
        return observation
    }

    private static let first: [(role: String, label: String?, x: Double, value: String?)] = [
        ("button", "Bold", 10, nil), ("textarea", nil, 100, "Hello"), ("button", "Save", 300, nil),
    ]

    @Test("The first observation keeps the driver's refs")
    func firstUnchanged() {
        var stabilizer = ComputerUseRefStabilizer()
        let stable = stabilizer.stabilize(Self.observation("o_1", Self.first))
        #expect(stable.tree?.text == Self.observation("o_1", Self.first).tree?.text)
        #expect(stabilizer.driverRef("e2", observation: "o_1") == "e2")
    }

    @Test("An insertion keeps every existing element's ref; the new element gets a fresh one")
    func insertion() throws {
        var stabilizer = ComputerUseRefStabilizer()
        _ = stabilizer.stabilize(Self.observation("o_1", Self.first))
        let inserted = [("button", "Italic", 50, nil)] + Self.first.map { $0 }
        let stable = stabilizer.stabilize(Self.observation("o_2", [Self.first[0], inserted[0], Self.first[1], Self.first[2]]))
        let tree = try #require(stable.tree)
        #expect(tree.elements["e1"]?.label == "Bold")
        #expect(tree.elements["e3"]?.label == "Save")
        #expect(tree.elements["e2"]?.role == "textarea")
        #expect(tree.elements["e4"]?.label == "Italic")
        #expect(tree.text.contains("[e4] button \"Italic\""))
        #expect(tree.text.contains("[e3] button \"Save\""))
        // The driver numbered Save e4 and Italic e2 in this observation.
        #expect(stabilizer.driverRef("e3", observation: "o_2") == "e4")
        #expect(stabilizer.driverRef("e4", observation: "o_2") == "e2")
        #expect(stabilizer.driverRef("e3", observation: "o_1") == "e3")
    }

    @Test("A removed element's ref is never reused for a different one")
    func removedNotReused() throws {
        var stabilizer = ComputerUseRefStabilizer()
        _ = stabilizer.stabilize(Self.observation("o_1", Self.first))
        _ = stabilizer.stabilize(Self.observation("o_2", [Self.first[0], Self.first[1]]))
        let stable = stabilizer.stabilize(Self.observation("o_3", [Self.first[0], Self.first[1], ("button", "Export", 300, nil)]))
        let tree = try #require(stable.tree)
        #expect(tree.elements["e3"] == nil)
        #expect(tree.elements["e4"]?.label == "Export")
    }

    @Test("Same-looking elements match by nearest frame")
    func duplicates() throws {
        var stabilizer = ComputerUseRefStabilizer()
        _ = stabilizer.stabilize(Self.observation("o_1", [("button", nil, 10, nil), ("button", nil, 200, nil)]))
        let stable = stabilizer.stabilize(Self.observation("o_2", [("button", nil, 195, nil), ("button", nil, 400, nil)]))
        let tree = try #require(stable.tree)
        #expect(tree.elements["e2"]?.frame?.x == 195)
        #expect(tree.elements["e3"]?.frame?.x == 400)
        #expect(tree.elements["e1"] == nil)
    }

    @Test("A diff lists what was added, changed, and removed, and counts the unchanged")
    func diff() throws {
        var stabilizer = ComputerUseRefStabilizer()
        let base = stabilizer.stabilize(Self.observation("o_1", Self.first))
        let current = stabilizer.stabilize(Self.observation("o_2", [
            ("button", "Bold", 10, nil), ("textarea", nil, 100, "Hello world"), ("button", "Export", 300, nil),
        ]))
        let text = ComputerUseTreeDiff.render(base: try #require(base.tree), baseID: "o_1", current: try #require(current.tree))
        #expect(text.hasPrefix("window app=com.apple.TextEdit obs=o_2"))
        #expect(text.contains("1 added, 1 changed, 1 removed, 1 unchanged"))
        #expect(text.contains("+ [e4] button \"Export\""))
        #expect(text.contains("~ [e2] textarea value=\"Hello world\""))
        #expect(text.contains("- [e3] button \"Save\""))
        #expect(!text.contains("[e1]"))
    }

    @Test("No changes says so")
    func noChanges() throws {
        var stabilizer = ComputerUseRefStabilizer()
        let base = stabilizer.stabilize(Self.observation("o_1", Self.first))
        let current = stabilizer.stabilize(Self.observation("o_2", Self.first))
        let text = ComputerUseTreeDiff.render(base: try #require(base.tree), baseID: "o_1", current: try #require(current.tree))
        #expect(text.contains("No changes since o_1"))
    }

    @Test("Actions translate public refs back to the driver's before they reach the target")
    func actionTranslation() {
        let action = ComputerAction.drag(path: [.ref("e3", observation: "o_2"), .point(DisplayPoint(x: 1, y: 2), observation: "o_2")])
        let mapped = action.mappingElementRefs { ref, observation in observation == "o_2" && ref == "e3" ? "e4" : ref }
        #expect(mapped == .drag(path: [.ref("e4", observation: "o_2"), .point(DisplayPoint(x: 1, y: 2), observation: "o_2")]))
        #expect(ComputerAction.key(combo: KeyCombo(modifiers: [], key: "a")).mappingElementRefs { _, _ in "x" } == .key(combo: KeyCombo(modifiers: [], key: "a")))
    }

    @Test("Through the session: a diff observation reaches the model, and clicks reach the driver's ref")
    func session() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make(manifest: FakeDisplayTarget.vmManifest)
        await target.setTrees([
            Self.tree(Self.first, observation: "o_1"),
            Self.tree([Self.first[0], ("button", "Italic", 50, nil), Self.first[1], Self.first[2]], observation: "o_2"),
        ])
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        let second = await session.perform([.observe(ObserveRequest(modes: [.accessibility], scope: .display(nil), diffAgainst: "o_1"))])
        let tree = try #require(second.observations.first?.tree)
        let diff = try #require(tree.diff)
        #expect(diff.base == "o_1")
        #expect(diff.text.contains("+ [e4] button \"Italic\""))
        #expect(await target.observeCalls.allSatisfy { $0.diffAgainst == nil })

        _ = await session.perform([.click(at: .ref("e3", observation: "o_2"))])
        let delivered = try #require(await target.actCalls.last?.first)
        #expect(delivered == .click(at: .ref("e4", observation: "o_2")))
    }

    @Test("A diff against an observation no longer retained falls back to the full tree")
    func baseNotRetained() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make(manifest: FakeDisplayTarget.vmManifest)
        await target.setTrees([Self.tree(Self.first, observation: "o_1")])
        let result = await session.perform([.observe(ObserveRequest(modes: [.accessibility], scope: .display(nil), diffAgainst: "o_gone"))])
        let diff = try #require(result.observations.first?.tree?.diff)
        #expect(diff.text.contains("o_gone is no longer retained"))
        #expect(diff.text.contains("[e3] button \"Save\""))
    }
}
