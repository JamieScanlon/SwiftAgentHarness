import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use: Anthropic's native toolset")
struct ComputerUseNativeToolsetTests {
    private func provider(
        _ toolset: ComputerUseNativeToolset = .toolset20260801
    ) async throws -> (FakeDisplayTarget, ComputerUseSession, ComputerUseNativeToolProvider, ComputerUseNativeFailures) {
        let (target, session) = try await ComputerUseSessionFixtures.make(manifest: FakeDisplayTarget.vmManifest)
        let failures = ComputerUseNativeFailures()
        return (target, session, ComputerUseNativeToolProvider(session: session, toolset: toolset, failures: failures), failures)
    }

    private func call(_ name: String, _ arguments: [String: JSON] = [:], id: String = UUID().uuidString) -> ToolCall {
        ToolCall(name: name, arguments: .object(arguments), id: id)
    }

    private func point(_ x: Int, _ y: Int) -> JSON { .array([.integer(x), .integer(y)]) }

    @Test("Model versions map to toolsets; the older ones need beta headers and the oldest has no zoom")
    func versions() {
        #expect(ComputerUseNativeToolset(version: "computer_toolset_20260801") == .toolset20260801)
        #expect(ComputerUseNativeToolset(version: "computer_20251124")?.betaHeader == "computer-use-2025-11-24")
        #expect(ComputerUseNativeToolset(version: "computer_20250124")?.betaHeader == "computer-use-2025-01-24")
        #expect(ComputerUseNativeToolset(version: "toolset-2026-08") == nil)
        #expect(ComputerUseNativeToolset.toolset20260801.betaHeader == nil)
        #expect(ComputerUseNativeToolset.toolset20260801.memberNames.count == 17)
        #expect(!ComputerUseNativeToolset.computer20250124.memberNames.contains("zoom"))
        #expect(ComputerUseNativeToolset.toolset20260801.registeredToolNames.contains("left_click"))
        #expect(ComputerUseNativeToolset.computer20251124.registeredToolNames == ["computer"])
    }

    @Test("The toolset registers one tool per member; the older versions register a single computer tool")
    func registration() async throws {
        let (_, _, toolset, _) = try await provider()
        #expect(Set(await toolset.availableTools().map(\.name)) == ComputerUseNativeToolset.toolset20260801.registeredToolNames)
        let (_, _, older, _) = try await provider(.computer20251124)
        #expect(await older.availableTools().map(\.name) == ["computer"])
    }

