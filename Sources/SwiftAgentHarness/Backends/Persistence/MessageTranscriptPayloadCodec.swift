//
//  v2 harness message row payload for JSONL + catalog `payload_json`.
//

import Foundation
import EasyJSON
import SwiftAgentKit

struct MessageTranscriptAttachmentWire: Codable, Sendable, Equatable {
    var blobId: String
    var kind: String
    var name: String
    var mimeType: String?
    var trust: String?

    init(blobId: String, kind: String, name: String, mimeType: String? = nil, trust: String? = nil) {
        self.blobId = blobId.lowercased()
        self.kind = kind
        self.name = name
        self.mimeType = mimeType
        self.trust = trust
    }

    init(from image: Message.Image, trust: String?) {
        blobId = SessionBlobImageRef.parsePath(image.path) ?? ""
        kind = "image"
        name = image.name
        mimeType = nil
        self.trust = trust
    }

    func asMessageImage() -> Message.Image? {
        guard !blobId.isEmpty else { return nil }
        return Message.Image(name: name, path: SessionBlobImageRef.path(for: blobId))
    }
}

struct MessageTranscriptToolCallWire: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var argumentsJson: String
    var instructions: String?

    init(id: String, name: String, argumentsJson: String, instructions: String? = nil) {
        self.id = id
        self.name = name
        self.argumentsJson = argumentsJson
        self.instructions = instructions
    }

    init(from toolCall: ToolCall) {
        id = toolCall.id ?? UUID().uuidString
        name = toolCall.name
        if let data = try? JSONEncoder().encode(toolCall.arguments),
           let str = String(data: data, encoding: .utf8) {
            argumentsJson = str
        } else {
            argumentsJson = "{}"
        }
        instructions = toolCall.instructions
    }

    func asToolCall() -> ToolCall? {
        guard let data = argumentsJson.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSON.self, from: data)
        else {
            return ToolCall(name: name, arguments: .object([:]), instructions: instructions, id: id)
        }
        return ToolCall(name: name, arguments: json, instructions: instructions, id: id)
    }
}

struct MessageTranscriptContentBlockWire: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case text
        case thinking
        case toolUse
    }

    var kind: Kind
    var text: String?
    var signature: String?
    var toolCallId: String?
    var toolName: String?

    init(
        kind: Kind,
        text: String? = nil,
        signature: String? = nil,
        toolCallId: String? = nil,
        toolName: String? = nil
    ) {
        self.kind = kind
        self.text = text
        self.signature = signature
        self.toolCallId = toolCallId
        self.toolName = toolName
    }

    init(from block: HarnessContentBlock) {
        switch block {
        case .text(let text):
            kind = .text
            self.text = text
            signature = nil
            toolCallId = nil
            toolName = nil
        case .thinking(let text, let signature):
            kind = .thinking
            self.text = text
            self.signature = signature
            toolCallId = nil
            toolName = nil
        case .toolUse(let id, let name):
            kind = .toolUse
            text = nil
            signature = nil
            toolCallId = id
            toolName = name
        }
    }
}

struct MessageTranscriptPayload: Codable, Sendable, Equatable {
    static let currentVersion = 4

    var v: Int?
    var id: UUID
    var role: String
    var content: String
    var timestamp: Date
    var toolCallId: String?
    /// v1: tool names only.
    var toolCallNames: [String]?
    /// v2: full tool-call rows.
    var toolCalls: [MessageTranscriptToolCallWire]?
    /// v3: blob store refs (no bytes).
    var attachmentRefs: [MessageTranscriptAttachmentWire]?
    var transcriptRunID: UUID?
    var inputTrustRaw: String?
    var finishReason: String?
    var responseFormat: String?
    /// v4: structured assistant content blocks (thinking signatures, etc.).
    var contentBlocks: [MessageTranscriptContentBlockWire]?

    init(
        from message: Message,
        transcriptRunID: UUID? = nil,
        finishReason: String? = nil,
        contentBlocks: [HarnessContentBlock]? = nil
    ) {
        v = Self.currentVersion
        id = message.id
        role = message.role.rawValue
        content = message.content
        timestamp = message.timestamp
        toolCallId = message.toolCallId
        toolCallNames = nil
        toolCalls = message.toolCalls.isEmpty ? nil : message.toolCalls.map(MessageTranscriptToolCallWire.init(from:))
        let trust = message.role == .user ? MessageInputTrustCodec.sanitizedInputTrustRaw(message.inputTrustRaw) : nil
        let refs = message.images.compactMap { image -> MessageTranscriptAttachmentWire? in
            guard SessionBlobImageRef.parsePath(image.path) != nil else { return nil }
            return MessageTranscriptAttachmentWire(from: image, trust: trust)
        }
        attachmentRefs = refs.isEmpty ? nil : refs
        self.transcriptRunID = transcriptRunID
        inputTrustRaw = trust
        self.finishReason = finishReason
        responseFormat = message.responseFormat
        if let contentBlocks, !contentBlocks.isEmpty {
            self.contentBlocks = contentBlocks.map(MessageTranscriptContentBlockWire.init(from:))
        } else if !message.content.isEmpty {
            self.contentBlocks = [MessageTranscriptContentBlockWire(kind: .text, text: message.content)]
        } else {
            self.contentBlocks = nil
        }
    }

