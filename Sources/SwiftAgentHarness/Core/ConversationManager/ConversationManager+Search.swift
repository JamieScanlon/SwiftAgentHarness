//
//  Cross-conversation search via harness transcript FTS when a local/in-memory session backend is installed.
//

import Foundation

extension ConversationManager {

    /// Ranks message hits for `q` with excerpts; uses harness FTS when v2 is installed.
    func searchConversations(request: ConversationSearchRequest) -> ConversationSearchResponse {
        if request.kind == .semantic {
            return ConversationSearchResponse(
                hits: [],
                totalHitCount: 0,
                warning: "Semantic search is not implemented.",
                nextOffset: nil
            )
        }

        let clampedLimit = min(max(request.limit, 1), 100)
        let offset = max(0, request.offset)
        let raw = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return ConversationSearchResponse(hits: [], totalHitCount: 0, warning: nil, nextOffset: nil)
        }

        if harnessSessionPersistence is LocalHarnessSessionPersistence
            || harnessSessionPersistence is InMemoryHarnessSessionPersistence {
            return searchConversationsViaTranscriptFTS(request: request, query: raw, offset: offset, limit: clampedLimit)
        }

        return ConversationSearchResponse(
            hits: [],
            totalHitCount: 0,
            warning: "Message search requires harness catalog + transcript persistence.",
            nextOffset: nil
        )
    }

    private func searchConversationsViaTranscriptFTS(
        request: ConversationSearchRequest,
        query: String,
        offset: Int,
        limit: Int
    ) -> ConversationSearchResponse {
        let fetchLimit = min(50_000, offset + limit + 500)
        let hits: [SessionMessageSearchHit]
        do {
            hits = try sessionBackend.searchTranscriptMessages(
                query: query,
                agentId: SessionPersistenceConfiguration.sessionAgentId,
                conversationID: nil,
                limit: fetchLimit
            )
        } catch {
            return ConversationSearchResponse(hits: [], totalHitCount: 0, warning: nil, nextOffset: nil)
        }
        let filtered = hits.filter { hit in
            guard let conv = modelConversation(id: hit.conversationID) else { return false }
            if let owner = request.ownerAccountID, conv.ownerAccountID != owner { return false }
            if conv.lifecycle == .deleted, !request.includeDeleted { return false }
            if conv.lifecycle == .archived, !request.includeArchived { return false }
            return true
        }
        let totalHitCount = filtered.count
        guard offset < totalHitCount else {
            return ConversationSearchResponse(hits: [], totalHitCount: totalHitCount, warning: nil, nextOffset: nil)
        }
        let page = Array(filtered.dropFirst(offset).prefix(limit))
        let mapped: [ConversationSearchHit] = page.enumerated().map { index, hit in
            let excerpt = hit.snippet
                .replacingOccurrences(of: SessionFTS5SearchConstants.snippetHighlightStart, with: "")
                .replacingOccurrences(of: SessionFTS5SearchConstants.snippetHighlightEnd, with: "")
            let messageID = modelConversation(id: hit.conversationID).flatMap { conv in
                SessionEntryID.matchingMessageID(for: hit.entryId, in: conv.messages)
            } ?? hit.conversationID
            return ConversationSearchHit(
                conversationID: hit.conversationID,
                messageID: messageID,
                excerpt: excerpt,
                score: -hit.score,
                rank: offset + index + 1,
                conversationTopic: modelConversation(id: hit.conversationID)?.topic
            )
        }
        let nextOffset: Int? = offset + mapped.count < totalHitCount ? offset + mapped.count : nil
        return ConversationSearchResponse(
            hits: mapped,
            totalHitCount: totalHitCount,
            warning: nil,
            nextOffset: nextOffset
        )
    }
}
