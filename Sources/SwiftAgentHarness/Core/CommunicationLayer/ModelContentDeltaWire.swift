import Foundation

/// Harness-aligned `model.contentDelta` payload for ``ConversationTopicEventPayload`` (`semanticKind == .contentDelta`),
/// carried as UTF-8 JSON in ``ConversationTopicEventPayload/jsonUTF8``.
public struct ModelContentDeltaWire: Codable, Sendable, Equatable {
    /// Wire schema revision (bump when adding required fields).
    public var v: Int
    public var kind: Kind
    /// Optional block index for multiplexed assistant content (tool blocks, reasoning vs answer, etc.).
    public var index: Int?
    /// UTF-8 text fragment for ``Kind/text`` and ``Kind/reasoning``.
    public var text: String?
    /// Tool-call streaming fields (fragment-friendly).
    public var toolName: String?
    public var toolCallId: String?
    public var toolArgumentsFragment: String?
    /// Turn-scoped run (Agent Runtime); pool call id is separate.
    public var runId: UUID?
    /// Pool-assigned call id for model streaming deltas.
    public var callId: UUID?

    public enum Kind: String, Codable, Sendable {
        case text
        case reasoning
        case toolCall
    }

    public init(
        v: Int = 1,
        kind: Kind,
        index: Int? = nil,
        text: String? = nil,
        toolName: String? = nil,
        toolCallId: String? = nil,
        toolArgumentsFragment: String? = nil,
        runId: UUID? = nil,
        callId: UUID? = nil
    ) {
        self.v = v
        self.kind = kind
        self.index = index
        self.text = text
        self.toolName = toolName
        self.toolCallId = toolCallId
        self.toolArgumentsFragment = toolArgumentsFragment
        self.runId = runId
        self.callId = callId
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(index, forKey: .index)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(toolName, forKey: .toolName)
        try c.encodeIfPresent(toolCallId, forKey: .toolCallId)
        try c.encodeIfPresent(toolArgumentsFragment, forKey: .toolArgumentsFragment)
        try c.encodeIfPresent(runId, forKey: .runId)
        try c.encodeIfPresent(callId, forKey: .callId)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        kind = try c.decode(Kind.self, forKey: .kind)
        index = try c.decodeIfPresent(Int.self, forKey: .index)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
        toolArgumentsFragment = try c.decodeIfPresent(String.self, forKey: .toolArgumentsFragment)
        runId = try c.decodeIfPresent(UUID.self, forKey: .runId)
        callId = try c.decodeIfPresent(UUID.self, forKey: .callId)
    }

    private enum CodingKeys: String, CodingKey {
        case v, kind, index, text, toolName, toolCallId, toolArgumentsFragment, runId, callId
    }
}
