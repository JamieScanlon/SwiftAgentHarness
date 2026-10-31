import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use tool family")
struct ComputerUseToolProviderTests {
    private func provider(
        manifest: DisplayTargetManifest = FakeDisplayTarget.vmManifest,
        coordinateMode: ComputerUseCoordinateMode = .imagePixels,
        oversight: (any ComputerUseOversight)? = nil,
        successCriteria: [String] = []
    ) async throws -> (FakeDisplayTarget, ComputerUseSession, ComputerUseToolProvider) {
        let target = FakeDisplayTarget(manifest: manifest)
        let lease = try await target.lease(LeaseRequest(
            target: manifest.id,
            agentID: "agent",
            grants: ComputerUseSessionFixtures.grants + [.domain("example.com", tier: .click)],
            budgets: ComputerUseBudgets(steps: 100, maxDuration: .seconds(3600)),
            operatorInitiated: true,
            userPresent: true
        ))
        let session = ComputerUseSession(
            target: target,
            lease: lease,
            configuration: ComputerUseSessionConfiguration(
                task: ComputerUseTaskContext(userRequest: ["Bold the title."], successCriteria: successCriteria),
                coordinateMode: coordinateMode
            ),
            oversight: oversight,
            now: { ComputerUseFixtures.epoch }
        )
        return (target, session, ComputerUseToolProvider(session: session))
    }

    private func call(_ provider: ComputerUseToolProvider, _ name: String, _ arguments: [String: JSON] = [:]) async throws -> ToolResult {
        try await provider.executeTool(ToolCall(name: name, arguments: .object(arguments), id: "call-1"))
    }

