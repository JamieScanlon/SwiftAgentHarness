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
    private var deliveredCollapsed = ""
    private var deliveredMessageIDs: Set<UUID> = []

    public init() {}

    public mutating func recordBlock(_ text: String, media: [StreamingMediaRef] = []) {
        if !text.isEmpty {
            deliveredExactPayloads.insert(normalized(text))
            deliveredCollapsed += collapsed(text)
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

    public mutating func recordDeliveredMessageID(_ id: UUID) {
        deliveredMessageIDs.insert(id)
    }

    public mutating func recordDeliveredMessageIDs(_ ids: [UUID]) {
        for id in ids {
            deliveredMessageIDs.insert(id)
        }
    }

    public func hasDeliveredMessageID(_ id: UUID) -> Bool {
        deliveredMessageIDs.contains(id)
    }

    /// Strips media already streamed and suppresses exact-duplicate final payloads.
    public mutating func prepareFinal(_ payload: StreamingFinalPayload) -> StreamingFinalPayload? {
        let normalizedText = normalized(payload.text)
        let newMedia = payload.media.filter { !delivered.contains($0) }
        let mediaChanged = newMedia.count != payload.media.count

        let matchesExactPayload = deliveredExactPayloads.contains(normalizedText)
        let matchesCollapsedBlocks = !deliveredCollapsed.isEmpty && collapsed(payload.text) == deliveredCollapsed
        if !mediaChanged && (matchesExactPayload || matchesCollapsedBlocks) {
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

    /// Dedup committed assistant rows by message id (published-stream final path).
    public mutating func prepareFinal(
        committedMessageIDs: [UUID],
        payload: StreamingFinalPayload
    ) -> StreamingFinalPayload? {
        let undeliveredIDs = committedMessageIDs.filter { !deliveredMessageIDs.contains($0) }
        if undeliveredIDs.isEmpty {
            let newMedia = payload.media.filter { !delivered.contains($0) }
            if newMedia.isEmpty {
                return nil
            }
            for ref in payload.media {
                delivered.insert(ref)
            }
            return StreamingFinalPayload(text: payload.text, media: newMedia)
        }

        recordDeliveredMessageIDs(undeliveredIDs)
        return prepareFinal(payload)
    }

    public mutating func reset() {
        delivered = []
        deliveredExactPayloads = []
        deliveredCollapsed = ""
        deliveredMessageIDs = []
    }

    private func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func collapsed(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }
}
