import CryptoKit
import Foundation
import SwiftAgentKit

public struct AttachmentMaterializedBlock: Codable, Sendable, Equatable {
    public var attachmentID: UUID
    public var attachmentName: String
    public var disposition: ConversationAttachmentProjectionDisposition
    public var body: String

    public init(
        attachmentID: UUID,
        attachmentName: String,
        disposition: ConversationAttachmentProjectionDisposition,
        body: String
    ) {
        self.attachmentID = attachmentID
        self.attachmentName = attachmentName
        self.disposition = disposition
        self.body = body
    }
}

public struct AttachmentRepresentationMaterializerConfiguration: Sendable, Equatable {
    public var digestHeadMaxBytes: Int
    public var digestTailMaxBytes: Int
    public var inlineByteLimit: Int64

    public init(
        digestHeadMaxBytes: Int = 1_536,
        digestTailMaxBytes: Int = 512,
        inlineByteLimit: Int64 = 256_000
    ) {
        self.digestHeadMaxBytes = max(0, digestHeadMaxBytes)
        self.digestTailMaxBytes = max(0, digestTailMaxBytes)
        self.inlineByteLimit = max(0, inlineByteLimit)
    }

    public static let `default` = AttachmentRepresentationMaterializerConfiguration()
}

enum AttachmentRepresentationMaterializer {
    static func materialize(
        decisions: [ConversationAttachmentProjectionDecision],
        catalog: [ConversationAttachmentDescriptor],
        modelSupportsVision: Bool,
        blobReader: AttachmentBlobReading?,
        conversationID: UUID,
        configuration: AttachmentRepresentationMaterializerConfiguration = .default,
        digestPreviewByAttachmentID: [UUID: String] = [:]
    ) -> [AttachmentMaterializedBlock] {
        let catalogByID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        return decisions.compactMap { decision in
            guard let descriptor = catalogByID[decision.attachmentID] else { return nil }
            if decision.disposition == .inline, isImageDescriptor(descriptor) {
                return nil
            }
            let body = materializedBody(
                descriptor: descriptor,
                decision: decision,
                modelSupportsVision: modelSupportsVision,
                blobReader: blobReader,
                conversationID: conversationID,
                configuration: configuration,
                cachedDigestPreview: digestPreviewByAttachmentID[decision.attachmentID]
            )
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return AttachmentMaterializedBlock(
                attachmentID: decision.attachmentID,
                attachmentName: decision.attachmentName,
                disposition: decision.disposition,
                body: body
            )
        }
    }

    static func attachmentsSectionBody(blocks: [AttachmentMaterializedBlock]) -> String? {
        let bodies = blocks.map(\.body).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !bodies.isEmpty else { return nil }
        return bodies.joined(separator: "\n\n")
    }

    private static func materializedBody(
        descriptor: ConversationAttachmentDescriptor,
        decision: ConversationAttachmentProjectionDecision,
        modelSupportsVision: Bool,
        blobReader: AttachmentBlobReading?,
        conversationID: UUID,
        configuration: AttachmentRepresentationMaterializerConfiguration,
        cachedDigestPreview: String? = nil
    ) -> String {
        switch decision.disposition {
        case .inline:
            return wrapWithRecovery(
                descriptor: descriptor,
                core: inlineCore(
                    descriptor: descriptor,
                    blobReader: blobReader,
                    conversationID: conversationID,
                    configuration: configuration
                ),
                blobReader: blobReader,
                conversationID: conversationID,
                includeRecovery: false
            )
        case .searchOnly:
            return wrapWithRecovery(
                descriptor: descriptor,
                core: referenceCore(descriptor: descriptor, decision: decision),
                blobReader: blobReader,
                conversationID: conversationID
            )
        case .summarize:
            return wrapWithRecovery(
                descriptor: descriptor,
                core: digestCore(
                    descriptor: descriptor,
                    decision: decision,
                    modelSupportsVision: modelSupportsVision,
                    blobReader: blobReader,
                    conversationID: conversationID,
                    configuration: configuration,
                    cachedDigestPreview: cachedDigestPreview
                ),
                blobReader: blobReader,
                conversationID: conversationID
            )
        }
    }

