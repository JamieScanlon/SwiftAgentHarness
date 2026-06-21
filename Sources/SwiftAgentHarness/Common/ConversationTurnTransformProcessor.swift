import EasyJSON
import Foundation
import SwiftAgentKit

/// Derives conversation turns from messages and optionally enriches turns with LLM metadata.
public struct ConversationTurnTransformProcessor: Sendable {
    public init() {}

    /// Deterministic transform with metadata reuse only (no LLM call).
    ///
    /// - Parameters:
    ///   - messages: The full visible conversation message list (not just newly appended forward messages).
    ///     Turn boundaries are recomputed from this entire list each call.
    ///   - interactionMode: Mode gate for turn derivation.
    ///   - previousTurns: Previously computed turns for the same conversation snapshot lineage. Used only
    ///     to reuse metadata when the recomputed `messageIDs` signature matches.
    /// - Returns: Recomputed turns for `messages`, with metadata reused where signatures are unchanged.
    public func transform(
        messages: [Message],
        interactionMode: InteractionMode,
        previousTurns: [ConversationTurn] = []
    ) -> [ConversationTurn] {
        let grouped = conversationTurns(interactionMode: interactionMode, messages: messages)
        guard interactionMode == .agent, !grouped.isEmpty else { return grouped }

        let oldBySignature: [String: TurnMetadata] = Dictionary(
            uniqueKeysWithValues: previousTurns.compactMap { turn in
                guard let metadata = turn.typedMetadata else { return nil }
                return (metadata.messageSignature, metadata)
            }
        )

        return grouped.map { turn in
            let signature = TurnMetadataCodec.signature(for: turn.messageIDs)
            guard let metadata = oldBySignature[signature],
                  metadata.schemaVersion == TurnMetadata.currentSchemaVersion else {
                return turn
            }
            var updated = turn
            updated.metadataJSON = TurnMetadataCodec.encode(metadata)
            return updated
        }
    }

    /// LLM-assisted transform: groups turns and fills missing/stale metadata.
    ///
    /// - Parameters:
    ///   - messages: The full visible conversation message list (not just newly appended forward messages).
    ///     Turn boundaries are recomputed from this entire list each call. Passing only forward/delta
    ///     messages will produce turns only for that subset.
    ///   - interactionMode: Mode gate for turn derivation and enrichment. Enrichment runs for `.agent` only.
    ///   - llm: SwiftAgentKit `LLMProtocol` used to generate missing/stale metadata per derived turn.
    ///   - previousTurns: Previously computed turns for the same conversation snapshot lineage. Used only
    ///     to reuse metadata when signatures are unchanged before deciding which turns still need LLM work.
    /// - Returns: Recomputed turns for `messages` with metadata reused where valid and enriched where missing/stale.
    public func transform(
        messages: [Message],
        interactionMode: InteractionMode,
        llm: any LLMProtocol,
        previousTurns: [ConversationTurn] = []
    ) async throws -> [ConversationTurn] {
        var turns = transform(messages: messages, interactionMode: interactionMode, previousTurns: previousTurns)
        guard interactionMode == .agent, !turns.isEmpty else { return turns }

        for index in turns.indices {
            var turn = turns[index]
            let signature = TurnMetadataCodec.signature(for: turn.messageIDs)
            if let metadata = turn.typedMetadata,
               metadata.schemaVersion == TurnMetadata.currentSchemaVersion,
               metadata.messageSignature == signature {
                continue
            }

            let turnMessages = messages.filter { turn.messageIDs.contains($0.id) }
            let metadata = try await generateMetadata(for: turnMessages, signature: signature, llm: llm)
            turn.metadataJSON = TurnMetadataCodec.encode(metadata)
            turns[index] = turn
        }
        return turns
    }

    private func generateMetadata(
        for turnMessages: [Message],
        signature: String,
        llm: any LLMProtocol
    ) async throws -> TurnMetadata {
        let system = Message(
            id: UUID(),
            role: .system,
            content: """
            You are producing metadata for one conversation turn.
            Respond with strict JSON only (no markdown), with keys:
            summary (string), compressedText (string), tokenEstimate (integer).
            """
        )
        let transcript = turnMessages.enumerated().map { idx, msg in
            "[\(idx)] role=\(msg.role.rawValue)\n\(msg.content)"
        }.joined(separator: "\n\n")
        let user = Message(
            id: UUID(),
            role: .user,
            content: """
            Turn transcript:
            \(transcript)
            """
        )

        let response = try await llm.send(
            [system, user],
            config: LLMRequestConfig(
                additionalParameters: .object([
                    "requestPurpose": .string("transform.conversationTurn.metadata")
                ])
            )
        )
        let parsed = parseMetadataJSON(response.content)
        return TurnMetadata(
            messageSignature: signature,
            summary: parsed.summary,
            compressedText: parsed.compressedText,
            tokenEstimate: parsed.tokenEstimate
        )
    }

    private struct ParsedMetadata {
        var summary: String?
        var compressedText: String?
        var tokenEstimate: Int?
    }

    private func parseMetadataJSON(_ content: String) -> ParsedMetadata {
        let jsonText = extractJSONObjectText(from: content) ?? content
        guard let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ParsedMetadata(summary: content.trimmingCharacters(in: .whitespacesAndNewlines), compressedText: nil, tokenEstimate: nil)
        }

        let summary = object["summary"] as? String
        let compressedText = object["compressedText"] as? String
        let tokenEstimate: Int? = {
            if let value = object["tokenEstimate"] as? Int { return value }
            if let value = object["tokenEstimate"] as? Double { return Int(value) }
            if let value = object["tokenEstimate"] as? String { return Int(value) }
            return nil
        }()
        return ParsedMetadata(summary: summary, compressedText: compressedText, tokenEstimate: tokenEstimate)
    }

    private func extractJSONObjectText(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            return nil
        }
        guard start <= end else { return nil }
        return String(text[start...end])
    }
}