    @Test("A screenshot comes back as an image with its observation id; clicks land through its geometry")
    func screenshotAndClick() async throws {
        let (target, _, provider, _) = try await provider()
        let shot = try await provider.executeTool(call("screenshot"))
        #expect(shot.success)
        #expect(shot.messageImages.count == 1)
        #expect(shot.content.contains("o_1"))

        // The fixture screenshot is 1280×800 of a 1440×900 pt capture.
        let click = try await provider.executeTool(call("left_click", ["coordinate": point(640, 400), "text": .string("shift")]))
        #expect(click.success)
        #expect(click.content.hasPrefix("OK"))
        #expect(await target.actCalls.last?.first == .click(
            at: .point(DisplayPoint(x: 720, y: 450), observation: "o_1"), modifiers: [.shift]
        ))
    }

    @Test("Each member translates to the canonical action the session gates")
    func translation() async throws {
        let (target, _, provider, _) = try await provider()
        _ = try await provider.executeTool(call("screenshot"))
        let cases: [(String, [String: JSON], ComputerAction)] = [
            ("double_click", ["coordinate": point(0, 0)], .click(at: .point(DisplayPoint(x: 0, y: 0), observation: "o_1"), count: 2)),
            ("right_click", ["coordinate": point(0, 0)], .click(at: .point(DisplayPoint(x: 0, y: 0), observation: "o_1"), button: .right)),
            ("mouse_move", ["coordinate": point(128, 80)], .move(to: .point(DisplayPoint(x: 144, y: 90), observation: "o_1"))),
            ("left_click_drag", ["start_coordinate": point(0, 0), "coordinate": point(128, 80)], .drag(path: [
                .point(DisplayPoint(x: 0, y: 0), observation: "o_1"), .point(DisplayPoint(x: 144, y: 90), observation: "o_1"),
            ])),
            ("left_mouse_down", [:], .pointer(state: .down)),
            ("scroll", ["scroll_direction": .string("down"), "scroll_amount": .integer(3)], .scroll(at: nil, dx: 0, dy: 3, unit: .line)),
            ("scroll", ["scroll_direction": .string("left"), "scroll_amount": .integer(2), "coordinate": point(0, 0)],
             .scroll(at: .point(DisplayPoint(x: 0, y: 0), observation: "o_1"), dx: -2, dy: 0, unit: .line)),
            ("type", ["text": .string("hello")], .type(text: "hello")),
            ("key", ["text": .string("ctrl+s"), "repeat": .integer(2)], .key(combo: try KeyCombo(parsing: "ctrl+s"), repeatCount: 2)),
            ("key", ["text": .string("Delete")], .key(combo: KeyCombo(modifiers: [], key: "forward-delete"))),
            ("key", ["text": .string("Page_Down")], .key(combo: KeyCombo(modifiers: [], key: "page-down"))),
            ("hold_key", ["text": .string("space"), "duration": .double(1.5)], .hold(combo: try KeyCombo(parsing: "space"), milliseconds: 1_500)),
            ("wait", ["duration": .integer(2)], .wait(milliseconds: 2_000)),
        ]
        for (member, arguments, expected) in cases {
            let result = try await provider.executeTool(call(member, arguments))
            #expect(result.success, "\(member): \(result.error ?? "")")
            #expect(await target.actCalls.last?.first == expected, "\(member)")
        }
    }

    @Test("cursor_position reports the last pointer position in screenshot pixels")
    func cursorPosition() async throws {
        let (_, _, provider, _) = try await provider()
        _ = try await provider.executeTool(call("screenshot"))
        #expect(!(try await provider.executeTool(call("cursor_position"))).success)
        _ = try await provider.executeTool(call("mouse_move", ["coordinate": point(128, 80)]))
        #expect(try await provider.executeTool(call("cursor_position")).content.hasPrefix("X=128, Y=80"))
    }

    @Test("Zoom takes a region in screenshot pixels and returns an image")
    func zoom() async throws {
        let (target, _, provider, _) = try await provider()
        _ = try await provider.executeTool(call("screenshot"))
        let zoomed = try await provider.executeTool(call("zoom", ["region": .array([.integer(0), .integer(0), .integer(640), .integer(400)])]))
        #expect(zoomed.success)
        #expect(zoomed.messageImages.count == 1)
        #expect(await target.observeCalls.last?.scope == .region(DisplayRect(x: 0, y: 0, width: 720, height: 450)))
    }

    @Test("A failed action is reported as a failure and recorded for batch halting")
    func failureRecorded() async throws {
        let (_, _, provider, failures) = try await provider()
        let early = try await provider.executeTool(call("left_click", ["coordinate": point(1, 1)], id: "call-early"))
        #expect(!early.success)
        #expect(early.error?.contains("screenshot") == true)
        #expect(await failures.takeFailure(toolCallID: "call-early"))
        #expect(await !failures.takeFailure(toolCallID: "call-early"))
        _ = try await provider.executeTool(call("screenshot", id: "call-shot"))
        #expect(await !failures.takeFailure(toolCallID: "call-shot"))
        let lone = try await provider.executeTool(call("hold_key", ["text": .string("shift"), "duration": .integer(1)], id: "call-lone"))
        #expect(lone.error?.contains("click") == true)
        #expect(await failures.takeFailure(toolCallID: "call-lone"))
        let bad = try await provider.executeTool(call("key", ["text": .string("ctrl+")], id: "call-bad"))
        #expect(!bad.success)
        #expect(await failures.takeFailure(toolCallID: "call-bad"))
    }

    @Test("The older computer tool takes the member as its action")
    func olderTool() async throws {
        let (target, _, older, _) = try await provider(.computer20251124)
        _ = try await older.executeTool(call("computer", ["action": .string("screenshot")]))
        let click = try await older.executeTool(call("computer", ["action": .string("left_click"), "coordinate": point(640, 400)]))
        #expect(click.success)
        #expect(await target.actCalls.last?.first == .click(at: .point(DisplayPoint(x: 720, y: 450), observation: "o_1")))
        let unknown = try await older.executeTool(call("computer", ["action": .string("teleport")]))
        #expect(!unknown.success)
        let (_, _, oldest, _) = try await provider(.computer20250124)
        _ = try await oldest.executeTool(call("computer", ["action": .string("screenshot")]))
        #expect(!(try await oldest.executeTool(call("computer", ["action": .string("zoom"), "region": .array([.integer(0), .integer(0), .integer(1), .integer(1)])]))).success)
    }
}
