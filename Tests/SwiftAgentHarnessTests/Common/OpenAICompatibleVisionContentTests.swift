import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("OpenAICompatibleVisionContent")
struct OpenAICompatibleVisionContentTests {
    private let tinyPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    @Test("keeps images with data when disposition is missing or inline")
    func keepsInlineAndMissingDisposition() {
        let images = [
            Message.Image(name: "a.png", imageData: tinyPNG),
            Message.Image(name: "b.png", imageData: tinyPNG),
            Message.Image(name: "c.png", imageData: tinyPNG),
        ]
        let dispositions = [
            "b.png": ConversationAttachmentProjectionDisposition.inline.rawValue,
            "c.png": ConversationAttachmentProjectionDisposition.summarize.rawValue,
        ]
        let kept = OpenAICompatibleVisionContent.inlineImagesWithData(from: images, dispositions: dispositions)
        #expect(kept.map(\.name) == ["a.png", "b.png"])
    }

    @Test("excludes images without imageData even when inline")
    func excludesNameOnlyInline() {
        let images = [
            Message.Image(name: "ref.png", path: "blob://abc"),
            Message.Image(name: "full.png", imageData: tinyPNG),
        ]
        let dispositions = [
            "ref.png": ConversationAttachmentProjectionDisposition.inline.rawValue,
            "full.png": ConversationAttachmentProjectionDisposition.inline.rawValue,
        ]
        let kept = OpenAICompatibleVisionContent.inlineImagesWithData(from: images, dispositions: dispositions)
        #expect(kept.map(\.name) == ["full.png"])
    }

    @Test("dataURL sniffs PNG mime type")
    func dataURLSniffsPNG() {
        let url = OpenAICompatibleVisionContent.dataURL(for: tinyPNG)
        #expect(url.hasPrefix("data:image/png;base64,"))
        #expect(url.contains(tinyPNG.base64EncodedString()))
    }
}
