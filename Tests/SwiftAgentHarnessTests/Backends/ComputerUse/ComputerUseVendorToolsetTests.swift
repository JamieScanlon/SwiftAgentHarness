import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// A session on a fake browser target, in the coordinate mode a vendor's tools speak.
enum ComputerUseVendorFixtures {
    static func session(
        coordinateMode: ComputerUseCoordinateMode,
        approvals: RecordingComputerUseApprovals = RecordingComputerUseApprovals(.approved)
    ) async throws -> (FakeDisplayTarget, ComputerUseSession) {
        let manifest = ComputerUseWatchModeTests.browserManifest
        let target = FakeDisplayTarget(manifest: manifest, now: { Date() })
        await target.setObserved(app: ComputerUseFixtures.textEdit, url: "https://shop.example/")
        let lease = try await target.lease(LeaseRequest(
            target: manifest.id,
            agentID: "agent",
            grants: [.domain("shop.example", tier: .full), .app(bundleID: ComputerUseFixtures.textEdit.bundleID, tier: .full)],
            budgets: ComputerUseBudgets(steps: 100, noProgressSteps: 100, maxDuration: .seconds(3600)),
            initiator: .operator,
            userPresent: true
        ))
        var configuration = ComputerUseSessionConfiguration(task: ComputerUseTaskContext(userRequest: ["Buy the blue mug."]))
        configuration.coordinateMode = coordinateMode
        let session = ComputerUseSession(target: target, lease: lease, configuration: configuration, approvals: approvals)
        _ = await session.perform([.observe(ObserveRequest(modes: [.pixels], scope: .display(nil)))])
        return (target, session)
    }

    static func call(_ name: String, _ arguments: [String: JSON], id: String = UUID().uuidString) -> ToolCall {
        ToolCall(name: name, arguments: .object(arguments), id: id)
    }

    static func point(_ x: Int, _ y: Int) -> DisplayPoint {
        DisplayPoint(x: Double(x), y: Double(y))
    }
}

@Suite("Computer use: OpenAI's computer tool")
struct ComputerUseOpenAIToolProviderTests {
    private typealias F = ComputerUseVendorFixtures

    private func action(_ type: String, _ fields: [String: JSON] = [:]) -> JSON {
        var object = fields
        object["type"] = .string(type)
        return .object(object)
    }

    @Test("A batch of actions runs in order through the screenshot's geometry and returns the screenshot after it")
    func batch() async throws {
        let (target, session) = try await F.session(coordinateMode: .imagePixels)
        let provider = ComputerUseOpenAIToolProvider(session: session, failures: ComputerUseNativeFailures())
        #expect(await provider.availableTools().map(\.name) == ["computer"])
        // The fixture screenshot is 1280×800 of a 1440×900 pt capture.
        let result = try await provider.executeTool(F.call("computer", ["actions": .array([
            action("screenshot"),
            action("click", ["button": .string("left"), "x": .integer(640), "y": .integer(400), "keys": .array([.string("SHIFT")])]),
            action("type", ["text": .string("blue mug")]),
            action("keypress", ["keys": .array([.string("CTRL"), .string("A")])]),
            action("scroll", ["x": .integer(0), "y": .integer(0), "scroll_x": .integer(0), "scroll_y": .integer(128)]),
            action("drag", ["path": .array([.array([.integer(0), .integer(0)]), .object(["x": .integer(128), "y": .integer(80)])])]),
        ])]))
        #expect(result.success)
        #expect(result.messageImages.count == 1)
        #expect(result.content == "OK")
        let acted = await target.actCalls.compactMap(\.first)
        #expect(acted == [
            .click(at: .point(F.point(720, 450), observation: "o_1"), modifiers: [.shift]),
            .type(text: "blue mug"),
            .key(combo: try KeyCombo(parsing: "ctrl+a")),
            .scroll(at: .point(F.point(0, 0), observation: "o_1"), dx: 0, dy: 144, unit: .pixel),
            .drag(path: [.point(F.point(0, 0), observation: "o_1"), .point(F.point(144, 90), observation: "o_1")]),
        ])
    }

    @Test("Pending safety checks are a question for the user, and are acknowledged only when the user said yes")
    func safetyChecks() async throws {
        let checks: JSON = .array([.object(["id": .string("sc_1"), "code": .string("malicious_instructions"), "message": .string("…")])])
        let approvals = RecordingComputerUseApprovals(.approved)
        let (_, session) = try await F.session(coordinateMode: .imagePixels, approvals: approvals)
        let provider = ComputerUseOpenAIToolProvider(session: session, failures: ComputerUseNativeFailures())
        let approved = try await provider.executeTool(F.call("computer", [
            "actions": .array([action("click", ["button": .string("left"), "x": .integer(1), "y": .integer(1)])]),
            "pending_safety_checks": checks,
        ]))
        #expect(approved.content.hasPrefix(ComputerUseOpenAIToolProvider.acknowledgedLine))
        #expect(await approvals.requests.count == 1)

        let declining = RecordingComputerUseApprovals(.denied("no"))
        let (target, declinedSession) = try await F.session(coordinateMode: .imagePixels, approvals: declining)
        let failures = ComputerUseNativeFailures()
        let declinedProvider = ComputerUseOpenAIToolProvider(session: declinedSession, failures: failures)
        let declined = try await declinedProvider.executeTool(F.call("computer", [
            "actions": .array([action("screenshot")]),
            "pending_safety_checks": checks,
        ], id: "call_x"))
        #expect(!declined.content.contains(ComputerUseOpenAIToolProvider.acknowledgedLine))
        #expect(declined.content.contains("refused"))
        #expect(declined.messageImages.count == 1, "the call still gets its screenshot")
        #expect(await failures.takeFailure(toolCallID: "call_x"))
        #expect(await target.actCalls.isEmpty)
    }

    @Test("Unknown actions and buttons fail without running anything")
    func invalid() async throws {
        let (target, session) = try await F.session(coordinateMode: .imagePixels)
        let provider = ComputerUseOpenAIToolProvider(session: session, failures: ComputerUseNativeFailures())
        #expect(!(try await provider.executeTool(F.call("computer", ["actions": .array([action("teleport")])]))).success)
        #expect(!(try await provider.executeTool(F.call("computer", ["actions": .array([
            action("type", ["text": .string("a")]), action("click", ["button": .string("back"), "x": .integer(1), "y": .integer(1)]),
        ])]))).success)
        #expect(await target.actCalls.isEmpty)
    }
}

