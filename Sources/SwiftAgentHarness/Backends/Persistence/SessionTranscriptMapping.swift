//
//  Map domain ``Message`` into harness-shaped ``SessionTranscriptEntry`` for v2 transcript.
//

import Foundation
import SwiftAgentKit

enum SessionTranscriptMapping {
    static func entry(
        from message: Message,
        sequence: Int,
        parentEntryId: SessionEntryID?,
        transcriptRunID: UUID? = nil,
        finishReason: String? = nil,
        attachmentIngestRefs: [AttachmentIngestRef]? = nil
    ) throws -> SessionTranscriptEntry {
        let roleType: SessionTranscriptEntryType = message.role == .system ? .system : .message
        let contentBlocks = HarnessMessageEnvelopeStore.envelope(for: message.id)?.contentBlocks
        let json = try MessageTranscriptPayloadCodec.encodePayloadJSON(
            from: message,
            transcriptRunID: transcriptRunID,
            finishReason: finishReason,
            contentBlocks: contentBlocks,
            attachmentIngestRefs: attachmentIngestRefs
        )
        return SessionTranscriptEntry(
            sequence: sequence,
            entryId: SessionEntryID.fromMessageUUID(message.id),
            parentEntryId: parentEntryId,
            type: roleType,
            timestamp: message.timestamp,
            payloadJSON: json
        )
    }

    static func inferFirstUserPromptIfNeeded(from entry: SessionTranscriptEntry) -> String? {
        guard entry.type == .message else { return nil }
        guard let obj = try? MessageTranscriptPayloadCodec.decode(entry.payloadJSON),
              obj.role == MessageRole.user.rawValue else { return nil }
        let t = obj.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Rebuild a ``Message`` for wire replay (`messagesRefresh`) from a transcript row.
    static func messageForReplay(from entry: SessionTranscriptEntry) throws -> Message? {
        guard entry.type == .message || entry.type == .system else { return nil }
        let obj = try MessageTranscriptPayloadCodec.decode(entry.payloadJSON)
        guard let role = MessageRole(rawValue: obj.role) else { return nil }
        let message = Message(
            id: obj.id,
            role: role,
            content: obj.content,
            timestamp: obj.timestamp,
            images: obj.decodedAttachmentImages(),
            toolCalls: obj.decodedToolCalls(),
            toolCallId: obj.toolCallId,
            responseFormat: obj.responseFormat,
            inputTrustRaw: obj.inputTrustRaw
        )
        let envelope = HarnessMessageEnvelope.fromTranscriptPayload(obj)
        if !envelope.contentBlocks.isEmpty {
            HarnessMessageEnvelopeStore.store(envelope)
        }
        return message
    }
}

/// FTS / README `messages.content`: searchable body for FTS5 (not raw `payload_json`).
enum SessionMessageContentExtractor: Sendable {
    static func ftsIndexedContent(for entry: SessionTranscriptEntry) -> String {
        switch entry.type {
        case .message, .system:
            guard let obj = try? MessageTranscriptPayloadCodec.decode(entry.payloadJSON) else { return "" }
            var pieces: [String] = []
            let body = obj.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { pieces.append(body) }
            let names = obj.resolvedToolCallNames().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !names.isEmpty { pieces.append(names.joined(separator: " ")) }
            return pieces.joined(separator: " ")
        default:
            return ""
        }
    }
}
