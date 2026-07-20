import Foundation

enum DocumentHygieneReceiptEnvelope {
    static let originalByteCountKey = "original_byte_count:"
    static let messageIDKey = "message_id:"
    static let previewKey = "preview:"

    static func isReceiptEnvelope(_ content: String, marker: String) -> Bool {
        let trimmedMarker = marker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMarker.isEmpty else { return false }
        return content.contains(trimmedMarker)
            && content.contains(originalByteCountKey)
            && content.contains(messageIDKey)
    }

    static func make(
        originalContent: String,
        messageID: UUID,
        marker: String,
        previewMaxBytes: Int
    ) -> String {
        let originalByteCount = Data(originalContent.utf8).count
        let preview = previewBody(from: originalContent, previewMaxBytes: previewMaxBytes)
        return """
        \(marker)
        \(previewKey)
        \(preview)
        \(originalByteCountKey) \(originalByteCount)
        \(messageIDKey) \(messageID.uuidString)
        Full content is retained in conversation history at message_id \(messageID.uuidString).
        """
    }

    private static func previewBody(from content: String, previewMaxBytes: Int) -> String {
        guard previewMaxBytes > 0 else {
            return "… [\(Data(content.utf8).count) bytes elided] …"
        }
        let originalByteCount = Data(content.utf8).count
        guard originalByteCount > previewMaxBytes else { return content }
        let prefix = ToolResultSpillEnvelope.previewPrefix(for: content, maxBytes: previewMaxBytes)
        let elided = max(0, originalByteCount - prefix.utf8.count)
        return "\(prefix)\n… [\(elided) bytes elided] …"
    }
}
