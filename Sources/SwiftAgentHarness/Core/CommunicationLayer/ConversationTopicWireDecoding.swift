import Foundation
import SwiftAgentKit

/// Decoded conversation topic event for surface stream drivers.
public enum DecodedConversationTopicEvent: Sendable {
    case partial(ChatStreamingPartial, runID: UUID?, callID: UUID?, seq: Int?, turnOrdinal: Int?)
    case streamDone(runID: UUID?, seq: Int?, turnOrdinal: Int?)
    case runtimeLifecycle(RuntimeLifecycleEventPayload, seq: Int?, turnOrdinal: Int?)
    case committedMessages([Message], seq: Int?, turnOrdinal: Int?)
    case surfaceIntent(ClientSurfaceIntent, seq: Int?, turnOrdinal: Int?)
    case modelLifecycle(seq: Int?, turnOrdinal: Int?)
    case checkpoint(seq: Int?, turnOrdinal: Int?)
    case unknown(semanticKind: String?, seq: Int?, turnOrdinal: Int?)
}

/// Inverse of ``ConversationTopicWireEncoding`` for surface clients of `conversation/{id}/events`.
public enum ConversationTopicWireDecoding {
    public static func chatStreamingPartial(from wire: ModelContentDeltaWire) -> ChatStreamingPartial? {
        switch wire.kind {
        case .text:
            guard let text = wire.text, !text.isEmpty else { return nil }
            return .text(text)
        case .reasoning:
            guard let text = wire.text, !text.isEmpty else { return nil }
            return .reasoning(text, blockIndex: wire.index)
        case .toolCall:
            return .toolCall(
                toolName: wire.toolName,
                toolCallId: wire.toolCallId,
                argumentsFragment: wire.toolArgumentsFragment,
                blockIndex: wire.index
            )
        }
    }

    public static func decodeEnvelope(
        _ line: String
    ) -> CommResourceTopicMessage<ConversationTopicEventPayload>? {
        guard let data = line.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(
            CommResourceTopicMessage<ConversationTopicEventPayload>.self,
            from: data
        )
    }

    public static func decodeMessagesRefreshRows(_ jsonUTF8: String) -> [Message] {
        guard let data = jsonUTF8.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        let rows: [[String: Any]]
        if let array = parsed as? [[String: Any]] {
            rows = array
        } else if let object = parsed as? [String: Any],
                  let messages = object["messages"] as? [[String: Any]] {
            rows = messages
        } else {
            return []
        }

        return rows.compactMap { Message.fromJSON($0) }
    }

    public static func decodeEvent(line: String) -> DecodedConversationTopicEvent {
        guard let envelope = decodeEnvelope(line),
              let payload = envelope.value else {
            return .unknown(semanticKind: nil, seq: nil, turnOrdinal: nil)
        }

        let seq = envelope.seq
        let turnOrdinal = envelope.turnOrdinal
        let runID = envelope.runId

        switch payload.semanticKind {
        case .contentDelta:
            guard let jsonUTF8 = payload.jsonUTF8,
                  let data = jsonUTF8.data(using: .utf8),
                  let wire = try? JSONDecoder().decode(ModelContentDeltaWire.self, from: data),
                  let partial = chatStreamingPartial(from: wire) else {
                return .unknown(semanticKind: payload.semanticKind.rawValue, seq: seq, turnOrdinal: turnOrdinal)
            }
            return .partial(
                partial,
                runID: wire.runId ?? runID,
                callID: wire.callId,
                seq: seq,
                turnOrdinal: turnOrdinal
            )
        case .streamDone:
            return .streamDone(runID: runID, seq: seq, turnOrdinal: turnOrdinal)
        case .runtimeLifecycle:
            guard let jsonUTF8 = payload.jsonUTF8,
                  let data = jsonUTF8.data(using: .utf8) else {
                return .unknown(semanticKind: payload.semanticKind.rawValue, seq: seq, turnOrdinal: turnOrdinal)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let lifecycle = try? decoder.decode(RuntimeLifecycleEventPayload.self, from: data) else {
                return .unknown(semanticKind: payload.semanticKind.rawValue, seq: seq, turnOrdinal: turnOrdinal)
            }
            return .runtimeLifecycle(lifecycle, seq: seq, turnOrdinal: turnOrdinal)
        case .messagesRefresh:
            guard let jsonUTF8 = payload.jsonUTF8 else {
                return .committedMessages([], seq: seq, turnOrdinal: turnOrdinal)
            }
            return .committedMessages(
                decodeMessagesRefreshRows(jsonUTF8),
                seq: seq,
                turnOrdinal: turnOrdinal
            )
        case .surfaceIntent:
            guard let jsonUTF8 = payload.jsonUTF8,
                  let data = jsonUTF8.data(using: .utf8),
                  let intent = try? JSONDecoder().decode(ClientSurfaceIntent.self, from: data) else {
                return .unknown(semanticKind: payload.semanticKind.rawValue, seq: seq, turnOrdinal: turnOrdinal)
            }
            return .surfaceIntent(intent, seq: seq, turnOrdinal: turnOrdinal)
        case .modelLifecycle:
            return .modelLifecycle(seq: seq, turnOrdinal: turnOrdinal)
        case .checkpoint:
            return .checkpoint(seq: seq, turnOrdinal: turnOrdinal)
        }
    }
}
