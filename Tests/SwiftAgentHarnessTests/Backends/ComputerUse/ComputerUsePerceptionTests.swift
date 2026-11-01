import EasyJSON
import Foundation
import SwiftAgentKit
import Synchronization
import Testing
@testable import SwiftAgentHarness

/// Answers every image question with a fixed reply and records what it was asked.
final class ScriptedImageAsker: ComputerUseImageAsking, Sendable {
    struct Question: Sendable {
        var prompt: String
        var image: ToolResultImage
    }

    private let reply: @Sendable (String) throws -> String
    private let log = Mutex<[Question]>([])

    init(_ reply: @escaping @Sendable (String) throws -> String) {
        self.reply = reply
    }

    convenience init(answer: String) {
        self.init { _ in answer }
    }

    var questions: [Question] { log.withLock { $0 } }

    func ask(_ prompt: String, image: ToolResultImage) async throws -> String {
        log.withLock { $0.append(Question(prompt: prompt, image: image)) }
        return try reply(prompt)
    }
}

@Suite("Computer use: grounder and vision-describe roles")
struct ComputerUsePerceptionTests {
    private func session(
        describer: ComputerUseDescriber? = nil,
        grounder: ComputerUseGrounder? = nil,
        showsScreenshots: Bool = true,
        coordinateMode: ComputerUseCoordinateMode = .imagePixels
    ) async throws -> (FakeDisplayTarget, ComputerUseSession, ComputerUseToolProvider) {
        let target = FakeDisplayTarget(manifest: FakeDisplayTarget.vmManifest)
        await target.setScreenshot(try ComputerUseFixtures.pngScreenshot())
        let lease = try await target.lease(LeaseRequest(
            target: target.manifest.id,
            agentID: "agent",
            grants: ComputerUseSessionFixtures.grants,
            budgets: ComputerUseBudgets(steps: 100, maxDuration: .seconds(3600)),
            operatorInitiated: true,
            userPresent: true
        ))
        var configuration = ComputerUseSessionConfiguration(
            task: ComputerUseTaskContext(userRequest: ["Bold the title."]),
            coordinateMode: coordinateMode
        )
        configuration.describer = describer
        configuration.grounder = grounder
        configuration.showsScreenshots = showsScreenshots
        let session = ComputerUseSession(target: target, lease: lease, configuration: configuration, now: { ComputerUseFixtures.epoch })
        return (target, session, ComputerUseToolProvider(session: session))
    }

    private func call(_ provider: ComputerUseToolProvider, _ name: String, _ arguments: [String: JSON] = [:]) async throws -> ToolResult {
        try await provider.executeTool(ToolCall(name: name, arguments: .object(arguments), id: "call-1"))
    }

    private func image(of result: ToolResult) -> ToolResultImage? {
        result.parts.lazy.compactMap { if case .image(let image) = $0 { image } else { nil } }.first
    }

    // MARK: - Grounder

    @Test("Grounder answers are read for a point in the common shapes, and a box gives its center")
    func pointParsing() {
        let point = ComputerUseGrounder.point(in:)
        #expect(point("(412, 230)")! == (412, 230))
        #expect(point("<point>412 230</point>")! == (412, 230))
        #expect(point(#"{"x": 412.5, "y": 230}"#)! == (412.5, 230))
        #expect(point("click at x=5, y=6")! == (5, 6))
        #expect(point("[100, 200, 300, 400]")! == (200, 300))
        #expect(point("I can't find that element.") == nil)
        #expect(point("only 7") == nil)
    }

    @Test("The grounder is sent the screenshot and a redacted description, and its pixels map to target points")
    func groundingInPixels() async throws {
        let asker = ScriptedImageAsker(answer: "(640, 400)")
        let grounder = ComputerUseGrounder(model: asker)
        var observation = ComputerUseFixtures.observation(id: "o_1")
        observation.image?.data = try ComputerUseFixtures.pngScreenshot()

        let located = try await grounder.locate("the field after password: hunter2", in: observation)
        // 1280×800 pixels over 1440×900 points.
        #expect(located == DisplayPoint(x: 720, y: 450))
        let question = try #require(asker.questions.first)
        #expect(question.image.data == observation.image?.data)
        #expect(question.image.width == 1280 && question.image.height == 800)
        #expect(question.prompt.contains("1280×800"))
        #expect(!question.prompt.contains("hunter2"))
        #expect(question.prompt.contains(ComputerUseSecrets.marker))
    }