    private static func inlineCore(
        descriptor: ConversationAttachmentDescriptor,
        blobReader: AttachmentBlobReading?,
        conversationID: UUID,
        configuration: AttachmentRepresentationMaterializerConfiguration
    ) -> String {
        var lines = ["[attachment inline]"]
        lines.append("name: \(displayName(descriptor))")
        lines.append("kind: \(descriptor.kind)")
        if let mimeType = descriptor.mimeType, !mimeType.isEmpty {
            lines.append("mime_type: \(mimeType)")
        }
        lines.append("attachment_id: \(descriptor.id.uuidString)")
        guard let bytes = loadBytes(descriptor: descriptor, blobReader: blobReader, conversationID: conversationID) else {
            lines.append(SessionBlobMessageHydration.unavailableMarker(name: descriptor.name))
            return lines.joined(separator: "\n")
        }
        let originalByteCount = bytes.count
        lines.append("original_byte_count: \(originalByteCount)")
        if let text = utf8Text(from: bytes, mimeType: descriptor.mimeType, name: descriptor.name) {
            lines.append("content:")
            lines.append(inlineTextContent(text: text, inlineByteLimit: configuration.inlineByteLimit))
        } else {
            lines.append("binary attachment (\(originalByteCount) bytes)")
        }
        return lines.joined(separator: "\n")
    }

    private static func referenceCore(
        descriptor: ConversationAttachmentDescriptor,
        decision: ConversationAttachmentProjectionDecision
    ) -> String {
        var lines = ["[attachment reference]"]
        lines.append("name: \(displayName(descriptor))")
        lines.append("kind: \(descriptor.kind)")
        if let mimeType = descriptor.mimeType, !mimeType.isEmpty {
            lines.append("mime_type: \(mimeType)")
        }
        if let byteSize = descriptor.byteSize {
            lines.append("byte_size: \(byteSize)")
        }
        lines.append("attachment_id: \(descriptor.id.uuidString)")
        if !decision.reason.isEmpty {
            lines.append("reason: \(decision.reason)")
        }
        return lines.joined(separator: "\n")
    }

    private static func digestCore(
        descriptor: ConversationAttachmentDescriptor,
        decision: ConversationAttachmentProjectionDecision,
        modelSupportsVision: Bool,
        blobReader: AttachmentBlobReading?,
        conversationID: UUID,
        configuration: AttachmentRepresentationMaterializerConfiguration,
        cachedDigestPreview: String? = nil
    ) -> String {
        var lines = ["[attachment digest]"]
        lines.append("name: \(displayName(descriptor))")
        lines.append("kind: \(descriptor.kind)")
        if let mimeType = descriptor.mimeType, !mimeType.isEmpty {
            lines.append("mime_type: \(mimeType)")
        }
        if !decision.reason.isEmpty {
            lines.append("reason: \(decision.reason)")
        }
        let isImage = isImageDescriptor(descriptor)
        if isImage, !modelSupportsVision {
            lines.append("image attached; active model cannot view images")
            if let byteSize = descriptor.byteSize {
                lines.append("byte_size: \(byteSize)")
            }
            return lines.joined(separator: "\n")
        }
        guard let bytes = loadBytes(descriptor: descriptor, blobReader: blobReader, conversationID: conversationID) else {
            lines.append(SessionBlobMessageHydration.unavailableMarker(name: descriptor.name))
            return lines.joined(separator: "\n")
        }
        let preview: String
        if let cachedDigestPreview, !cachedDigestPreview.isEmpty {
            preview = cachedDigestPreview
        } else {
            preview = AttachmentDigestProducer.produce(
                descriptor: descriptor,
                bytes: bytes,
                modelSupportsVision: modelSupportsVision,
                configuration: configuration
            )
        }
        lines.append(preview)
        return lines.joined(separator: "\n")
    }

    private static func wrapWithRecovery(
        descriptor: ConversationAttachmentDescriptor,
        core: String,
        blobReader: AttachmentBlobReading?,
        conversationID: UUID,
        includeRecovery: Bool = true
    ) -> String {
        let combined: String
        if includeRecovery {
            let recovery = recoveryFooter(descriptor: descriptor, blobReader: blobReader, conversationID: conversationID)
            combined = core + "\n" + recovery
        } else {
            combined = core
        }
        return AttachmentProvenancePolicy.wrapIfRequired(descriptor: descriptor, content: combined)
    }

