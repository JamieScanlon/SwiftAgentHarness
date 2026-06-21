import Foundation
import SwiftAgentKit

/// UTF-8 JSON encoding for `conversation/{id}/events` payloads (`messagesRefresh` semantic kind).
/// Keeps wire shape aligned with canonical message-row encoding.
enum ConversationTopicWireEncoding {
    private static func encodeContentDeltaWireJSONUTF8(_ wire: ModelContentDeltaWire) -> String {
        let data = try! JSONEncoder().encode(wire)
        return String(data: data, encoding: .utf8) ?? "{\"v\":1,\"kind\":\"text\"}"
    }

    /// Harness-shaped text fragment for `semanticKind == contentDelta` (`jsonUTF8` holds ``ModelContentDeltaWire``).
    static func contentDeltaTextFragmentPayload(
        text: String,
        blockIndex: Int? = nil,
        runId: UUID? = nil,
        callId: UUID? = nil
    ) -> ConversationTopicEventPayload {
        let wire = ModelPoolContentDeltaMapping.textFragment(fragment: text, blockIndex: blockIndex, runId: runId, callId: callId)
        return ConversationTopicEventPayload.contentDeltaJSONUTF8(encodeContentDeltaWireJSONUTF8(wire))
    }

    /// Reasoning channel fragment (`kind == reasoning`).
    static func contentDeltaReasoningFragmentPayload(
        text: String,
        blockIndex: Int? = nil,
        runId: UUID? = nil,
        callId: UUID? = nil
    ) -> ConversationTopicEventPayload {
        let wire = ModelPoolContentDeltaMapping.reasoningFragment(fragment: text, blockIndex: blockIndex, runId: runId, callId: callId)
        return ConversationTopicEventPayload.contentDeltaJSONUTF8(encodeContentDeltaWireJSONUTF8(wire))
    }

    /// Tool-call streaming fragment (`kind == toolCall`).
    static func contentDeltaToolCallFragmentPayload(
        toolName: String?,
        toolCallId: String?,
        argumentsFragment: String?,
        blockIndex: Int? = nil,
        runId: UUID? = nil,
        callId: UUID? = nil
    ) -> ConversationTopicEventPayload {
        let wire = ModelPoolContentDeltaMapping.toolCallFragment(
            toolName: toolName,
            toolCallId: toolCallId,
            argumentsFragment: argumentsFragment,
            blockIndex: blockIndex,
            runId: runId,
            callId: callId
        )
        return ConversationTopicEventPayload.contentDeltaJSONUTF8(encodeContentDeltaWireJSONUTF8(wire))
    }

    /// Typed delta → topic payload (pool/runtime calls this after normalization).
    static func contentDeltaPayload(wire: ModelContentDeltaWire) -> ConversationTopicEventPayload {
        ConversationTopicEventPayload.contentDeltaJSONUTF8(encodeContentDeltaWireJSONUTF8(wire))
    }

    static func modelLifecyclePayload(payload: ModelStatePayload) -> ConversationTopicEventPayload {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try! encoder.encode(payload)
        let utf8 = String(data: data, encoding: .utf8) ?? "{}"
        return ConversationTopicEventPayload.modelLifecycleJSONUTF8(utf8)
    }

    static func runtimeLifecyclePayload(payload: RuntimeLifecycleEventPayload) -> ConversationTopicEventPayload {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try! encoder.encode(payload)
        let utf8 = String(data: data, encoding: .utf8) ?? "{}"
        return ConversationTopicEventPayload.runtimeLifecycleJSONUTF8(utf8)
    }

    /// Same UTF-8 JSON array used by `messagesRefresh` snapshots and persisted replay payloads.
    static func messagesJSONArrayUTF8(from messages: [Message]) -> String {
        let rows = messages.map { $0.toJSON(includeImageData: false, includeThumbData: true) }
        let data = try! JSONSerialization.data(withJSONObject: rows)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// UTF-8 JSON for `messagesRefresh`: array, or object with `messages` + optional `latestTranscriptSequence` (store cursor; distinct from hub `seq`).
    static func messagesRefreshJSONUTF8(from messages: [Message], latestTranscriptSequence: Int?) -> String {
        let rows = messages.map { $0.toJSON(includeImageData: false, includeThumbData: true) }
        if let seq = latestTranscriptSequence {
            let obj: [String: Any] = ["messages": rows, "latestTranscriptSequence": seq]
            let data = try! JSONSerialization.data(withJSONObject: obj)
            return String(data: data, encoding: .utf8) ?? "{\"messages\":[]}"
        }
        let data = try! JSONSerialization.data(withJSONObject: rows)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func messagesRefreshPayload(messages: [Message], latestTranscriptSequence: Int? = nil) -> ConversationTopicEventPayload {
        ConversationTopicEventPayload.messagesRefreshJSONUTF8(messagesRefreshJSONUTF8(from: messages, latestTranscriptSequence: latestTranscriptSequence))
    }

    static func messagesRefreshPayload(messages: [Message]) -> ConversationTopicEventPayload {
        messagesRefreshPayload(messages: messages, latestTranscriptSequence: nil)
    }

    /// Checkpoint lifecycle notification for `conversation/{id}/events` (`semanticKind == checkpoint`).
    static func checkpointTopicPayload(wire: ConversationCheckpointTopicEventWire) -> ConversationTopicEventPayload {
        let data = try! JSONEncoder().encode(wire)
        let utf8 = String(data: data, encoding: .utf8) ?? "{}"
        return ConversationTopicEventPayload.checkpointJSONUTF8(utf8)
    }

    static func surfaceIntentPayload(intent: ClientSurfaceIntent) -> ConversationTopicEventPayload {
        let data = try! JSONEncoder().encode(intent)
        let utf8 = String(data: data, encoding: .utf8) ?? "{}"
        return ConversationTopicEventPayload.surfaceIntentJSONUTF8(utf8)
    }
}
