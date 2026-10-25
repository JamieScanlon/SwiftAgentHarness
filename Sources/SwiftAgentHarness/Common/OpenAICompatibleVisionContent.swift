import Foundation
import Logging
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

    /// `data:` URL using the image's declared media type, sniffed only when it has none.
    static func dataURL(for image: Message.Image) -> String? {
        guard let data = image.imageData else { return nil }
        let mime = image.mediaType ?? SessionBlobMIME.sniff(data: data, hint: nil)
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    /// Chat-completions tool messages carry text only, so the images a run of tool messages returned travel in one
    /// user message placed right after the run (never between tool messages, which must follow their assistant
    /// message contiguously).
    struct ToolImageCarrier {
        private(set) var pending: [(toolCallID: String, image: Message.Image)] = []

        mutating func collect(_ message: Message, dispositions: [String: String]) {
            guard message.role == .tool else { return }
            let id = message.toolCallId ?? "unknown"
            for image in OpenAICompatibleVisionContent.inlineImagesWithData(from: message.images, dispositions: dispositions) {
                pending.append((id, image))
            }
        }

        /// The carrier's text and image data URLs, or `nil` when nothing is pending. Clears the pending images.
        mutating func flush() -> (text: String, imageURLs: [String])? {
            guard !pending.isEmpty else { return nil }
            var ids: [String] = []
            for entry in pending where !ids.contains(entry.toolCallID) { ids.append(entry.toolCallID) }
            let urls = pending.compactMap { OpenAICompatibleVisionContent.dataURL(for: $0.image) }
            pending = []
            return ("Images returned by tool call\(ids.count == 1 ? "" : "s") \(ids.joined(separator: ", ")):", urls)
        }
    }

    /// Compact wire diagnostics (no base64) for vision encode path debugging.
    static func logWireDiagnostics(
        adapter: String,
        messages: [Message],
        dispositions: [String: String],
        encodedImageURLPartCount: Int,
        logger: Logger?
    ) {
        guard let logger else { return }
        let imageCount = messages.reduce(0) { $0 + $1.images.count }
        guard imageCount > 0 || encodedImageURLPartCount > 0 else { return }
        let withData = messages.reduce(0) { partial, message in
            partial + message.images.filter { $0.imageData != nil }.count
        }
        let nonInline = dispositions
            .filter { $0.value != ConversationAttachmentProjectionDisposition.inline.rawValue }
            .map { "\($0.key):\($0.value)" }
            .sorted()
            .joined(separator: ",")
        let nonInlineSuffix = nonInline.isEmpty ? "" : " nonInlineDispositions=[\(nonInline)]"
        logger.debug(
            "[\(adapter)] Vision wire: inputImages=\(imageCount) withImageData=\(withData) encodedImageURLParts=\(encodedImageURLPartCount)\(nonInlineSuffix)"
        )
    }
}