@Suite("Computer use: Gemini's computer_use functions")
struct ComputerUseGeminiToolProviderTests {
    private typealias F = ComputerUseVendorFixtures

    private func provider(
        _ environment: GeminiComputerEnvironment = .browser,
        approvals: RecordingComputerUseApprovals = RecordingComputerUseApprovals(.approved)
    ) async throws -> (FakeDisplayTarget, ComputerUseGeminiToolProvider, ComputerUseNativeFailures) {
        let (target, session) = try await F.session(coordinateMode: .normalized1000, approvals: approvals)
        let failures = ComputerUseNativeFailures()
        let dialect = ComputerUseNativeDialect(toolset: .geminiComputerUse, environment: environment)
        return (target, ComputerUseGeminiToolProvider(session: session, dialect: dialect, failures: failures), failures)
    }

    private func response(_ result: ToolResult) throws -> [String: JSON] {
        guard case .object(let object) = try JSONDecoder().decode(JSON.self, from: Data(result.content.utf8)) else { return [:] }
        return object
    }

    private func string(_ json: JSON?) -> String? {
        if case .string(let value)? = json { return value }
        return nil
    }

    private func acknowledged(_ fields: [String: JSON]) -> Bool {
        if case .boolean(true)? = fields["safety_acknowledgement"] { return true }
        return false
    }

    @Test("Each environment offers only the functions its targets can carry out")
    func environments() {
        #expect(GeminiComputerEnvironment(manifest: ComputerUseWatchModeTests.browserManifest) == .browser)
        #expect(GeminiComputerEnvironment(manifest: FakeDisplayTarget.hostManifest) == .desktop)
        let browser = ComputerUseNativeDialect(toolset: .geminiComputerUse, environment: .browser)
        #expect(browser.geminiFunctionNames.contains("navigate"))
        #expect(!browser.geminiFunctionNames.contains("open_app"))
        #expect(browser.geminiExcludedFunctionNames.contains("key_down"))
        #expect(browser.geminiExcludedFunctionNames.contains("open_app"))
        let desktop = ComputerUseNativeDialect(toolset: .geminiComputerUse, environment: .desktop)
        #expect(desktop.geminiExcludedFunctionNames.contains("navigate"))
        let mobile = ComputerUseNativeDialect(toolset: .geminiComputerUse, environment: .mobile)
        #expect(mobile.geminiFunctionNames.contains("open_app"))
        #expect(!mobile.geminiFunctionNames.contains("hotkey"))
    }

