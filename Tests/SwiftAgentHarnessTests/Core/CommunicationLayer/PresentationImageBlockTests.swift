import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Presentation image blocks")
struct PresentationImageBlockTests {
    private let image = PresentationImage(
        data: Data([0x89, 0x50, 0x4E, 0x47]),
        mediaType: "image/png",
        width: 240,
        height: 120,
        alt: "Target region: AXButton \"Send\" in com.apple.Mail"
    )

    private static var schemaURL: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appending(path: "openapi/schemas/ws/approval-presentation.schema.json")
    }

    @Test("An image block encodes with a type discriminator and base64 data, and round-trips")
    func encoding() throws {
        let data = try JSONEncoder().encode(ApprovalBlock.image(image))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "image")
        let encoded = try #require(object["image"] as? [String: Any])
        #expect(encoded["data"] as? String == image.data.base64EncodedString())
        #expect(encoded["mediaType"] as? String == "image/png")
        #expect(try JSONDecoder().decode(ApprovalBlock.self, from: data) == .image(image))
        #expect(try JSONDecoder().decode(MessageBlock.self, from: JSONEncoder().encode(MessageBlock.image(image))) == .image(image))
    }

    @Test("Text fallbacks carry the alt text, never the pixels")
    func textFallback() {
        let approval = ApprovalPresentation(blocks: [.text("Confirm?"), .image(image), .buttons(ApprovalButton.standardDecisionButtons())])
        #expect(approval.textFallback(approvalID: "a1").contains("[Image: \(image.alt)]"))
        let message = approval.asMessagePresentation()
        #expect(message.blocks.contains(.image(image)))
        #expect(message.textFallback().contains("[Image: \(image.alt)]"))
    }

    @Test("A surface without image support gets the alt text as context instead")
    func filterDegradesImages() {
        var capabilities = SurfacePresentationCapabilities.mockRich
        #expect(SurfacePresentationFilter.nativeBlocks(from: [.image(image)], capabilities: capabilities) == [.context("[Image: \(image.alt)]")])
        capabilities.images = true
        #expect(SurfacePresentationFilter.nativeBlocks(from: [.image(image)], capabilities: capabilities) == [.image(image)])
    }

    @Test("The approval presentation schema declares the image block")
    func schema() throws {
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.schemaURL)) as? [String: Any])
        let blocks = try #require((root["properties"] as? [String: Any])?["blocks"] as? [String: Any])
        let item = try #require(blocks["items"] as? [String: Any])
        let properties = try #require(item["properties"] as? [String: Any])
        let types = try #require((properties["type"] as? [String: Any])?["enum"] as? [String])
        #expect(types.contains("image"))
        let imageProperties = try #require((properties["image"] as? [String: Any])?["properties"] as? [String: Any])
        let encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(image)) as? [String: Any])
        #expect(Set(encoded.keys).isSubset(of: Set(imageProperties.keys)))
    }
}