    @Test("A grounder that answers on a 0–999 grid is mapped through it; points off the screenshot are refused")
    func groundingOnGrid() async throws {
        let observation = ComputerUseFixtures.observation(id: "o_1")
        let grid = ComputerUseGrounder(model: ScriptedImageAsker(answer: "<point>500 250</point>"), coordinateMode: .normalized1000)
        #expect(try await grid.locate("Save", in: observation) == DisplayPoint(x: 720, y: 225))

        let outside = ComputerUseGrounder(model: ScriptedImageAsker(answer: "(5000, 10)"))
        await #expect(throws: ComputerUsePerceptionError.outsideScreenshot) {
            try await outside.locate("Save", in: observation)
        }
        let vague = ComputerUseGrounder(model: ScriptedImageAsker(answer: "not visible"))
        await #expect(throws: ComputerUsePerceptionError.noPoint(answer: "not visible")) {
            try await vague.locate("Save", in: observation)
        }
        await #expect(throws: ComputerUsePerceptionError.noScreenshot) {
            try await grid.locate("Save", in: ComputerUseFixtures.observation(id: "o_2", withImage: false))
        }
    }

    // MARK: - Describer

    @Test("The describer is sent the screenshot with standing instructions and a redacted question")
    func describing() async throws {
        let asker = ScriptedImageAsker(answer: "  A Save dialog is open.  ")
        let describer = ComputerUseDescriber(model: asker)
        let observation = ComputerUseFixtures.observation(id: "o_1")
        #expect(try await describer.describe("Is a dialog open? token: sk-abcdefghijklmnopqrstuvwxyz", in: observation) == "A Save dialog is open.")
        let question = try #require(asker.questions.first)
        #expect(question.prompt.hasPrefix(ComputerUseDescriber.instructions))
        #expect(question.prompt.contains("Is a dialog open?"))
        #expect(!question.prompt.contains("sk-abcdefghijklmnopqrstuvwxyz"))

        let silent = ComputerUseDescriber(model: ScriptedImageAsker(answer: " "))
        await #expect(throws: ComputerUsePerceptionError.noAnswer) {
            try await silent.describe("Anything?", in: observation)
        }
    }

    // MARK: - Tools

    @Test("computer_describe and computer_locate are offered only with their role bound; zoom only when screenshots are shown")
    func offering() async throws {
        let names: (ComputerUseToolProvider) async -> Set<String> = { Set(await $0.availableTools().map(\.name)) }
        let (_, _, plain) = try await session()
        #expect(await !names(plain).contains(ComputerUseToolProvider.describeToolName))
        #expect(await !names(plain).contains(ComputerUseToolProvider.locateToolName))
        #expect(await names(plain).contains(ComputerUseToolProvider.zoomToolName))

        let (_, _, textOnly) = try await session(
            describer: ComputerUseDescriber(model: ScriptedImageAsker(answer: "")),
            grounder: ComputerUseGrounder(model: ScriptedImageAsker(answer: "")),
            showsScreenshots: false
        )
        let offered = await names(textOnly)
        #expect(offered.contains(ComputerUseToolProvider.describeToolName))
        #expect(offered.contains(ComputerUseToolProvider.locateToolName))
        #expect(!offered.contains(ComputerUseToolProvider.zoomToolName))
        let observe = try #require(await textOnly.availableTools().first { $0.name == ComputerUseToolProvider.observeToolName })
        #expect(observe.description.contains(ComputerUseToolProvider.describeToolName))

        let (_, grounded, _) = try await session(grounder: ComputerUseGrounder(model: ScriptedImageAsker(answer: "")))
        let companions = ComputerUseToolProvider(session: grounded, offering: ComputerUseToolProvider.nativeCompanionToolNames)
        #expect(await names(companions).contains(ComputerUseToolProvider.locateToolName))
    }

    @Test("computer_describe answers about a fresh screenshot it can cite, and the step is an observation")
    func describeTool() async throws {
        let asker = ScriptedImageAsker(answer: "The title is bold.")
        let (target, session, provider) = try await session(describer: ComputerUseDescriber(model: asker), showsScreenshots: false)
        let result = try await call(provider, ComputerUseToolProvider.describeToolName, ["question": .string("Is the title bold?")])
        #expect(result.success)
        #expect(result.content.contains("Observation o_1"))
        #expect(result.content.contains("The title is bold."))
        #expect(image(of: result) == nil)
        #expect(await target.observeCalls.map(\.modes) == [[.pixels]])
        #expect(await session.observation("o_1") != nil)
        #expect(await target.actCalls.isEmpty)
        #expect(asker.questions.first?.image.data == (try ComputerUseFixtures.pngScreenshot()))
    }

    @Test("A describer that fails comes back as a failed tool result")
    func describeFailure() async throws {
        struct Down: Error {}
        let (_, _, provider) = try await session(describer: ComputerUseDescriber(model: ScriptedImageAsker { _ in throw Down() }))
        let result = try await call(provider, ComputerUseToolProvider.describeToolName, ["question": .string("Is the title bold?")])
        #expect(!result.success)
        #expect(result.content.contains("vision model"))
    }

    @Test("computer_locate returns a point in the model's own coordinates on a citable observation, and the element under it")
    func locateTool() async throws {
        // e2 (Bold) spans points 10–40 × 10–30; its center is pixel (22.2, 17.8).
        let grounder = ComputerUseGrounder(model: ScriptedImageAsker(answer: "(22, 18)"))
        let (target, _, provider) = try await session(grounder: grounder, coordinateMode: .normalized1000)
        let result = try await call(provider, ComputerUseToolProvider.locateToolName, ["description": .string("the Bold button")])
        #expect(result.success)
        #expect(result.content.contains("Observation o_1"))
        #expect(result.content.contains("x=17, y=23"))
        #expect(result.content.contains("e2 (AXButton)"))
        #expect(Set(try #require(await target.observeCalls.first).modes) == [.pixels, .accessibility])

        let click = try await call(provider, ComputerUseToolProvider.clickToolName, [
            "observation": .string("o_1"), "x": .double(17), "y": .double(23),
        ])
        #expect(click.success)
        guard case .click(.point(let point, _), _, _, _)? = await target.actCalls.first?.first else {
            Issue.record("expected a point click")
            return
        }
        #expect(abs(point.x - 24.48) < 0.01 && abs(point.y - 20.7) < 0.01)
    }

    @Test("A grounder that gives no point is a failed result that says what to try")
    func locateFailure() async throws {
        let (_, _, provider) = try await session(grounder: ComputerUseGrounder(model: ScriptedImageAsker(answer: "nothing like that")))
        let result = try await call(provider, ComputerUseToolProvider.locateToolName, ["description": .string("the Bold button")])
        #expect(!result.success)
        #expect(result.content.contains("no point"))
    }

    @Test("A model that can't see images gets the tree without the screenshot, though one is still taken")
    func textOnlyObserve() async throws {
        let (target, session, provider) = try await session(
            describer: ComputerUseDescriber(model: ScriptedImageAsker(answer: "")),
            showsScreenshots: false
        )
        let result = try await call(provider, ComputerUseToolProvider.observeToolName)
        #expect(image(of: result) == nil)
        #expect(result.content.contains("not shown to you"))
        #expect(!result.content.contains(ComputerUseToolProvider.screenshotTagsNote))
        #expect(try #require(await target.observeCalls.first).modes.contains(.pixels))
        #expect(await session.observation("o_1")?.image != nil)
    }

    @Test("Describe and locate results are screen content: wrapped as untrusted, never exempt")
    func provenance() {
        for name in [ComputerUseToolProvider.describeToolName, ComputerUseToolProvider.locateToolName] {
            #expect(ComputerUseToolProvider.screenToolNames.contains(name))
            #expect(!ComputerUseToolProvider.harnessToolNames.contains(name))
            #expect(ToolExternalContentPolicy.resolve(toolName: name, entry: nil).source == .screen)
            #expect(ComputerUseDelegateToolProvider.specialistToolNames.contains(name))
        }
    }
}
