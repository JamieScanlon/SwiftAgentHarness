import EasyJSON
import Foundation
import SwiftAgentKit

extension ToolResult {
    /// The same result with new text. Image parts are kept, after the text, so a middleware that rewrites
    /// `content` never silently drops what the tool returned.
    func replacingText(_ content: String, metadata: JSON? = nil) -> ToolResult {
        let images = self.images
        guard !images.isEmpty else {
            return ToolResult(
                success: success,
                content: content,
                metadata: metadata ?? self.metadata,
                toolCallId: toolCallId,
                error: error
            )
        }
        return replacingParts([.text(content)] + images.map { .image($0) }, metadata: metadata)
    }

    func replacingParts(_ parts: [ToolResultContentPart], metadata: JSON? = nil) -> ToolResult {
        ToolResult(success: success, parts: parts, metadata: metadata ?? self.metadata, toolCallId: toolCallId, error: error)
    }

    /// A tool-role message read back as a result, its images as image parts.
    init(toolMessage message: Message, success: Bool = true) {
        guard !message.images.isEmpty else {
            self.init(success: success, content: message.content, metadata: .object([:]), toolCallId: message.toolCallId)
            return
        }
        self.init(
            success: success,
            parts: [.text(message.content)] + message.images.map { .image(ToolResultImage(messageImage: $0)) },
            metadata: .object([:]),
            toolCallId: message.toolCallId
        )
    }
}

extension ToolResultImage {
    init(messageImage image: Message.Image) {
        self.init(
            data: image.imageData,
            url: image.path.flatMap(Self.referenceURL),
            mediaType: image.mediaType ?? image.imageData.map { SessionBlobMIME.sniff(data: $0, hint: nil) } ?? "image/png"
        )
    }

    private static func referenceURL(_ path: String) -> URL? {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return URL(string: path)
    }
}

extension Message {
    /// This tool message with the result's text and images.
    func replacingToolResult(_ result: ToolResult) -> Message {
        var copy = self
        copy.content = result.content
        copy.images = result.messageImages
        return copy
    }
}
