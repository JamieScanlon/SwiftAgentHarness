import Foundation
import SwiftAgentKit

/// Shared helpers for OpenAI-compatible / LM Studio chat adapters that emit
/// multimodal `image_url` content parts from projected `Message.images`.
enum OpenAICompatibleVisionContent {
    /// Images eligible for wire multimodal parts: disposition missing or `inline`,
    /// and `imageData` present (matches Ollama’s `compactMap(\.base64EncodedImage)`).
    static func inlineImagesWithData(
        from images: [Message.Image],
        dispositions: [String: String]
    ) -> [Message.Image] {
        images.filter { image in
            guard image.imageData != nil else { return false }
            guard let disposition = dispositions[image.name] else { return true }
            return disposition == ConversationAttachmentProjectionDisposition.inline.rawValue
        }
    }

    /// `data:<mime>;base64,…` URL using sniffed MIME (not hard-coded JPEG).
    static func dataURL(for imageData: Data) -> String {
        let mime = SessionBlobMIME.sniff(data: imageData, hint: nil)
        return "data:\(mime);base64,\(imageData.base64EncodedString())"
    }
}