    private static func recoveryFooter(
        descriptor: ConversationAttachmentDescriptor,
        blobReader: AttachmentBlobReading?,
        conversationID: UUID
    ) -> String {
        var lines = [
            "attachment_id: \(descriptor.id.uuidString)",
        ]
        if let blobId = descriptor.blobId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !blobId.isEmpty {
            lines.append("blob_id: \(blobId)")
        }
        _ = conversationID
        _ = blobReader
        lines.append(
            "Use read_attachment with attachment_id \(descriptor.id.uuidString) and optional offset/limit to read more."
        )
        return lines.joined(separator: "\n")
    }

    private static func loadBytes(
        descriptor: ConversationAttachmentDescriptor,
        blobReader: AttachmentBlobReading?,
        conversationID: UUID
    ) -> Data? {
        guard let blobId = descriptor.blobId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !blobId.isEmpty,
              let blobReader else {
            return nil
        }
        do {
            return try blobReader.loadBytes(blobId, conversationID)
        } catch {
            return nil
        }
    }

    private static func inlineTextContent(text: String, inlineByteLimit: Int64) -> String {
        let limit = Int(inlineByteLimit)
        guard limit > 0, text.utf8.count > limit else { return text }
        return ToolResultSpillEnvelope.previewPrefix(for: text, maxBytes: limit)
            + "\n… [\(text.utf8.count - limit) bytes truncated for inline budget] …"
    }

    private static func displayName(_ descriptor: ConversationAttachmentDescriptor) -> String {
        AttachmentProvenancePolicy.sanitizedAttachmentName(descriptor.name)
    }

    static func textDigestPreview(
        text: String,
        originalByteCount: Int,
        configuration: AttachmentRepresentationMaterializerConfiguration
    ) -> String {
        let headMax = configuration.digestHeadMaxBytes
        let tailMax = configuration.digestTailMaxBytes
        let utf8Count = text.utf8.count
        if utf8Count <= headMax + tailMax || headMax + tailMax == 0 {
            return text
        }
        let head = ToolResultSpillEnvelope.previewPrefix(for: text, maxBytes: headMax)
        let tail = utf8SuffixPreview(text, maxBytes: tailMax)
        let elided = max(0, originalByteCount - head.utf8.count - tail.utf8.count)
        return "\(head)\n… [\(elided) bytes elided] …\n\(tail)"
    }

    private static func utf8SuffixPreview(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        let data = Data(text.utf8)
        guard data.count > maxBytes else { return text }
        var cutoff = maxBytes
        while cutoff > 0 {
            let suffix = data.suffix(cutoff)
            if let decoded = String(data: suffix, encoding: .utf8) {
                return decoded
            }
            cutoff -= 1
        }
        return ""
    }

    static func utf8Text(from bytes: Data, mimeType: String?, name: String) -> String? {
        if isTextLike(mimeType: mimeType, name: name),
           let decoded = String(data: bytes, encoding: .utf8) {
            return decoded
        }
        if String(data: bytes, encoding: .utf8) != nil,
           bytes.count <= 64_000,
           !bytes.contains(0) {
            return String(data: bytes, encoding: .utf8)
        }
        return nil
    }

    private static func isTextLike(mimeType: String?, name: String) -> Bool {
        if let mimeType {
            let lowered = mimeType.lowercased()
            if lowered.hasPrefix("text/") || lowered == "application/json" || lowered == "application/xml" {
                return true
            }
        }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["txt", "md", "json", "csv", "swift", "py", "js", "ts", "yaml", "yml", "xml", "html", "htm", "log"]
            .contains(ext)
    }

    static func isImageDescriptor(_ descriptor: ConversationAttachmentDescriptor) -> Bool {
        let normalizedKind = descriptor.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedKind == "image" { return true }
        return descriptor.mimeType?.lowercased().hasPrefix("image/") == true
    }
}
