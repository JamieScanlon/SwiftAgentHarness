import Foundation

/// Tool-less, envelope-aware digest production for attachment bytes.
enum AttachmentDigestProducer {
    static func produce(
        descriptor: ConversationAttachmentDescriptor,
        bytes: Data,
        modelSupportsVision: Bool,
        configuration: AttachmentRepresentationMaterializerConfiguration
    ) -> String {
        let isImage = AttachmentRepresentationMaterializer.isImageDescriptor(descriptor)
        if isImage, !modelSupportsVision {
            var lines = ["image attached; active model cannot view images"]
            if let byteSize = descriptor.byteSize {
                lines.append("byte_size: \(byteSize)")
            }
            return lines.joined(separator: "\n")
        }
        let originalByteCount = bytes.count
        var previewLines = ["original_byte_count: \(originalByteCount)"]
        if isImage {
            previewLines.append("image attachment (\(originalByteCount) bytes)")
        } else if let text = AttachmentRepresentationMaterializer.utf8Text(
            from: bytes,
            mimeType: descriptor.mimeType,
            name: descriptor.name
        ) {
            previewLines.append("preview:")
            previewLines.append(
                AttachmentRepresentationMaterializer.textDigestPreview(
                    text: text,
                    originalByteCount: originalByteCount,
                    configuration: configuration
                )
            )
        } else {
            previewLines.append("binary attachment (\(originalByteCount) bytes)")
        }
        let previewBody = previewLines.joined(separator: "\n")
        return previewBody
    }
}
