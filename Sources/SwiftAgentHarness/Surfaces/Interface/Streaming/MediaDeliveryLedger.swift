import Foundation

/// Reference to media delivered during a turn (blob id or stable name).
public struct StreamingMediaRef: Sendable, Hashable, Equatable, Codable {
    public var id: String
    public var kind: String
    public var mimeType: String?

    public init(id: String, kind: String = "attachment", mimeType: String? = nil) {
        self.id = id
        self.kind = kind
        self.mimeType = mimeType
    }
}

/// Final outbound payload after media deduplication.
public struct StreamingFinalPayload: Sendable, Equatable {
    public var text: String
    public var media: [StreamingMediaRef]

    public init(text: String, media: [StreamingMediaRef] = []) {
        self.text = text
        self.media = media
    }
}

/// Remembers per-turn media deliveries and strips duplicates from the final send.
public struct MediaDeliveryLedger: Sendable {
    private var delivered: Set<StreamingMediaRef> = []
    private var deliveredExactPayloads: Set<String> = []

    public init() {}

    public mutating func recordBlock(_ text: String, media: [StreamingMediaRef] = []) {
        if !text.isEmpty {
            deliveredExactPayloads.insert(normalized(text))
        }
        for ref in media {
            delivered.insert(ref)
        }
    }

    public mutating func recordMedia(_ refs: [StreamingMediaRef]) {
        for ref in refs {
            delivered.insert(ref)
        }
    }

    /// Strips media already streamed and suppresses exact-duplicate final payloads.
    public mutating func prepareFinal(_ payload: StreamingFinalPayload) -> StreamingFinalPayload? {
        let normalizedText = normalized(payload.text)
        let newMedia = payload.media.filter { !delivered.contains($0) }
        let mediaChanged = newMedia.count != payload.media.count

        if deliveredExactPayloads.contains(normalizedText) && !mediaChanged {
            return nil
        }

        for ref in payload.media {
            delivered.insert(ref)
        }
        if !normalizedText.isEmpty {
            deliveredExactPayloads.insert(normalizedText)
        }

        return StreamingFinalPayload(text: payload.text, media: newMedia)
    }

    public mutating func reset() {
        delivered = []
        deliveredExactPayloads = []
    }

    private func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
