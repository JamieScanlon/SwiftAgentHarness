import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

enum ToolImageFixtures {
    /// 1×1 PNG.
    static let tinyPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    static func pngPart(_ data: Data = tinyPNG, width: Int? = 1, height: Int? = 1) -> ToolResultContentPart {
        .image(ToolResultImage(data: data, mediaType: "image/png", width: width, height: height))
    }

    static func imageResult(text: String = "observed", toolCallId: String = "call-1") -> ToolResult {
        ToolResult(success: true, parts: [.text(text), pngPart()], metadata: .object(["k": .string("v")]), toolCallId: toolCallId)
    }
}

/// Reports every image as oversized and "rescales" it to a marker payload, so tests can see whether a rescale ran.
struct OversizeReportingImageProcessor: ImageProcessing {
    static let rescaled = Data("rescaled".utf8)

    func generateThumbnail(from data: Data, maxPixelSize: Int) -> Data? { data }
    func scaleImage(_ data: Data, maxPixelDimension: Int) -> Data? { Self.rescaled }
    func scaleImageToFileSize(_ data: Data, maxFileSize: Int) -> Data? { data }
}

@Suite("Tool result image parts through the harness pipeline")
struct ToolResultImagePartsTests {
    private func entry(_ name: String, tags: Set<ToolRegistryEntry.PolicyTag> = []) -> ToolRegistryEntry {
        ToolRegistryEntry(
            definition: ToolDefinition(name: name, description: "", parameters: [], type: .function),
            source: .local,
            effectClass: .readOnly,
            policyTags: tags
        )
    }

    private func context(
        toolName: String,
        entry: ToolRegistryEntry? = nil,
        vision: Bool,
        processor: ImageProcessing = OversizeReportingImageProcessor(),
        modelMaxImageEdgePx: Int? = nil
    ) throws -> ToolResultFormattingSpillContext {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tool-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ToolResultFormattingSpillContext(
            conversationID: UUID(),
            toolName: toolName,
            entry: entry,
            spillWriter: HarnessSessionPersistenceSpillWriter(
                persistence: try LocalHarnessSessionPersistence(root: root, agentId: "test-agent")
            ),
            modelSupportsVision: vision,
            imageProcessor: processor,
            modelMaxImageEdgePx: modelMaxImageEdgePx
        )
    }

    @Test("Rebuilding a result's text keeps its image parts, success, id, and error")
    func replacingTextKeepsImages() {
        let result = ToolResult(
            success: false,
            parts: [.text("a"), ToolImageFixtures.pngPart(), .text("b")],
            toolCallId: "call-9",
            error: "boom"
        )
        let rebuilt = result.replacingText("wrapped")
        #expect(rebuilt.content == "wrapped")
        #expect(rebuilt.images.count == 1)
        #expect(rebuilt.success == false)
        #expect(rebuilt.error == "boom")
        #expect(rebuilt.toolCallId == "call-9")
        let textOnly = ToolResult(success: true, content: "plain", toolCallId: "c").replacingText("new")
        #expect(textOnly.parts.isEmpty)
        #expect(textOnly.content == "new")
    }

    @Test("The external-content envelope wraps the text and keeps the image")
    func envelopeKeepsImages() {
        let call = ToolCall(name: "web_fetch", id: "call-1")
        let wrapped = ToolResultExternalContentMiddleware.apply(toolCall: call, result: ToolImageFixtures.imageResult(), entry: nil)
        #expect(ExternalContentEnvelope.isAlreadyWrapped(wrapped.content))
        #expect(wrapped.images.count == 1)
        #expect(wrapped.images.first?.data == ToolImageFixtures.tinyPNG)
    }

    @Test("Runtime formatting for a vision model keeps an in-cap image byte-for-byte")
    func visionKeepsImage() throws {
        let output = ToolResultFormattingStack.apply(
            result: ToolImageFixtures.imageResult(),
            stage: .runtime,
            configuration: .default,
            spillContext: try context(toolName: "chart_tool", vision: true, processor: DefaultImageProcessor())
        )
        #expect(output.images.first?.data == ToolImageFixtures.tinyPNG)
        #expect(output.images.first?.mediaType == "image/png")
        #expect(output.content == "observed")
    }

    @Test("A model without vision gets a text marker instead of the image")
    func noVisionStripsImage() throws {
        let output = ToolResultFormattingStack.apply(
            result: ToolImageFixtures.imageResult(),
            stage: .runtime,
            configuration: .default,
            spillContext: try context(toolName: "chart_tool", vision: false)
        )
        #expect(output.images.isEmpty)
        #expect(output.content.contains("observed"))
        #expect(output.content.contains(ToolResultFormattingConfiguration.default.imagePayloadPlaceholder))
    }

    @Test("Compaction always replaces images with the compaction marker")
    func compactionStripsImage() throws {
        let output = ToolResultFormattingStack.apply(
            result: ToolImageFixtures.imageResult(),
            stage: .compaction,
            configuration: .default,
            spillContext: try context(toolName: "chart_tool", vision: true)
        )
        #expect(output.images.isEmpty)
        #expect(output.content.contains(ToolResultFormattingConfiguration.default.compactionImagePayloadPlaceholder))
    }

    @Test("An oversized image from an ordinary tool is rescaled to the cap")
    func oversizedRescaled() throws {
        var config = ToolResultFormattingConfiguration.default
        config.maxInlineImagePixelDimension = 1
        let big = ToolResult(success: true, parts: [.text("x"), ToolImageFixtures.pngPart(width: 4000, height: 3000)], toolCallId: "c")
        let output = ToolResultFormattingStack.apply(
            result: big,
            stage: .runtime,
            configuration: config,
            spillContext: try context(toolName: "chart_tool", vision: true)
        )
        #expect(output.images.first?.data == OversizeReportingImageProcessor.rescaled)
        #expect(output.images.first?.width == nil)
    }