    init(from message: Message, transcriptRunID: UUID? = nil, finishReason: String? = nil) {
        self.init(from: message, transcriptRunID: transcriptRunID, finishReason: finishReason, contentBlocks: nil)
    }

    func resolvedToolCallNames() -> [String] {
        if let toolCalls, !toolCalls.isEmpty {
            return toolCalls.map(\.name)
        }
        return toolCallNames ?? []
    }

    func decodedToolCalls() -> [ToolCall] {
        if let toolCalls, !toolCalls.isEmpty {
            return toolCalls.compactMap { $0.asToolCall() }
        }
        return (toolCallNames ?? []).map { ToolCall(name: $0, arguments: .object([:])) }
    }

    func decodedAttachmentImages() -> [Message.Image] {
        guard let attachmentRefs, !attachmentRefs.isEmpty else { return [] }
        return attachmentRefs.compactMap { $0.asMessageImage() }
    }

    func decodedContentBlocks() -> [MessageTranscriptContentBlockWire] {
        if let contentBlocks, !contentBlocks.isEmpty {
            return contentBlocks
        }
        if !content.isEmpty {
            return [MessageTranscriptContentBlockWire(kind: .text, text: content)]
        }
        return []
    }

    func asMessage() -> Message {
        Message(
            id: id,
            role: MessageRole(rawValue: role) ?? .user,
            content: content,
            timestamp: timestamp,
            images: decodedAttachmentImages(),
            toolCalls: decodedToolCalls(),
            toolCallId: toolCallId,
            responseFormat: responseFormat,
            inputTrustRaw: inputTrustRaw
        )
    }

    var hasAttachmentRefs: Bool {
        guard let attachmentRefs, !attachmentRefs.isEmpty else { return false }
        return true
    }

    func hasRichToolCallDetail() -> Bool {
        guard let toolCalls, !toolCalls.isEmpty else { return false }
        return toolCalls.contains { wire in
            let trimmed = wire.argumentsJson.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed != "{}" && !trimmed.isEmpty
        }
    }

    var isThinPayload: Bool {
        (v ?? 1) < Self.currentVersion && !hasRichToolCallDetail()
    }
}

struct MessageTranscriptCatalogColumns: Sendable, Equatable {
    var toolCallId: String?
    var toolCallsJSON: String?
    var attachmentRefsJSON: String?
    var responseFormat: String?
    var finishReason: String?
}

enum MessageTranscriptPayloadCodec {
    static func enrichPayloadJSON(from message: Message, preserving payloadJSON: String) throws -> String {
        let old = try decode(payloadJSON)
        return try encodePayloadJSON(
            from: message,
            transcriptRunID: old.transcriptRunID,
            finishReason: old.finishReason
        )
    }

    static func encodePayloadJSON(
        from message: Message,
        transcriptRunID: UUID? = nil,
        finishReason: String? = nil,
        contentBlocks: [HarnessContentBlock]? = nil
    ) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let payload = MessageTranscriptPayload(
            from: message,
            transcriptRunID: transcriptRunID,
            finishReason: finishReason,
            contentBlocks: contentBlocks
        )
        let data = try enc.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "message payload encode failed")
        }
        try SessionTranscriptPayloadAllowlist.assertMessagePayloadKeysAllowed(json)
        return json
    }

    static func encodePayloadJSON(from message: Message, transcriptRunID: UUID? = nil, finishReason: String? = nil) throws -> String {
        try encodePayloadJSON(from: message, transcriptRunID: transcriptRunID, finishReason: finishReason, contentBlocks: nil)
    }

    static func decode(_ payloadJSON: String) throws -> MessageTranscriptPayload {
        guard let data = payloadJSON.data(using: .utf8) else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "message payload not utf-8")
        }
        do {
            return try JSONDecoder().decode(MessageTranscriptPayload.self, from: data)
        } catch {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "message payload decode failed")
        }
    }

    static func catalogColumns(for payloadJSON: String) -> MessageTranscriptCatalogColumns {
        guard let payload = try? decode(payloadJSON) else {
            return MessageTranscriptCatalogColumns(
                toolCallId: nil,
                toolCallsJSON: nil,
                attachmentRefsJSON: nil,
                responseFormat: nil,
                finishReason: nil
            )
        }
        let toolCallsJSON: String?
        if let toolCalls = payload.toolCalls, !toolCalls.isEmpty,
           let data = try? JSONEncoder().encode(toolCalls),
           let json = String(data: data, encoding: .utf8) {
            toolCallsJSON = json
        } else {
            toolCallsJSON = nil
        }
        let attachmentRefsJSON: String?
        if let attachmentRefs = payload.attachmentRefs, !attachmentRefs.isEmpty,
           let data = try? JSONEncoder().encode(attachmentRefs),
           let json = String(data: data, encoding: .utf8) {
            attachmentRefsJSON = json
        } else {
            attachmentRefsJSON = nil
        }
        return MessageTranscriptCatalogColumns(
            toolCallId: payload.toolCallId,
            toolCallsJSON: toolCallsJSON,
            attachmentRefsJSON: attachmentRefsJSON,
            responseFormat: payload.responseFormat,
            finishReason: payload.finishReason
        )
    }

}
