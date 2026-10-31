import CoreGraphics
import EasyJSON
import Foundation
import ImageIO
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use: labeled screenshots")
struct ComputerUseScreenshotLabelTests {
    private typealias Labels = ComputerUseScreenshotLabels

    private func observation(elements: [String: ElementRef] = ComputerUseFixtures.elements(), image: Data? = nil) throws -> DisplayObservation {
        var observation = ComputerUseFixtures.observation(id: "o_1")
        observation.image?.data = try image ?? ComputerUseFixtures.pngScreenshot()
        observation.tree?.elements = elements
        return observation
    }

    /// RGBA of one pixel, top-left origin.
    private func pixel(_ data: Data, x: Int, y: Int) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return bytes
    }

    @Test("Tags go on located, on-screen elements smaller than a container, in image pixels")
    func tagSelection() throws {
        let tags = Labels.tags(for: try observation())
        // The text area covers most of the screen and e1, e7, e8, e9 have no frame.
        #expect(tags.map(\.ref).sorted() == ["e2", "e6"])
        let bold = try #require(tags.first { $0.ref == "e2" })
        // 1440×900 points map to 1280×800 pixels.
        #expect(abs(bold.element.x - 8.89) < 0.01 && abs(bold.element.width - 26.67) < 0.01)
        for tag in tags {
            #expect(tag.label.minX >= 0 && tag.label.minY >= 0 && tag.label.maxX <= 1280 && tag.label.maxY <= 800, "\(tag)")
        }
    }

    @Test("Elements off the screenshot or too small to see get no tag, and colliding tags keep the smaller element")
    func collisionsAndBounds() throws {
        let elements: [String: ElementRef] = [
            "e1": ElementRef(id: "e1", role: "AXButton", frame: DisplayRect(x: 100, y: 100, width: 60, height: 30)),
            "e2": ElementRef(id: "e2", role: "AXButton", frame: DisplayRect(x: 101, y: 101, width: 40, height: 20)),
            "e3": ElementRef(id: "e3", role: "AXButton", frame: DisplayRect(x: 2000, y: 2000, width: 40, height: 20)),
            "e4": ElementRef(id: "e4", role: "AXButton", frame: DisplayRect(x: 500, y: 500, width: 1, height: 1)),
            "e5": ElementRef(id: "e5", role: "AXButton", frame: DisplayRect(x: 700, y: 300, width: 40, height: 20)),
        ]
        #expect(Labels.tags(for: try observation(elements: elements)).map(\.ref).sorted() == ["e2", "e5"])
    }

    @Test("The labeled screenshot keeps the size the geometry records and draws only near tagged elements")
    func drawing() throws {
        let raw = try observation()
        let labeled = try #require(Labels.labeled(raw))
        #expect(labeled.width == 1280 && labeled.height == 800)
        #expect(labeled.mediaType == "image/png")
        let original = try pixel(try #require(raw.image?.data), x: 640, y: 400)
        let drawn = try #require(labeled.data)
        #expect(try pixel(drawn, x: 640, y: 400) == original)
        let tag = try #require(Labels.tags(for: raw).first { $0.ref == "e6" })
        #expect(try pixel(drawn, x: Int(tag.label.center.x), y: Int(tag.label.center.y)) != original)
    }

    @Test("No tags are drawn when the bitmap doesn't match the recorded geometry or nothing is taggable")
    func untouched() throws {
        #expect(Labels.labeled(try observation(image: ToolImageFixtures.tinyPNG)) == nil)
        #expect(Labels.labeled(try observation(elements: [:])) == nil)
    }

    private func provider(labels: Bool) async throws -> (FakeDisplayTarget, ComputerUseToolProvider) {
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
        var configuration = ComputerUseSessionConfiguration(task: ComputerUseTaskContext(userRequest: ["Bold the title."]))
        configuration.labelsScreenshots = labels
        let session = ComputerUseSession(target: target, lease: lease, configuration: configuration, now: { ComputerUseFixtures.epoch })
        return (target, ComputerUseToolProvider(session: session))
    }

    private func image(of result: ToolResult) -> ToolResultImage? {
        result.parts.lazy.compactMap { if case .image(let image) = $0 { image } else { nil } }.first
    }

    @Test("Observe results carry the labeled screenshot and say what the tags are; the setting turns them off")
    func observeResults() async throws {
        let raw = try ComputerUseFixtures.pngScreenshot()
        let (_, labeled) = try await provider(labels: true)
        let result = try await labeled.executeTool(ToolCall(name: ComputerUseToolProvider.observeToolName, arguments: .object([:]), id: "c1"))
        #expect(try #require(image(of: result)).data != raw)
        #expect(result.content.contains(ComputerUseToolProvider.screenshotTagsNote))

        let screenshotOnly = try await labeled.executeTool(ToolCall(
            name: ComputerUseToolProvider.observeToolName,
            arguments: .object(["include_tree": .boolean(false)]),
            id: "c2"
        ))
        #expect(try #require(image(of: screenshotOnly)).data == raw)
        #expect(!screenshotOnly.content.contains(ComputerUseToolProvider.screenshotTagsNote))

        let (_, plain) = try await provider(labels: false)
        let unlabeled = try await plain.executeTool(ToolCall(name: ComputerUseToolProvider.observeToolName, arguments: .object([:]), id: "c3"))
        #expect(try #require(image(of: unlabeled)).data == raw)
        #expect(!unlabeled.content.contains(ComputerUseToolProvider.screenshotTagsNote))
    }
}
