import Foundation

extension ConversationManager {

    func applyConversationResourceCatalogPatch(
        _ conversation: ModelConversation,
        streamingRunIDOverride: UUID? = nil,
        expectedRevision: UInt64? = nil
    ) throws -> SessionCatalogRecord {
        let inferredStatus = conversation.inferredResourceRunStatusForPersistence()
        let effectiveRunID: UUID? = inferredStatus == .idle ? nil : (streamingRunIDOverride ?? conversation.currentRunID)
        var patch = SessionConversationUpdatePatch()
        patch.lifecycleStateRaw = .set(conversation.lifecycle.rawValue)
        patch.resourceRunStatusRaw = .set(inferredStatus.rawValue)
        patch.currentRunID = .set(effectiveRunID)
        patch.parentConversationID = .set(conversation.parentConversationID ?? conversation.splitFromConversationID)
        patch.userID = .set(conversation.ownerAccountID?.uuidString)
        patch.resourceJSON = .set(SessionCatalogResourceCodec.encode(conversation))
        patch.lastActiveAt = .set(conversation.lastActiveAt ?? conversation.updatedAt)
        patch.metadataJSON = .set(SessionCatalogRecord.metadataJSONString(from: conversation.metadata))
        patch.systemPrompt = .set(conversation.systemPrompt.isEmpty ? nil : conversation.systemPrompt)
        patch.modelConfigJSON = .set(SessionCatalogResourceCodec.modelConfigJSONHint(from: conversation))
        patch.updatedAt = .set(conversation.updatedAt)
        let revision = expectedRevision ?? conversation.controlPlaneRevision
        let updated = try harnessSessionPersistence.updateSessionConversation(
            conversationID: conversation.id,
            patch: patch,
            expectedRevision: revision
        )
        if var inMemory = modelConversation(id: conversation.id) {
            inMemory.controlPlaneRevision = UInt64(updated.controlPlaneRevision)
            replaceConversationInRegistry(inMemory)
        }
        return updated
    }

    /// Persists harness conversation resource fields on the catalog row (v14+ columns).
    func persistConversationResourceFields(
        _ conversation: ModelConversation,
        streamingRunIDOverride: UUID?
    ) throws {
        guard catalogRowExists(conversationID: conversation.id) else { return }
        _ = try applyConversationResourceCatalogPatch(conversation, streamingRunIDOverride: streamingRunIDOverride)
    }

    func hydrateConversationResourceFields(from record: SessionCatalogRecord, into model: inout ModelConversation) {
        if let raw = record.lifecycleStateRaw,
           let v = ConversationLifecycleState(rawValue: raw) {
            model.lifecycle = v
        }
        SessionCatalogResourceCodec.hydrateResourceFields(from: record, into: &model)
        model.ownerAccountID = record.userID.flatMap(UUID.init(uuidString:))
    }

    /// Appends a branch reference on the parent's denormalized index (and saves).
    func appendBranchRef(parentConversationID: UUID, ref: ConversationBranchRef) throws {
        guard var parent = modelConversation(id: parentConversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        parent.branchChildren.append(ref)
        replaceConversationInRegistry(parent)
        _ = try applyConversationResourceCatalogPatch(parent)
    }

    /// Updates persisted budget snapshot JSON from token/orchestration hints.
    func persistBudgetSnapshot(conversationID: UUID, snapshot: ConversationBudgetSnapshot) throws {
        guard var conversation = modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        conversation.budgetSnapshot = snapshot
        replaceConversationInRegistry(conversation)
        _ = try applyConversationResourceCatalogPatch(conversation)
    }

    /// Dedupes by resource id and persists attachment catalog on harness resource JSON.
    /// Removing attachments updates catalog/transcript refs only — never calls ``HarnessSessionPersistence/deleteBlob(blobId:)``; bytes are reclaimed by install maintenance sweep.
    func mergeAttachmentsCatalog(
        conversationID: UUID,
        resources: [CachedResource],
        attachmentTrustRaw: String?,
        harness: (any HarnessSessionPersistence)? = nil
    ) throws {
        guard !resources.isEmpty else { return }
        guard var conversation = modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        let sessionHarness: any HarnessSessionPersistence = harness ?? harnessSessionPersistence
        var catalog = conversation.attachmentsCatalog
        var seen = Set(catalog.map(\.id))
        let normalizedTrust = AttachmentInputTrustCodec.sanitizedInputTrustRaw(attachmentTrustRaw)
        let now = Date()
        for resource in resources where !seen.contains(resource.id) {
            let blobId = SessionBlobImageRef.parsePath(resource.filePath)
                ?? SessionBlobImageRef.parsePath(resource.thumbnailPath)
            let stat = blobId.flatMap { try? sessionHarness.statBlob(blobId: $0) }
            let addedBy: ConversationAttachmentAddedBy = .user
            let trustRaw = normalizedTrust ?? AttachmentProvenancePolicy.defaultTrustRaw(for: addedBy)
            catalog.append(
                ConversationAttachmentDescriptor(
                    id: resource.id,
                    blobId: blobId,
                    kind: resource.fileType,
                    name: resource.name,
                    mimeType: stat?.mimeType,
                    byteSize: stat.map { Int64($0.size) },
                    addedAt: now,
                    addedBy: addedBy,
                    trustRaw: trustRaw
                )
            )
            seen.insert(resource.id)
        }
        conversation.attachmentsCatalog = catalog
        replaceConversationInRegistry(conversation)
        _ = try applyConversationResourceCatalogPatch(conversation)
    }

    func catalogAttachmentID(forBlobId blobId: String, conversationID: UUID) -> UUID? {
        let normalized = blobId.lowercased()
        guard let conversation = modelConversation(id: conversationID) else { return nil }
        return conversation.attachmentsCatalog.first(where: { $0.blobId?.lowercased() == normalized })?.id
    }

    /// Durable hydration source for runtime budget ledger startup.
    func budgetLedgerHydrationSeeds() -> [BudgetLedgerHydrationSeed] {
        let records = (try? sessionBackend.listCatalogConversations()) ?? []
        return records.map { record in
            let decoded = SessionCatalogResourceCodec.decode(record.resourceJSON)
            let spent = max(0, decoded?.budgetSnapshot?.spentUSD ?? 0)
            let maxUSD = decoded?.budgetSnapshot?.maxUSD
            return BudgetLedgerHydrationSeed(
                conversationID: record.id,
                parentConversationID: record.parentConversationID,
                ownerAccountID: record.userID.flatMap(UUID.init(uuidString:)),
                spentUSD: spent,
                maxUSD: maxUSD
            )
        }
    }
}
