import Foundation
import SwiftAgentKit

/// Anthropic Messages API image content blocks from projected `Message.images`.
enum AnthropicVisionContent {
    /// Builds Anthropic `{ type: image, source: { type: base64, … } }` blocks for
    /// images eligible via ``OpenAICompatibleVisionContent/inlineImagesWithData(from:dispositions:)``.
    static func imageContentBlocks(
        from images: [Message.Image],
        dispositions: [String: String]
    ) -> [[String: Any]] {
        let visionImages = OpenAICompatibleVisionContent.inlineImagesWithData(
            from: images,
            dispositions: dispositions
        )
        return visionImages.compactMap { image in
            guard let data = image.imageData else { return nil }
            let mediaType = SessionBlobMIME.sniff(data: data, hint: nil)
            return [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": mediaType,
                    "data": data.base64EncodedString(),
                ] as [String: Any],
            ]
        }
    }
}