    @Test("The family exposes the spec's element-ref-first tools with flat schemas")
    func toolList() async throws {
        let (_, _, provider) = try await provider()
        let tools = await provider.availableTools()
        #expect(tools.map(\.name) == [
            "computer_observe", "computer_click", "computer_type", "computer_key", "computer_scroll",
            "computer_press", "computer_set_value", "computer_menu", "computer_launch", "computer_open_url",
            "computer_zoom", "computer_wait_for", "computer_verify", "computer_ask_user", "computer_handoff",
        ])
        let primitive: Set<String> = ["string", "integer", "number", "boolean"]
        #expect(tools.allSatisfy { $0.type == .function && $0.parameters.allSatisfy { primitive.contains($0.type) } })
        #expect(tools.allSatisfy { $0.name.range(of: "^[a-zA-Z0-9_-]{1,64}$", options: .regularExpression) != nil })
    }

    @Test("The observe description carries the control ladder; pointer tools state the frozen coordinate mode")
    func descriptions() async throws {
        let (_, _, pixels) = try await provider()
        let tools = await pixels.availableTools()
        let observe = try #require(tools.first { $0.name == "computer_observe" })
        #expect(observe.description.contains("API"))
        let click = try #require(tools.first { $0.name == "computer_click" })
        #expect(click.parameters.first { $0.name == "x" }?.description.contains("pixel") == true)

        let (_, _, normalized) = try await provider(coordinateMode: .normalized1000)
        let normalizedClick = try #require(await normalized.availableTools().first { $0.name == "computer_click" })
        #expect(normalizedClick.parameters.first { $0.name == "x" }?.description.contains("0–999") == true)
    }

    @Test("Observe returns the receipt id, the tree, and the screenshot geometry")
    func observe() async throws {
        let (_, _, provider) = try await provider()
        let result = try await call(provider, "computer_observe")
        #expect(result.success)
        #expect(result.content.contains("o_1"))
        #expect(result.content.contains("[e2] button \"Bold\""))
        guard case .object(let metadata) = result.metadata,
              case .object(let observation)? = metadata["observation"],
              case .string(let id)? = observation["id"] else {
            Issue.record("missing observation metadata")
            return
        }
        #expect(id == "o_1")
        #expect(observation["image"] != nil)
    }

    @Test("A ref click cites its observation and reaches the target")
    func refClick() async throws {
        let (target, _, provider) = try await provider()
        _ = try await call(provider, "computer_observe")
        let result = try await call(provider, "computer_click", ["observation": .string("o_1"), "ref": .string("e2")])
        #expect(result.success)
        #expect(await target.actCalls.last == [.click(at: .ref("e2", observation: "o_1"))])
    }

    @Test("Pixel coordinates are decoded through the cited screenshot's geometry")
    func pixelClick() async throws {
        let (target, _, provider) = try await provider()
        _ = try await call(provider, "computer_observe")
        _ = try await call(provider, "computer_click", [
            "observation": .string("o_1"), "x": .integer(640), "y": .integer(400), "button": .string("right"), "count": .integer(2),
        ])
        #expect(await target.actCalls.last == [
            .click(at: .point(DisplayPoint(x: 720, y: 450), observation: "o_1"), button: .right, count: 2),
        ])
    }

    @Test("Normalized sessions decode the 0–999 grid")
    func normalizedClick() async throws {
        let (target, _, provider) = try await provider(coordinateMode: .normalized1000)
        _ = try await call(provider, "computer_observe")
        _ = try await call(provider, "computer_click", ["observation": .string("o_1"), "x": .integer(500), "y": .integer(500)])
        #expect(await target.actCalls.last == [.click(at: .point(DisplayPoint(x: 720, y: 450), observation: "o_1"))])
    }

    @Test("Malformed calls fail without reaching the target")
    func malformed() async throws {
        let (target, _, provider) = try await provider()
        _ = try await call(provider, "computer_observe")
        let missing = try await call(provider, "computer_click", ["ref": .string("e2")])
        #expect(!missing.success)
        let outside = try await call(provider, "computer_click", ["observation": .string("o_1"), "x": .integer(5000), "y": .integer(1)])
        #expect(!outside.success)
        let both = try await call(provider, "computer_click", ["observation": .string("o_1")])
        #expect(!both.success)
        let combo = try await call(provider, "computer_key", ["combo": .string("cmd+shift")])
        #expect(!combo.success)
        #expect(await target.actCalls.isEmpty)
    }

    @Test("A refused action reports the harness's reason and does not invite a retry")
    func refused() async throws {
        let (_, _, provider) = try await provider()
        let result = try await call(provider, "computer_open_url", ["url": .string("file:///etc/hosts")])
        #expect(!result.success)
        #expect(result.content.contains("refused"))
        #expect(result.content.contains("http(s)"))
    }

    @Test("An unverifiable result tells the model to observe rather than repeat the action")
    func unverifiableGuidance() async throws {
        let (target, _, provider) = try await provider()
        await target.setOutcomes { _, index in ActionOutcome(action: index, effect: .unverifiable, evidence: "no tree change") }
        _ = try await call(provider, "computer_observe")
        let result = try await call(provider, "computer_press", ["observation": .string("o_1"), "ref": .string("e6")])
        #expect(result.content.contains("unverifiable"))
        #expect(result.content.contains("Do not repeat"))
    }

    @Test("Type, key, scroll, menu, launch, and open-url map to canonical actions")
    func canonicalMapping() async throws {
        let (target, _, provider) = try await provider()
        _ = try await call(provider, "computer_observe")
        _ = try await call(provider, "computer_type", ["text": .string("Title"), "observation": .string("o_1"), "ref": .string("e5"), "mode": .string("set-value")])
        _ = try await call(provider, "computer_key", ["combo": .string("Command+B"), "repeat": .integer(1)])
        _ = try await call(provider, "computer_scroll", ["observation": .string("o_1"), "ref": .string("e5"), "dy": .integer(-3)])
        _ = try await call(provider, "computer_menu", ["path": .string("Format > Font > Bold"), "app": .string("com.apple.TextEdit")])
        _ = try await call(provider, "computer_launch", ["app": .string("com.apple.TextEdit")])
        _ = try await call(provider, "computer_open_url", ["url": .string("https://example.com/")])
        #expect(await target.actCalls == [
            [.type(text: "Title", into: .ref("e5", observation: "o_1"), mode: .setValue)],
            [.key(combo: try KeyCombo(parsing: "cmd+b"))],
            [.scroll(at: .ref("e5", observation: "o_1"), dx: 0, dy: -3, unit: .line)],
            [.menu(path: ["Format", "Font", "Bold"], app: "com.apple.TextEdit")],
            [.launch(app: "com.apple.TextEdit", background: true)],
            [.openURL("https://example.com/")],
        ])
    }

    @Test("Zoom crops a region given in the cited screenshot's coordinates")
    func zoom() async throws {
        let (target, _, provider) = try await provider()
        _ = try await call(provider, "computer_observe")
        let result = try await call(provider, "computer_zoom", [
            "observation": .string("o_1"), "x": .integer(0), "y": .integer(0), "width": .integer(640), "height": .integer(400),
        ])
        #expect(result.success)
        #expect(await target.observeCalls.last?.scope == .region(DisplayRect(x: 0, y: 0, width: 720, height: 450)))
    }

    @Test("Verify records evidence against a fresh observation")
    func verify() async throws {
        let (_, session, provider) = try await provider()
        _ = try await call(provider, "computer_observe")
        let result = try await call(provider, "computer_verify", [
            "criterion": .string("title is bold"), "met": .boolean(true), "evidence": .string("Bold button pressed state"), "observation": .string("o_1"),
        ])
        #expect(result.success)
        #expect(await session.verifications.count == 1)
    }

    @Test("Verify refuses a criterion that matches none of the task's, and lists them")
    func verifyUnknownCriterion() async throws {
        let (_, session, provider) = try await provider(successCriteria: ["The title is bold", "The file is saved"])
        _ = try await call(provider, "computer_observe")
        let unknown = try await call(provider, "computer_verify", [
            "criterion": .string("The page is bold"), "met": .boolean(true), "evidence": .string("x"), "observation": .string("o_1"),
        ])
        #expect(!unknown.success)
        #expect(unknown.content.contains("1. The title is bold; 2. The file is saved"))
        #expect(await session.verifications.isEmpty)
        let listed = try await call(provider, "computer_verify", [
            "criterion": .string("1. The title is bold"), "met": .boolean(true), "evidence": .string("x"), "observation": .string("o_1"),
        ])
        #expect(listed.success)
        #expect(await session.unverifiedCriteria.map(\.number) == [2])
    }

    @Test("Ask-user and handoff route through oversight")
    func oversightTools() async throws {
        let oversight = ScriptedComputerUseOversight(reply: "Use the second file.")
        let (target, _, provider) = try await provider(manifest: FakeDisplayTarget.hostManifest, oversight: oversight)
        let answer = try await call(provider, "computer_ask_user", ["question": .string("Which file?")])
        #expect(answer.content.contains("Use the second file."))
        let handoff = try await call(provider, "computer_handoff", ["reason": .string("login"), "prompt": .string("Please sign in.")])
        #expect(handoff.success)
        #expect(await target.takeoverStates == [true, false])
        let bad = try await call(provider, "computer_handoff", ["reason": .string("bored"), "prompt": .string("x")])
        #expect(!bad.success)
    }

    @Test("Screen-bearing results are wrapped as untrusted screen content; harness-only tools are exempt")
    func externalContentPolicy() {
        let observe = ToolExternalContentPolicy.resolve(toolName: "computer_observe", entry: nil)
        #expect(observe.shouldWrap)
        #expect(observe.source == .screen)
        #expect(observe.includeSecurityPreamble)
        #expect(ToolExternalContentPolicy.resolve(toolName: "computer_click", entry: nil).source == .screen)
        #expect(!ToolExternalContentPolicy.resolve(toolName: "computer_ask_user", entry: nil).shouldWrap)
        #expect(!ToolExternalContentPolicy.resolve(toolName: "computer_verify", entry: nil).shouldWrap)
        #expect(!ToolExternalContentPolicy.resolve(toolName: "computer_handoff", entry: nil).shouldWrap)
    }

    @Test("Observe returns the screenshot as an image part sized as its recorded geometry")
    func observeReturnsImagePart() async throws {
        let (_, _, provider) = try await provider()
        let result = try await call(provider, "computer_observe")
        let image = try #require(result.images.first)
        #expect(image.data == ToolImageFixtures.tinyPNG)
        #expect(image.mediaType == "image/png")
        #expect(image.width == ComputerUseFixtures.geometry.imageSize.width)
        #expect(image.height == ComputerUseFixtures.geometry.imageSize.height)
        #expect(result.content.contains("[e2] button \"Bold\""))
        #expect(!result.content.contains(ToolImageFixtures.tinyPNG.base64EncodedString()))
    }

    @Test("Observing without a screenshot, and plain actions, return no image part")
    func noScreenshotNoImage() async throws {
        let (_, _, provider) = try await provider()
        let treeOnly = try await call(provider, "computer_observe", ["include_screenshot": .boolean(false)])
        #expect(treeOnly.images.isEmpty)
        #expect(treeOnly.content.contains("[e2] button \"Bold\""))
        let click = try await call(provider, "computer_click", ["observation": .string("o_1"), "ref": .string("e2")])
        #expect(click.images.isEmpty)
    }

    @Test("Screen tools declare geometry-bound images so the pipeline never resizes them")
    func screenToolsAreGeometryBound() async throws {
        let (_, _, provider) = try await provider()
        let tools = await provider.availableTools()
        let observe = try #require(tools.first { $0.name == ComputerUseToolProvider.observeToolName })
        let ask = try #require(tools.first { $0.name == ComputerUseToolProvider.askUserToolName })
        #expect(await provider.policyTags(for: observe).contains(ToolRegistryResultFormattingPolicy.geometryBoundImagesPolicyTag()))
        #expect(await provider.policyTags(for: ask).isEmpty)
    }

    @Test("The session's image limit reaches every observe request, and defaults within the pipeline's cap")
    func imageLimitApplied() async throws {
        let (target, session, provider) = try await provider()
        _ = try await call(provider, "computer_observe")
        let limit = try #require(await target.observeCalls.last?.maxImage)
        #expect(limit == session.configuration.imageLimit)
        #expect(limit.longEdgePx <= ToolResultFormattingConfiguration.default.maxInlineImagePixelDimension)
    }

    @Test("Unknown tools throw")
    func unknownTool() async throws {
        let (_, _, provider) = try await provider()
        await #expect(throws: ComputerUseToolProvider.Error.self) {
            _ = try await provider.executeTool(ToolCall(name: "computer_teleport", id: "x"))
        }
    }
}