    @Test("A geometry-bound screenshot is never rescaled; over the cap it becomes a marker")
    func geometryBoundNotRescaled() throws {
        var config = ToolResultFormattingConfiguration.default
        config.maxInlineImagePixelDimension = 1
        let big = ToolResult(success: true, parts: [.text("x"), ToolImageFixtures.pngPart(width: 4000, height: 3000)], toolCallId: "c")
        let tagged = entry("host_screenshot", tags: [.geometryBoundImages])
        let byTag = ToolResultFormattingStack.apply(
            result: big,
            stage: .runtime,
            configuration: config,
            spillContext: try context(toolName: tagged.name, entry: tagged, vision: true)
        )
        #expect(byTag.images.isEmpty)
        #expect(byTag.content.contains(config.imagePayloadPlaceholder))
        #expect(!byTag.content.contains("rescaled"))

        let byName = ToolResultFormattingStack.apply(
            result: big,
            stage: .runtime,
            configuration: config,
            spillContext: try context(toolName: ComputerUseToolProvider.observeToolName, vision: true)
        )
        #expect(byName.images.isEmpty)
    }

    @Test("A geometry-bound screenshot is held to the bound model's edge cap, not the generic one")
    func geometryBoundUsesModelCap() throws {
        let screenshot = ToolResult(success: true, parts: [.text("x"), ToolImageFixtures.pngPart(width: 1568, height: 980)], toolCallId: "c")
        let withinModel = ToolResultFormattingStack.apply(
            result: screenshot,
            stage: .runtime,
            configuration: .default,
            spillContext: try context(toolName: ComputerUseToolProvider.observeToolName, vision: true, modelMaxImageEdgePx: 1568)
        )
        #expect(withinModel.images.first?.data == ToolImageFixtures.tinyPNG)

        let overModel = ToolResultFormattingStack.apply(
            result: screenshot,
            stage: .runtime,
            configuration: .default,
            spillContext: try context(toolName: ComputerUseToolProvider.observeToolName, vision: true, modelMaxImageEdgePx: 1024)
        )
        #expect(overModel.images.isEmpty)
    }

    @Test("Ordinary images are rescaled to the tighter of the model's cap and the configured cap")
    func ordinaryUsesTighterCap() throws {
        let image = ToolResult(success: true, parts: [.text("x"), ToolImageFixtures.pngPart(width: 1100, height: 800)], toolCallId: "c")
        let output = ToolResultFormattingStack.apply(
            result: image,
            stage: .runtime,
            configuration: .default,
            spillContext: try context(toolName: "chart_tool", vision: true, modelMaxImageEdgePx: 1024)
        )
        #expect(output.images.first?.data == OversizeReportingImageProcessor.rescaled)
        let generous = ToolResultFormattingStack.apply(
            result: image,
            stage: .runtime,
            configuration: .default,
            spillContext: try context(toolName: "chart_tool", vision: true, modelMaxImageEdgePx: 4000)
        )
        #expect(generous.images.first?.data == ToolImageFixtures.tinyPNG)
    }

    @Test("Image parts referenced by URL pass through untouched")
    func urlReferencePassesThrough() throws {
        let ref = ToolResult(
            success: true,
            parts: [.text("x"), .image(ToolResultImage(url: URL(string: "blob://abc")!, mediaType: "image/png"))],
            toolCallId: "c"
        )
        let output = ToolResultFormattingStack.apply(
            result: ref,
            stage: .persistence,
            configuration: .default,
            spillContext: try context(toolName: "chart_tool", vision: true)
        )
        #expect(output.images.first?.url?.absoluteString == "blob://abc")
    }

    @Test("A tool message and its result convert both ways without losing images")
    func messageRoundTrip() {
        let message = Message(
            id: UUID(),
            role: .tool,
            content: "observed",
            images: [Message.Image(name: "call-1-image-1", imageData: ToolImageFixtures.tinyPNG, mediaType: "image/png")],
            toolCallId: "call-1"
        )
        let result = ToolResult(toolMessage: message)
        #expect(result.content == "observed")
        #expect(result.images.map(\.mediaType) == ["image/png"])
        let back = message.replacingToolResult(result.replacingText("rewritten"))
        #expect(back.id == message.id)
        #expect(back.content == "rewritten")
        #expect(back.images.map(\.imageData) == [ToolImageFixtures.tinyPNG])
        #expect(back.images.map(\.mediaType) == ["image/png"])
    }

    @Test("Completed tool dispatches put image parts on the tool message; failures do not")
    func toolMessageCarriesImages() {
        let ok = AgentLoopToolDispatch.toolResultMessage(for: ToolImageFixtures.imageResult(), fallbackToolCallID: "x")
        #expect(ok.images.count == 1)
        #expect(ok.images.first?.mediaType == "image/png")
        #expect(ok.toolCallId == "call-1")
        let failed = AgentLoopToolDispatch.toolResultMessage(
            for: ToolResult(success: false, parts: [ToolImageFixtures.pngPart()], toolCallId: nil, error: "nope"),
            fallbackToolCallID: "x"
        )
        #expect(failed.images.isEmpty)
        #expect(failed.content == "nope")
        #expect(failed.toolCallId == "x")
    }
}
