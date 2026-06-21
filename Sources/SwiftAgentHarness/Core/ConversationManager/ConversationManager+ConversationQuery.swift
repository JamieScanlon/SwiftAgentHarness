//
//  Paged list + lifecycle updates for the CRUD/query API track.
//

import Foundation

extension ConversationManager {

    /// Filtered, sorted, offset/limit list for REST `GET /api/conversations`.
    func listConversationSummaries(query: ConversationListQuery) -> PagedConversationsResponse {
        if hydratesRegistryFromHarnessCatalog {
            return listConversationSummariesFromCatalog(query: query)
        }
        return PagedConversationsResponse(items: [], totalCount: 0, nextOffset: nil)
    }

    private func listConversationSummariesFromCatalog(query: ConversationListQuery) -> PagedConversationsResponse {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let clampedLimit = min(max(query.limit, 1), 200)
        let offset = max(0, query.offset)

        let catalogFilter = sessionConversationListFilter(from: query)
        let matching: [SessionCatalogRecord]
        do {
            matching = try fetchAllCatalogRecordsMatchingListQuery(query: query, catalogFilter: catalogFilter)
        } catch {
            return PagedConversationsResponse(items: [], totalCount: 0, nextOffset: nil)
        }

        let sorted = sortCatalogRecordsForList(matching, sort: query.sort)
        let totalCount = sorted.count
        guard offset < totalCount else {
            return PagedConversationsResponse(items: [], totalCount: totalCount, nextOffset: nil)
        }
        let page = Array(sorted.dropFirst(offset).prefix(clampedLimit))
        let items = page.map { summaryFromCatalogRecord($0, isoFormatter: isoFormatter) }
        let nextOffset = offset + items.count < totalCount ? offset + items.count : nil
        return PagedConversationsResponse(items: items, totalCount: totalCount, nextOffset: nextOffset)
    }

    private func sessionConversationListFilter(from query: ConversationListQuery) -> SessionConversationListFilter {
        var filter = SessionConversationListFilter()
        filter.agentId = SessionPersistenceConfiguration.sessionAgentId
        if let lifecycle = query.lifecycle {
            filter.lifecycleState = lifecycle.rawValue
        }
        filter.since = query.updatedAfter
        filter.parentConversationID = query.parentConversationID
        filter.catalogVisibility = query.catalogVisibilityFilter
        return filter
    }

    private func fetchAllCatalogRecordsMatchingListQuery(
        query: ConversationListQuery,
        catalogFilter: SessionConversationListFilter
    ) throws -> [SessionCatalogRecord] {
        if query.searchMode == .fts, let raw = query.search?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return try fetchCatalogRecordsForFTSListQuery(query: query, catalogFilter: catalogFilter, queryText: raw)
        }
        var collected: [SessionCatalogRecord] = []
        var cursor: String?
        repeat {
            let page = try listSessionBackendConversations(
                filter: catalogFilter,
                limit: 200,
                cursor: cursor
            )
            collected.append(contentsOf: page.records)
            cursor = page.nextCursor
            if page.records.isEmpty { break }
        } while cursor != nil
        return applyListQueryPostFilters(records: collected, query: query)
    }

    private func fetchCatalogRecordsForFTSListQuery(
        query: ConversationListQuery,
        catalogFilter: SessionConversationListFilter,
        queryText: String
    ) throws -> [SessionCatalogRecord] {
        let hits = try sessionBackend.searchTranscriptMessages(
            query: queryText,
            agentId: SessionPersistenceConfiguration.sessionAgentId,
            conversationID: nil,
            limit: 50_000
        )
        var seen = Set<UUID>()
        var records: [SessionCatalogRecord] = []
        for hit in hits {
            guard seen.insert(hit.conversationID).inserted else { continue }
            guard let row = try sessionBackend.catalogConversation(id: hit.conversationID) else { continue }
            guard catalogFilter.matches(record: row) else { continue }
            records.append(row)
        }
        return applyListQueryPostFilters(records: records, query: query)
    }

    private func applyListQueryPostFilters(
        records: [SessionCatalogRecord],
        query: ConversationListQuery
    ) -> [SessionCatalogRecord] {
        var rows = records
        if let owner = query.ownerAccountID {
            let ownerString = owner.uuidString
            rows = rows.filter { $0.userID == ownerString }
        }
        if query.lifecycle == nil {
            if !query.includeDeleted {
                rows = rows.filter { $0.lifecycleStateRaw != ConversationLifecycleState.deleted.rawValue }
            }
            if !query.includeArchived {
                rows = rows.filter { $0.lifecycleStateRaw != ConversationLifecycleState.archived.rawValue }
            }
        }
        if let before = query.updatedBefore {
            rows = rows.filter { $0.updatedAt <= before }
        }
        if query.searchMode == .substring, let raw = query.search?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let needle = raw.lowercased()
            rows = rows.filter { record in
                listSubstringMatches(record: record, needle: needle)
            }
        }
        return rows
    }

    private func listSubstringMatches(record: SessionCatalogRecord, needle: String) -> Bool {
        if record.topic?.lowercased().contains(needle) == true { return true }
        if record.description?.lowercased().contains(needle) == true { return true }
        let tags = SessionCatalogResourceCodec.decode(record.resourceJSON)?.tags ?? []
        return tags.contains { $0.lowercased().contains(needle) }
    }

    private func sortCatalogRecordsForList(
        _ records: [SessionCatalogRecord],
        sort: ConversationListSort
    ) -> [SessionCatalogRecord] {
        switch sort {
        case .updatedAtDesc:
            return records.sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id.uuidString > $1.id.uuidString
            }
        case .updatedAtAsc:
            return records.sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        case .createdAtDesc:
            return records.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id.uuidString > $1.id.uuidString
            }
        case .createdAtAsc:
            return records.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
    }

    private func summaryFromCatalogRecord(
        _ record: SessionCatalogRecord,
        isoFormatter: ISO8601DateFormatter
    ) -> ConversationListSummary {
        let lifecycle = ConversationLifecycleState(rawValue: record.lifecycleStateRaw ?? "")
            ?? .active
        let tags = SessionCatalogResourceCodec.decode(record.resourceJSON)?.tags ?? []
        let listUpdatedAt = modelConversation(id: record.id)?.updatedAt ?? record.updatedAt
        return ConversationListSummary(
            id: record.id,
            modelName: record.modelName,
            topic: record.listDisplayTopic(),
            description: record.description,
            messageCount: record.messageCount,
            createdAt: isoFormatter.string(from: record.createdAt),
            updatedAt: isoFormatter.string(from: listUpdatedAt),
            lifecycle: lifecycle,
            tags: tags,
            controlPlaneRevision: UInt64(record.controlPlaneRevision)
        )
    }

    /// Updates persisted lifecycle + registry row (harness resource field).
    func updateConversationLifecycle(conversationID: UUID, lifecycle: ConversationLifecycleState, skipControlPlaneRevisionBump: Bool = false) throws {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
            throw ConversationServiceError.conversationNotFound
        }
        var updated = conversations[index]
        updated.lifecycle = lifecycle
        updated.updatedAt = Date()
        replaceConversationInRegistry(updated)

        try syncConversationCatalogStateToSessionBackend(conversation: updated)
        if !skipControlPlaneRevisionBump {
            try bumpControlPlaneRevision(conversationID: conversationID)
        }
    }

    /// Marks lifecycle `.deleted` without removing catalog rows (soft delete).
    func softDeleteConversation(conversationID: UUID) throws {
        try updateConversationLifecycle(conversationID: conversationID, lifecycle: .deleted)
    }
}
