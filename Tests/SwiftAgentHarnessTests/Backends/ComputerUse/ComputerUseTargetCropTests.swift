import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SwiftAgentHarness

@Suite("Computer use approval-card target crops")
struct ComputerUseTargetCropTests {
    /// A screenshot sized as the fixture geometry says (1280×800 for a 1440×900 pt capture).
    private static func screenshot(width: Int = 1280, height: Int = 800) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func size(of data: Data) throws -> (Int, Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    private func observation(imageData: Data?) -> DisplayObservation {
        var observation = ComputerUseFixtures.observation(id: "o_1")
        observation.image?.data = imageData
        return observation
    }

    @Test("An element target crops its padded frame from the screenshot")
    func elementCrop() throws {
        let observation = observation(imageData: try Self.screenshot())
        let action = ComputerAction.click(at: .ref("e6", observation: "o_1"))
        let region = try #require(ComputerUseTargetCrop.region(for: action, in: observation))
        // The Save button (1300, 860, 80×24) grows to the minimum crop and stays inside the 1440×900 capture.
        #expect(region.width >= ComputerUseTargetCrop.minimumRegion.width)
        #expect(region.maxX <= 1440 && region.maxY <= 900)
        #expect(region.contains(DisplayPoint(x: 1340, y: 872)))

        let image = try #require(ComputerUseTargetCrop.image(of: region, in: observation, alt: "Save button"))
        #expect(image.mediaType == "image/png")
        #expect(image.alt == "Save button")
        let (width, height) = try Self.size(of: image.data)
        #expect((width, height) == (image.width, image.height))
        #expect(max(width, height) <= ComputerUseTargetCrop.maximumEdgePx)
        // 1280 px across 1440 pt: the crop keeps the screenshot's scale.
        #expect(abs(Double(width) - region.width * 1280 / 1440) <= 2)
    }

    @Test("A point target crops a box around the point")
    func pointCrop() throws {
        let observation = observation(imageData: try Self.screenshot())
        let action = ComputerAction.click(at: .point(DisplayPoint(x: 720, y: 450), observation: "o_1"))
        let region = try #require(ComputerUseTargetCrop.region(for: action, in: observation))
        #expect(region.center == DisplayPoint(x: 720, y: 450))
        #expect(region.width == ComputerUseTargetCrop.minimumRegion.width)
    }

    @Test("Actions without a located target, and observations without pixels, get no crop")
    func noCrop() throws {
        let withPixels = observation(imageData: try Self.screenshot())
        #expect(ComputerUseTargetCrop.region(for: .key(combo: KeyCombo(modifiers: [], key: "return")), in: withPixels) == nil)
        // e7 has no frame.
        #expect(ComputerUseTargetCrop.region(for: .click(at: .ref("e7", observation: "o_1")), in: withPixels) == nil)

        let withoutPixels = observation(imageData: nil)
        let region = DisplayRect(x: 0, y: 0, width: 200, height: 100)
        #expect(ComputerUseTargetCrop.image(of: region, in: withoutPixels, alt: "x") == nil)
    }

    @Test("A consequential action's approval card carries the crop above its buttons")
    func approvalCard() async throws {
        let approvals = RecordingComputerUseApprovals(.denied("no"))
        let (target, session) = try await ComputerUseSessionFixtures.make(approvals: approvals)
        await target.setScreenshot(try Self.screenshot())
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        _ = await session.perform([.click(at: .ref("e6", observation: "o_1"))])
        let request = try #require(await approvals.requests.first)
        let blocks = request.presentation.blocks
        guard let imageIndex = blocks.firstIndex(where: { if case .image = $0 { true } else { false } }),
              let buttonsIndex = blocks.firstIndex(where: { if case .buttons = $0 { true } else { false } })
        else {
            Issue.record("expected an image block and a buttons block: \(blocks)")
            return
        }
        #expect(imageIndex < buttonsIndex)
        if case .image(let image) = blocks[imageIndex] {
            #expect(image.alt.contains("AXButton \"Save\""))
        }
    }
}
