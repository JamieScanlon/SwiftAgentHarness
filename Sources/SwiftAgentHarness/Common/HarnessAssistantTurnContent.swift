import Foundation
import SwiftAgentKit

public enum HarnessContentBlock: Sendable, Equatable {
    case text(String)
    case thinking(text: String, signature: String?)
    case toolUse(id: String?, name: String?)
}

public struct HarnessMessageEnvelope: Sendable {
    public var message: Message
    public var contentBlocks: [HarnessContentBlock]

    public init(message: Message, contentBlocks: [HarnessContentBlock] = []) {
        self.message = message
        self.contentBlocks = contentBlocks
    }

    public func flattenedMessage() -> Message {
        message
    }

    mutating func appendThinkingDelta(_ text: String, signature: String? = nil) {
        if case .thinking(let existing, let existingSignature)? = contentBlocks.last,
           signature == nil || signature == existingSignature {
            contentBlocks[contentBlocks.count - 1] = .thinking(
                text: existing + text,
                signature: existingSignature ?? signature
            )
        } else if !text.isEmpty || signature != nil {
            contentBlocks.append(.thinking(text: text, signature: signature))
        }
    }

    mutating func appendTextDelta(_ text: String) {
        guard !text.isEmpty else { return }
        if case .text(let existing)? = contentBlocks.last {
            contentBlocks[contentBlocks.count - 1] = .text(existing + text)
        } else {
            contentBlocks.append(.text(text))
        }
    }

    mutating func noteToolCallStarted(id: String?, name: String?) {
        contentBlocks.append(.toolUse(id: id, name: name))
    }

    static func fromTranscriptPayload(_ payload: MessageTranscriptPayload) -> HarnessMessageEnvelope {
        let message = payload.asMessage()
        let blocks = payload.decodedContentBlocks().map { wire in
            switch wire.kind {
            case .text:
                return HarnessContentBlock.text(wire.text ?? "")
            case .thinking:
                return HarnessContentBlock.thinking(text: wire.text ?? "", signature: wire.signature)
            case .toolUse:
                return HarnessContentBlock.toolUse(id: wire.toolCallId, name: wire.toolName)
            }
        }
        return HarnessMessageEnvelope(message: message, contentBlocks: blocks)
    }
}

/// Thread-safe in-memory store for assistant content blocks between finalize and dispatch/persistence.
/// Guarded by NSLock; writers and readers run on the same turn loop task in production.
private final class HarnessMessageEnvelopeStoreState: @unchecked Sendable {
    // NSLock provides the Sendable guarantee for this process-local envelope cache.
    private let lock = NSLock()
    private var byMessageID: [UUID: HarnessMessageEnvelope] = [:]

    func store(_ envelope: HarnessMessageEnvelope) {
        lock.lock()
        defer { lock.unlock() }
        byMessageID[envelope.message.id] = envelope
    }

    func envelope(for messageID: UUID) -> HarnessMessageEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        return byMessageID[messageID]
    }

    func envelopes(for messages: [Message]) -> [UUID: HarnessMessageEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        var result: [UUID: HarnessMessageEnvelope] = [:]
        for message in messages {
            if let envelope = byMessageID[message.id] {
                result[message.id] = envelope
            }
        }
        return result
    }

    func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        byMessageID.removeAll()
    }
}

enum HarnessMessageEnvelopeStore {
    private static let state = HarnessMessageEnvelopeStoreState()

    static func store(_ envelope: HarnessMessageEnvelope) {
        state.store(envelope)
    }

    static func envelope(for messageID: UUID) -> HarnessMessageEnvelope? {
        state.envelope(for: messageID)
    }

    static func envelopes(for messages: [Message]) -> [UUID: HarnessMessageEnvelope] {
        state.envelopes(for: messages)
    }

    static func resetForTesting() {
        state.resetForTesting()
    }
}