    @Test("Functions on the 0–999 grid become canonical actions, and each result is the URL plus a screenshot")
    func translation() async throws {
        let (target, provider, _) = try await provider()
        #expect(Set(await provider.availableTools().map(\.name)) == Set(ComputerUseNativeDialect(toolset: .geminiComputerUse, environment: .browser).geminiFunctionNames))
        let cases: [(String, [String: JSON], (ObservationID) throws -> [ComputerAction])] = [
            ("click", ["x": .integer(500), "y": .integer(500), "intent": .string("Open the cart")], { o in [.click(at: .point(F.point(720, 450), observation: o))] }),
            ("right_click", ["x": .integer(0), "y": .integer(0)], { o in [.click(at: .point(F.point(0, 0), observation: o), button: .right)] }),
            ("type", ["text": .string("mug"), "press_enter": .boolean(true)], { _ in [.type(text: "mug"), .key(combo: KeyCombo(modifiers: [], key: "return"))] }),
            ("hotkey", ["keys": .array([.string("Control"), .string("c")])], { _ in [.key(combo: try KeyCombo(parsing: "ctrl+c"))] }),
            ("press_key", ["key": .string("Enter")], { _ in [.key(combo: KeyCombo(modifiers: [], key: "return"))] }),
            ("drag_and_drop", ["start_x": .integer(0), "start_y": .integer(0), "end_x": .integer(500), "end_y": .integer(500)],
             { o in [.drag(path: [.point(F.point(0, 0), observation: o), .point(F.point(720, 450), observation: o)])] }),
            ("scroll", ["direction": .string("down")], { _ in [.scroll(at: nil, dx: 0, dy: 270, unit: .pixel)] }),
            ("navigate", ["url": .string("https://shop.example/cart")], { _ in [.openURL("https://shop.example/cart")] }),
            ("wait", ["seconds": .integer(2)], { _ in [.wait(milliseconds: 2_000)] }),
        ]
        for (function, arguments, expected) in cases {
            let before = await target.actCalls.count
            let latest = try #require(await provider.session.latestScreenshot?.id)
            let result = try await provider.executeTool(F.call(function, arguments))
            #expect(result.success, "\(function): \(result.content)")
            #expect(result.messageImages.count == 1, "\(function)")
            #expect(string(try response(result)["url"]) == "https://shop.example/", "\(function)")
            #expect(await target.actCalls.dropFirst(before).compactMap(\.first) == (try expected(latest)), "\(function): \(result.content)")
        }
        let shot = try await provider.executeTool(F.call("take_screenshot", [:]))
        #expect(shot.messageImages.count == 1)
    }

    @Test("A require_confirmation decision is asked, and acknowledged in the result only when the user said yes")
    func safetyDecision() async throws {
        let decision: JSON = .object(["decision": .string("require_confirmation"), "explanation": .string("Checkout")])
        let approvals = RecordingComputerUseApprovals(.approved)
        let (_, provider, _) = try await provider(approvals: approvals)
        let approved = try await provider.executeTool(F.call("click", ["x": .integer(1), "y": .integer(1), "safety_decision": decision]))
        #expect(acknowledged(try response(approved)))
        #expect(await approvals.requests.count == 1)

        let (target, declining, failures) = try await self.provider(approvals: RecordingComputerUseApprovals(.denied("no")))
        let declined = try await declining.executeTool(F.call("click", ["x": .integer(1), "y": .integer(1), "safety_decision": decision], id: "fc_1"))
        let fields = try response(declined)
        #expect(!acknowledged(fields))
        #expect(string(fields["error"]) != nil)
        #expect(await failures.takeFailure(toolCallID: "fc_1"))
        #expect(await target.actCalls.isEmpty)

        let (_, quiet, _) = try await self.provider(approvals: approvals)
        let plain = try await quiet.executeTool(F.call("click", ["x": .integer(1), "y": .integer(1)]))
        #expect(!acknowledged(try response(plain)))
    }

    @Test("Functions outside the environment, and bad arguments, fail")
    func invalid() async throws {
        let (target, provider, _) = try await provider(.desktop)
        #expect(!(try await provider.executeTool(F.call("navigate", ["url": .string("https://a.example")]))).success)
        #expect(!(try await provider.executeTool(F.call("click", ["x": .integer(1000), "y": .integer(1)]))).success)
        #expect(!(try await provider.executeTool(F.call("scroll", ["direction": .string("sideways")]))).success)
        #expect(await target.actCalls.isEmpty)
    }
}
