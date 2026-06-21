//
//  Harness-aligned conversation resource layer (stable ids, CRUD, harness catalog + transcript).
//

import EasyJSON
import Foundation
import Logging
import SwiftData
import SwiftAgentKit

/// Owns in-process conversation registry; durable metadata lives on harness catalog + transcript. Held by ``ConversationPersistenceDomain``
/// (composition root); orchestration reads/writes see it indirectly via **`HarnessRuntimeSession`** (`conversationManager` alias).
/// Not `Sendable` — callers treat mutations as confined to the persistence domain + **`HarnessRuntimeSession`** orchestration actor.
/// Kept as a class so synchronous delegation stays cheap versus hopping isolation boundaries twice per hot path.
final class ConversationManager {

    let modelContainer: ModelContainer
    private let logger: Logger?

    private(set) var conversations: [ModelConversation] = []

    /// Harness persistence surface for this manager. Defaults to in-memory for tests without local install.
    private var harnessSessionPersistenceBacking: any SessionBackend = InMemoryHarnessSessionPersistence()

    /// Harness-aligned persistence surface (installed v2 local backend in production).
    var harnessSessionPersistence: any HarnessSessionPersistence {
        harnessSessionPersistenceBacking
    }

    /// Harness template ``SessionBackend`` name for ``harnessSessionPersistence``.
    var sessionBackend: any SessionBackend { harnessSessionPersistence }

    /// Installs a harness backend for this manager.
    func setHarnessSessionPersistenceOverride(_ persistence: (any SessionBackend)?) {
        harnessSessionPersistenceBacking = persistence ?? InMemoryHarnessSessionPersistence()
    }

    /// Weak back-reference to ``ConversationPersistenceStack`` for transcript append + derived journal routing.
    weak var persistenceCoordinator: (any ConversationPersistenceCoordinating)?

    func attachPersistenceCoordinator(_ coordinator: any ConversationPersistenceCoordinating) {
        persistenceCoordinator = coordinator
    }

    /// Production Local install: catalog + transcript are durable registry, messages, and journal; SwiftData V22 container is migration anchors only.
    private var usesHarnessConversationRegistry: Bool {
        harnessSessionPersistence is LocalHarnessSessionPersistence
    }

    var skipsSwiftDataRegistryWrites: Bool {
        usesHarnessConversationRegistry
    }

    var hydratesRegistryFromHarnessCatalog: Bool {
        harnessSessionPersistence is LocalHarnessSessionPersistence
            || harnessSessionPersistence is InMemoryHarnessSessionPersistence
    }

    func catalogRowExists(conversationID: UUID) -> Bool {
        guard hydratesRegistryFromHarnessCatalog else { return false }
        return (try? sessionBackend.catalogConversation(id: conversationID)) != nil
    }

    private func appendMessagesToHarnessTranscript(
        conversationID: UUID,
        messages: [Message],
        parentEntryId: SessionEntryID? = nil
    ) throws {
        let harness = harnessSessionPersistence
        var parent = parentEntryId
        for message in messages {
            let sequence = try harness.nextTranscriptSequence(conversationID: conversationID)
            let entry = try SessionTranscriptMapping.entry(
                from: message,
                sequence: sequence,
                parentEntryId: parent,
                transcriptRunID: nil
            )
            try harness.appendTranscriptEntries(conversationID: conversationID, entries: [entry])
            parent = entry.entryId
        }
    }

    private func persistSystemPromptChangeToHarnessTranscript(
        conversationID: UUID,
        systemMessage: Message
    ) throws {
        guard catalogRowExists(conversationID: conversationID) else { return }
        let harness = harnessSessionPersistence
        let lineage = try ConversationTranscriptLineage.activeLineageEntries(
            conversationID: conversationID,
            harness: harness
        )
        guard let systemEntry = lineage.first(where: { $0.type == .system }) else { return }
        var base = try SessionTranscriptMapping.messageForReplay(from: systemEntry) ?? systemMessage
        base = Message(
            id: base.id,
            role: .system,
            content: systemMessage.content,
            timestamp: base.timestamp,
            images: base.images,
            toolCalls: base.toolCalls,
            toolCallId: base.toolCallId,
            responseFormat: base.responseFormat,
            inputTrustRaw: base.inputTrustRaw
        )
        var entry = systemEntry
        entry.payloadJSON = try MessageTranscriptPayloadCodec.encodePayloadJSON(from: base)
        switch harness {
        case let local as LocalHarnessSessionPersistence:
            try local.updateTranscriptEntryPayload(conversationID: conversationID, entry: entry)
        case let inMemory as InMemoryHarnessSessionPersistence:
            try inMemory.updateTranscriptEntryPayload(conversationID: conversationID, entry: entry)
        default:
            return
        }
    }

    init(container: ModelContainer, logger: Logger? = nil) {
        self.modelContainer = container
        self.logger = logger
    }

    private func messageShapedTranscriptMessages(conversationID: UUID) throws -> [Message] {
        let entries = try harnessSessionPersistence.readTranscriptEntries(
            conversationID: conversationID,
            request: .full
        )
        return entries
            .filter { $0.type == .message || $0.type == .system }
            .sorted { $0.sequence < $1.sequence }
            .compactMap { try? SessionTranscriptMapping.messageForReplay(from: $0) }
    }

    func messagesNeedingTranscriptMessageAppendedJournal(
        conversationID: UUID,
        messages: [Message]
    ) throws -> [Message] {
        let entries = try harnessSessionPersistence.readTranscriptEntries(
            conversationID: conversationID,
            request: .full
        )
        let existingIDs = Set(entries.compactMap { entry -> UUID? in
            guard entry.type == .message || entry.type == .system else { return nil }
            return try? SessionTranscriptMapping.messageForReplay(from: entry)?.id
        })
        return messages.filter { !existingIDs.contains($0.id) }
    }

    // MARK: - Registry

    func listConversationInfo() -> [ModelConversation] {
        conversations
    }

    /// Clears the in-process registry only (catalog + transcript rows unchanged). Used by tests for catalog lazy-hydrate coverage.
    func evictRegistryForTesting() {
        conversations = []
    }

    /// README backend `list_conversations` via the canonical SessionBackend seam.
    func listSessionBackendConversations(
        filter: SessionConversationListFilter,
        limit: Int,
        cursor: String?
    ) throws -> SessionCatalogPage {
        try sessionBackend.listConversations(filter, limit: limit, cursor: cursor)
    }

    /// REST list metadata projection (ISO8601 timestamps); conversation-plane peel.
    func listConversationMetadata(
        visibility: ConversationCatalogVisibilityFilter = .catalogVisible
    ) -> [ConversationMetadata] {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        return listConversationInfo()
            .filter {
                ConversationCatalogVisibility.matchesFilter(
                    lineage: $0.lineageKind,
                    origin: $0.origin,
                    filter: visibility
                )
            }
            .map { conversationMetadata(from: $0, isoFormatter: isoFormatter) }
    }

    private func conversationMetadata(from conv: ModelConversation, isoFormatter: ISO8601DateFormatter) -> ConversationMetadata {
        ConversationMetadata(
            id: conv.id.uuidString,
            modelName: conv.modelName,
            topic: conv.topic,
            description: conv.description,
            messageCount: conv.messages.count,
            createdAt: isoFormatter.string(from: conv.createdAt),
            updatedAt: isoFormatter.string(from: conv.updatedAt),
            lifecycle: conv.lifecycle,
            tags: conv.tags,
            controlPlaneRevision: conv.controlPlaneRevision,
            ownerAccountID: conv.ownerAccountID,
            interactionMode: conv.interactionMode,
            modeProfileID: conv.modeProfileID,
            parentConversationID: conv.parentConversationID,
            lineageKind: conv.lineageKind,
            origin: conv.origin,
            catalogSection: ConversationCatalogVisibility.catalogSection(
                lineage: conv.lineageKind,
                origin: conv.origin
            )
        )
    }

    func modelConversation(id: UUID) -> ModelConversation? {
        if let found = conversations.first(where: { $0.id == id }) {
            return found
        }
        do {
            return try hydrateConversationFromCatalogIntoRegistry(id: id)
        } catch {
            logger?.warning("Failed to lazy-hydrate conversation \(id) from catalog: \(error)")
            return nil
        }
    }

    /// Loads one catalog row into the in-process registry on first access (list/summary APIs read catalog directly).
    private func hydrateConversationFromCatalogIntoRegistry(
        id: UUID,
        preferredModel: Model? = nil,
        isModelAvailable: Bool = false
    ) throws -> ModelConversation? {
        guard hydratesRegistryFromHarnessCatalog else { return nil }
        guard let record = try sessionBackend.catalogConversation(id: id) else { return nil }
        if record.lifecycleStateRaw == ConversationLifecycleState.deleted.rawValue {
            return nil
        }
        let model = resolveModelForCatalogRecord(record, preferred: preferredModel)
        let hydrated = try catalogRecordToModelConversation(
            record: record,
            model: model,
            isModelAvailable: isModelAvailable
        )
        conversations.append(hydrated)
        logger?.debug("Lazy-hydrated conversation \(id) from harness catalog")
        return hydrated
    }

    private func resolveModelForCatalogRecord(_ record: SessionCatalogRecord, preferred: Model?) -> Model {
        if let preferred, preferred.modelName == record.modelName {
            return preferred
        }
        if let matched = conversations.first(where: { $0.model.modelName == record.modelName })?.model {
            return matched
        }
        let modelProtocol = ModelProtocol.openAIAPI
        return Model(
            id: UUID(),
            protocol: modelProtocol,
            modelName: record.modelName,
            serverURL: URL(string: "http://localhost")!,
            capabilities: [],
            modelProtocol: modelProtocol
        )
    }

    func indexOfConversation(id: UUID) -> Int? {
        conversations.firstIndex(where: { $0.id == id })
    }

    /// In-memory row update (orchestrator + cache persistence run elsewhere in ``HarnessRuntimeSession``).
    func replaceConversationInRegistry(_ conversation: ModelConversation) {
        logger?.info("Updating conversation \(conversation.id)")
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else {
            logger?.warning("Conversation \(conversation.id) NOT FOUND. Abourting")
            return
        }
        var merged = conversation
        let existing = conversations[index]
        if existing.messages.count > merged.messages.count {
            merged.messages = existing.messages
        }
        merged.controlPlaneRevision = max(existing.controlPlaneRevision, merged.controlPlaneRevision)
        conversations.replaceSubrange(index..<index + 1, with: [merged])
    }

    func appendPersistedMessageToRegistry(_ message: Message, conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        if conversations[index].messages.contains(where: { $0.id == message.id }) { return }
        conversations[index].messages.append(message)
        conversations[index].updatedAt = max(conversations[index].updatedAt, message.timestamp)
        if conversations[index].interactionMode == .agent {
            conversations[index].turns = conversationTurns(messages: conversations[index].messages)
        }
    }

    func appendConversation(_ conversation: ModelConversation) {
        conversations.append(conversation)
    }

    /// First conversation with id different from the given id (used when deleting the selected session).
    /// Skips soft-deleted rows so selection does not jump to a tombstoned conversation.
    func firstConversation(excluding conversationID: UUID) -> ModelConversation? {
        conversations.first(where: {
            $0.id != conversationID && $0.lifecycle != .deleted
        })
    }

    // MARK: - Load / reset

    /// Loads in-process registry from catalog rows + active transcript lineage.
    func resetConversationsFromCatalog(availableModels: [Model]) throws {
        conversations = []
        guard hydratesRegistryFromHarnessCatalog else { return }
        let records = try sessionBackend.listCatalogConversations()
        for record in records {
            let model: Model
            let isAvailable: Bool
            if let matched = availableModels.first(where: { $0.modelName == record.modelName }) {
                model = matched
                isAvailable = true
            } else {
                let modelProtocol = ModelProtocol.openAIAPI
                model = Model(
                    id: UUID(),
                    protocol: modelProtocol,
                    modelName: record.modelName,
                    serverURL: URL(string: "http://localhost")!,
                    capabilities: [],
                    modelProtocol: modelProtocol
                )
                isAvailable = false
            }
            do {
                let hydrated = try catalogRecordToModelConversation(record: record, model: model, isModelAvailable: isAvailable)
                conversations.append(hydrated)
            } catch {
                logger?.warning("resetConversationsFromCatalog skipped conversation \(record.id): \(error)")
            }
        }
    }

    func mostRecentConversation() -> ModelConversation? {
        conversations.max(by: { $0.updatedAt < $1.updatedAt })
    }

    private static func harnessCatalogWorkingDirectoryIfKnown() -> String? {
        if let v = ProcessInfo.processInfo.environment["SAH_SESSION_CWD"], !v.isEmpty { return v }
        if let v = ProcessInfo.processInfo.environment["PWD"], !v.isEmpty { return v }
        let cur = FileManager.default.currentDirectoryPath
        if cur.isEmpty || cur == "/" { return nil }
        return cur
    }

    private func applyDefaultHarnessPersistenceMetadata(to conversation: inout ModelConversation) {
        conversation.harnessPersistenceSource = "cli"
        conversation.harnessPersistenceTrustClass = "user"
        conversation.harnessPersistenceAgentId = SessionPersistenceConfiguration.sessionAgentId
        conversation.harnessPersistenceCwd = Self.harnessCatalogWorkingDirectoryIfKnown()
    }

    /// Second value is set when the catalog disambiguates ``SessionCatalogRecord/title``; callers should prefer it over the requested topic for UI and persistence.
    private func allocateBackendConversationIDIfNeeded(
        selectedModel: Model,
        topic: String?,
        description: String?,
        metadata: JSON?,
        interactionMode: InteractionMode,
        modeProfileID: String?,
        parentConversationID: UUID? = nil,
        forkAnchorEntryID: UUID? = nil,
        lineageKind: ConversationLineageKind = .root,
        origin: ConversationOrigin = .user
    ) throws -> (id: UUID, catalogResolvedTopic: String?) {
        let params = SessionConversationCreationParams(
            agentId: SessionPersistenceConfiguration.sessionAgentId,
            source: "cli",
            trustClass: "user",
            parentConversationID: parentConversationID,
            forkAnchorMessageID: forkAnchorEntryID,
            cwd: Self.harnessCatalogWorkingDirectoryIfKnown(),
            modelName: selectedModel.modelName,
            interactionModeRaw: interactionMode.rawValue,
            modeProfileID: modeProfileID,
            title: topic,
            topic: topic,
            description: description,
            userID: nil,
            lifecycleStateRaw: ConversationLifecycleState.active.rawValue,
            modelConfigJSON: nil,
            createdAt: Date(),
            lineageKind: lineageKind,
            origin: origin
        )
        do {
            let created = try harnessSessionPersistence.createConversation(params)
            return (created.id, created.title ?? created.topic)
        } catch let e as SessionPersistenceError {
            if case .unsupportedOperation = e {
                return (UUID(), nil)
            }
            throw e
        }
    }

    /// Attempts README `fork_conversation` allocation on the SessionBackend seam.
    /// Returns `usedBackendFork = false` when v2-create routing is disabled or the backend does not implement fork.
    private func allocateBackendForkConversationIDIfNeeded(
        parentConversationID: UUID,
        anchorMessageID: UUID,
        title: String?,
        childLineageKind: ConversationLineageKind = .branch,
        childOrigin: ConversationOrigin? = nil
    ) throws -> (id: UUID, catalogResolvedTopic: String?, usedBackendFork: Bool) {
        // Fork routing is Local-only. InMemory copy falls back to copyConversationViaHarnessTranscript;
        // split requires usesHarnessConversationRegistry and is unsupported on in-memory installs here.
        guard sessionBackend is LocalHarnessSessionPersistence else {
            return (UUID(), nil, false)
        }
        let newConversationID = UUID()
        let resolvedForkTitle = try nextForkLineageTitle(baseTitle: title)
        logger?.info("[ConversationManager] fork allocation parent=\(parentConversationID) anchor=\(anchorMessageID) requestedTitle=\(title ?? "nil") resolvedTitle=\(resolvedForkTitle ?? "nil")")
        do {
            let forked = try sessionBackend.forkConversation(
                parentConversationID: parentConversationID,
                atMessageID: anchorMessageID,
                newConversationId: newConversationID,
                title: resolvedForkTitle,
                childLineageKind: childLineageKind,
                childOrigin: childOrigin
            )
            logger?.info("[ConversationManager] fork allocation success parent=\(parentConversationID) child=\(forked.id) title=\(forked.title ?? "nil")")
            return (forked.id, forked.title ?? forked.topic, true)
        } catch let e as SessionPersistenceError {
            logger?.error("[ConversationManager] fork allocation failed parent=\(parentConversationID) anchor=\(anchorMessageID) requestedTitle=\(title ?? "nil") resolvedTitle=\(resolvedForkTitle ?? "nil") error=\(e)")
            if case .unsupportedOperation = e {
                return (UUID(), nil, false)
            }
            throw e
        }
    }

    /// Derives deterministic fork lineage titles (`base #N`) to avoid catalog title collisions.
    /// Returning `nil` preserves nil/empty titles.
    func nextForkLineageTitle(baseTitle: String?) throws -> String? {
        guard let baseTitle else { return nil }
        let normalizedBase = SessionTitleResolution.sanitizedTitle(baseTitle)
        guard !normalizedBase.isEmpty else { return nil }

        let records = try sessionBackend.listCatalogConversations()
        let prefix = "\(normalizedBase) #"
        var maxOrdinal = 0
        for record in records {
            guard let storedTitle = record.title else { continue }
            guard SessionTitleResolution.storedTitleMatchesLineage(baseTitle: normalizedBase, storedTitle: storedTitle) else { continue }
            if storedTitle == normalizedBase {
                maxOrdinal = max(maxOrdinal, 0)
                continue
            }
            guard storedTitle.hasPrefix(prefix) else { continue }
            let suffix = String(storedTitle.dropFirst(prefix.count))
            guard let n = Int(suffix) else { continue }
            maxOrdinal = max(maxOrdinal, n)
        }
        return "\(normalizedBase) #\(maxOrdinal + 1)"
    }

    private func requireRegistryModelConversation(
        id: UUID,
        fallbackModel: Model? = nil
    ) throws -> ModelConversation {
        if let loaded = modelConversation(id: id) {
            return loaded
        }
        if let hydrated = try hydrateConversationFromCatalogIntoRegistry(
            id: id,
            preferredModel: fallbackModel,
            isModelAvailable: true
        ) {
            return hydrated
        }
        throw ConversationServiceError.conversationNotFound
    }

    private func copyConversationViaHarnessTranscript(
        from source: ModelConversation,
        to model: Model,
        systemPrompt: String
    ) throws -> ModelConversation {
        let mode = source.interactionMode
        let (newConversationID, catalogTopic) = try allocateBackendConversationIDIfNeeded(
            selectedModel: model,
            topic: source.topic,
            description: source.description,
            metadata: source.metadata,
            interactionMode: mode,
            modeProfileID: source.modeProfileID
        )
        let createdAt = Date()
        let systemMessage = Message(id: UUID(), role: .system, content: systemPrompt, timestamp: Date())
        var copiedMessages: [Message] = [systemMessage]
        var lastUpdatedAt = systemMessage.timestamp
        for message in source.messages where message.role != .system {
            let copy = Message(
                id: UUID(),
                role: message.role,
                content: message.content,
                timestamp: message.timestamp,
                images: message.images,
                toolCalls: message.toolCalls,
                toolCallId: message.toolCallId,
                responseFormat: message.responseFormat,
                inputTrustRaw: message.inputTrustRaw
            )
            copiedMessages.append(copy)
            if copy.timestamp > lastUpdatedAt {
                lastUpdatedAt = copy.timestamp
            }
        }
        var newConversation = ModelConversation(
            id: newConversationID,
            model: model,
            createdAt: createdAt,
            updatedAt: lastUpdatedAt,
            systemPrompt: systemPrompt,
            topic: catalogTopic ?? source.topic,
            description: source.description,
            interactionMode: mode,
            modeProfileID: source.modeProfileID,
            metadata: source.metadata,
            ownerAccountID: source.ownerAccountID
        )
        newConversation.messages = copiedMessages
        newConversation.turns = conversationTurns(interactionMode: mode, messages: copiedMessages)
        newConversation.harnessPersistenceSource = source.harnessPersistenceSource ?? "cli"
        newConversation.harnessPersistenceTrustClass = source.harnessPersistenceTrustClass ?? "user"
        newConversation.harnessPersistenceAgentId = source.harnessPersistenceAgentId ?? SessionPersistenceConfiguration.sessionAgentId
        newConversation.harnessPersistenceCwd = source.harnessPersistenceCwd ?? Self.harnessCatalogWorkingDirectoryIfKnown()
        if catalogRowExists(conversationID: newConversationID) {
            try appendMessagesToHarnessTranscript(conversationID: newConversationID, messages: copiedMessages)
            try syncConversationCatalogStateToSessionBackend(conversation: newConversation)
        }
        copyConversationDirectoryIfNeeded(from: source.id, to: newConversationID)
        var messageStorageIdMap: [UUID: UUID] = [:]
        let sourceNonSystem = source.messages.filter { $0.role != .system }.sorted { $0.timestamp < $1.timestamp }
        let copiedNonSystem = copiedMessages.filter { $0.role != .system }
        for (oldMessage, newMessage) in zip(sourceNonSystem, copiedNonSystem) {
            messageStorageIdMap[oldMessage.id] = newMessage.id
        }
        try? copyInheritedJournalEventsForHarnessBranch(
            parentConversationID: source.id,
            childConversationID: newConversationID,
            messageStorageIdMap: messageStorageIdMap,
            parentSystemPrompt: source.systemPrompt,
            childSystemPrompt: systemPrompt
        )
        conversations.append(newConversation)
        return newConversation
    }

    // MARK: - Create / copy / delete

    func createConversation(
        with selectedModel: Model,
        userSystemPrompt: String,
        topic: String? = nil,
        description: String? = nil,
        metadata: JSON? = nil,
        interactionMode: InteractionMode = .chat,
        modeProfileID: String? = nil,
        ownerAccountID: UUID? = nil,
        lineageKind: ConversationLineageKind = .root,
        origin: ConversationOrigin = .user
    ) throws -> ModelConversation {
        let (conversationID, catalogTopic) = try allocateBackendConversationIDIfNeeded(
            selectedModel: selectedModel,
            topic: topic,
            description: description,
            metadata: metadata,
            interactionMode: interactionMode,
            modeProfileID: modeProfileID,
            lineageKind: lineageKind,
            origin: origin
        )
        let effectiveTopic = catalogTopic ?? topic
        let createdAt = Date()
        let systemMessage = Message(id: UUID(), role: .system, content: userSystemPrompt, timestamp: Date())
        let mode = interactionMode
        var newConversation = ModelConversation(
            id: conversationID,
            model: selectedModel,
            createdAt: createdAt,
            updatedAt: createdAt,
            systemPrompt: userSystemPrompt,
            topic: effectiveTopic,
            description: description,
            interactionMode: mode,
            modeProfileID: modeProfileID,
            metadata: metadata,
            ownerAccountID: ownerAccountID,
            lineageKind: lineageKind,
            origin: origin
        )
        newConversation.messages.append(systemMessage)
        newConversation.turns = conversationTurns(interactionMode: mode, messages: newConversation.messages)
        applyDefaultHarnessPersistenceMetadata(to: &newConversation)

        if catalogRowExists(conversationID: conversationID) {
            try appendMessagesToHarnessTranscript(conversationID: conversationID, messages: [systemMessage])
            try syncConversationCatalogStateToSessionBackend(conversation: newConversation)
            if let record = try sessionBackend.catalogConversation(id: conversationID) {
                newConversation.controlPlaneRevision = UInt64(record.controlPlaneRevision)
            }
        }

        if mode == .plan || mode == .agent {
            try? AgentPlanStore.ensureConversationDirectory(for: conversationID)
        }

        conversations.append(newConversation)
        return newConversation
    }

    /// Creates a child conversation under ``parentConversationID`` with an empty transcript (system message only).
    func createIsolatedSubAgent(
        parentConversationID: UUID,
        selectedModel: Model,
        userSystemPrompt: String,
        topic: String? = nil,
        description: String? = nil,
        metadata: JSON? = nil,
        interactionMode: InteractionMode,
        modeProfileID: String?,
    ) throws -> ModelConversation {
        let parentConv = try requireRegistryModelConversation(id: parentConversationID, fallbackModel: selectedModel)

        let (conversationID, catalogTopic) = try allocateBackendConversationIDIfNeeded(
            selectedModel: selectedModel,
            topic: topic,
            description: description,
            metadata: metadata,
            interactionMode: interactionMode,
            modeProfileID: modeProfileID,
            parentConversationID: parentConversationID,
            lineageKind: .subAgent,
            origin: .system
        )
        let effectiveTopic = catalogTopic ?? topic
        let createdAt = Date()
        let systemMessage = Message(id: UUID(), role: .system, content: userSystemPrompt, timestamp: Date())
        let mode = interactionMode

        var newConversation = ModelConversation(
            id: conversationID,
            model: selectedModel,
            createdAt: createdAt,
            updatedAt: createdAt,
            systemPrompt: userSystemPrompt,
            topic: effectiveTopic,
            description: description,
            interactionMode: mode,
            modeProfileID: modeProfileID,
            metadata: metadata,
            parentConversationID: parentConversationID,
            ownerAccountID: parentConv.ownerAccountID,
            lineageKind: .subAgent,
            origin: .system
        )
        newConversation.messages = [systemMessage]
        newConversation.turns = conversationTurns(interactionMode: mode, messages: newConversation.messages)
        applyDefaultHarnessPersistenceMetadata(to: &newConversation)
        newConversation.harnessPersistenceCwd = parentConv.harnessPersistenceCwd ?? newConversation.harnessPersistenceCwd

        conversations.append(newConversation)

        if catalogRowExists(conversationID: conversationID) {
            try appendMessagesToHarnessTranscript(conversationID: conversationID, messages: [systemMessage])
            try syncConversationCatalogStateToSessionBackend(conversation: newConversation)
        }

        if mode == .plan || mode == .agent {
            try? AgentPlanStore.ensureConversationDirectory(for: conversationID)
        }

        return newConversation
    }

    func copyConversation(from sourceConversationID: UUID, to model: Model, systemPrompt: String) throws -> ModelConversation {
        let sourceConv = try requireRegistryModelConversation(id: sourceConversationID, fallbackModel: model)
        let orderedRegistryMessages = sourceConv.messages.sorted { $0.timestamp < $1.timestamp }
        let sourceTailHarnessMessageID = orderedRegistryMessages.last?.id
        let canRouteCopyThroughFork = systemPrompt == sourceConv.systemPrompt
        if canRouteCopyThroughFork, let sourceTailHarnessMessageID {
            let forkedAllocation = try allocateBackendForkConversationIDIfNeeded(
                parentConversationID: sourceConversationID,
                anchorMessageID: sourceTailHarnessMessageID,
                title: sourceConv.topic
            )
            if forkedAllocation.usedBackendFork {
                guard let record = try sessionBackend.catalogConversation(id: forkedAllocation.id) else {
                    throw ConversationServiceError.conversationNotFound
                }
                var newConversation = try catalogRecordToModelConversation(record: record, model: model, isModelAvailable: true)
                newConversation.messages = try messageShapedTranscriptMessages(conversationID: newConversation.id)
                newConversation.harnessPersistenceSource = sourceConv.harnessPersistenceSource ?? "cli"
                newConversation.harnessPersistenceTrustClass = sourceConv.harnessPersistenceTrustClass ?? "user"
                newConversation.harnessPersistenceAgentId = sourceConv.harnessPersistenceAgentId ?? SessionPersistenceConfiguration.sessionAgentId
                newConversation.harnessPersistenceCwd = sourceConv.harnessPersistenceCwd ?? Self.harnessCatalogWorkingDirectoryIfKnown()
                copyConversationDirectoryIfNeeded(from: sourceConversationID, to: newConversation.id)
                var forkMessageStorageIdMap: [UUID: UUID] = [:]
                for message in sourceConv.messages where message.role != .system {
                    forkMessageStorageIdMap[message.id] = message.id
                }
                try? copyInheritedJournalEventsForHarnessBranch(
                    parentConversationID: sourceConversationID,
                    childConversationID: newConversation.id,
                    messageStorageIdMap: forkMessageStorageIdMap,
                    parentSystemPrompt: sourceConv.systemPrompt,
                    childSystemPrompt: systemPrompt
                )
                conversations.append(newConversation)
                return newConversation
            }
        }
        if hydratesRegistryFromHarnessCatalog {
            return try copyConversationViaHarnessTranscript(from: sourceConv, to: model, systemPrompt: systemPrompt)
        }
        throw ConversationServiceError.conversationNotFound
    }

    /// Raw `plan.md` text for REST plan viewer; empty string if file missing. Conversation-plane peel.
    func readPlanMarkdown(for conversationID: UUID) throws -> String {
        guard modelConversation(id: conversationID) != nil else {
            throw ConversationServiceError.conversationNotFound
        }
        return AgentPlanStore.readPlanText(for: conversationID) ?? ""
    }

    func deleteConversation(conversationID: UUID) throws {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
            throw ConversationServiceError.conversationNotFound
        }
        conversations.remove(at: index)

        if (try? sessionBackend.catalogConversation(id: conversationID)) != nil {
            try harnessSessionPersistence.removeSessionConversation(conversationID: conversationID)
        }

        if !AgentPlanStore.removeConversationDirectory(for: conversationID) {
            logger?.warning("[ConversationManager] Failed to remove \(AgentPlanStore.conversationDirectoryURL(for: conversationID)) after delete")
        }
    }

    func persistSplitSelectingNewThread(
        sourceConversation: ModelConversation,
        atUserMessageID messageID: UUID,
        childLineageKind: ConversationLineageKind = .branch,
        childOrigin: ConversationOrigin? = nil
    ) throws -> (
        newConversationID: UUID,
        anchorNewUserMessageID: UUID,
        newConversation: ModelConversation
    ) {
        logger?.info("[ConversationManager] persistSplitSelectingNewThread start sourceConversationID=\(sourceConversation.id) anchorMessageID=\(messageID)")
        guard sourceConversation.isModelAvailable else {
            throw ConversationServiceError.modelUnavailable
        }
        let sourceConversationID = sourceConversation.id
        let sourceConv = try requireRegistryModelConversation(id: sourceConversationID, fallbackModel: sourceConversation.model)
        let model = sourceConversation.model
        let orderedRegistry = sourceConv.messages.sorted { $0.timestamp < $1.timestamp }
        guard let anchorIndex = orderedRegistry.firstIndex(where: { $0.id == messageID }) else {
            throw ConversationServiceError.invalidRevertTarget
        }
        guard orderedRegistry[anchorIndex].role == .user else {
            throw ConversationServiceError.invalidRevertTarget
        }
        logger?.info("[ConversationManager] persistSplitSelectingNewThread anchorResolved sourceConversationID=\(sourceConversationID) anchorIndex=\(anchorIndex) prefixCount=\(anchorIndex + 1)")

        if usesHarnessConversationRegistry {
            let inheritedModeSnapshot = resolveInheritedModeSnapshotForSplitAnchor(
                parentConversationID: sourceConversationID,
                anchorMessageID: messageID,
                fallbackInteractionModeRaw: sourceConv.interactionMode.rawValue,
                fallbackModeProfileID: sourceConv.modeProfileID
            )
            let forkedAllocation = try allocateBackendForkConversationIDIfNeeded(
                parentConversationID: sourceConversationID,
                anchorMessageID: messageID,
                title: sourceConv.topic,
                childLineageKind: childLineageKind,
                childOrigin: childOrigin
            )
            guard forkedAllocation.usedBackendFork else {
                logger?.error("[ConversationManager] split requires backend fork path but backend fallback was returned sourceConversationID=\(sourceConversationID)")
                throw SessionPersistenceError.unsupportedOperation("split_requires_backend_fork")
            }
            let (newConversationID, _, usedBackendFork) = forkedAllocation
            logger?.info("[ConversationManager] persistSplitSelectingNewThread usingBackendFork childConversationID=\(newConversationID)")
            guard let record = try sessionBackend.catalogConversation(id: newConversationID) else {
                throw ConversationServiceError.conversationNotFound
            }
            var newConversation = try catalogRecordToModelConversation(record: record, model: model, isModelAvailable: true)
            newConversation.messages = try messageShapedTranscriptMessages(conversationID: newConversation.id)
            newConversation.splitFromConversationID = sourceConversationID
            newConversation.splitThreadAfterMessageID = messageID
            newConversation.state = ModelState.generating
            newConversation.agenticPhase = ConversationAgenticPhase.started
            newConversation.llmRequestPhase = ConversationLLMRequestPhase.queued
            newConversation.updatedAt = Date()
            newConversation.harnessPersistenceSource = sourceConversation.harnessPersistenceSource
            newConversation.harnessPersistenceTrustClass = sourceConversation.harnessPersistenceTrustClass
            newConversation.harnessPersistenceAgentId = sourceConversation.harnessPersistenceAgentId ?? SessionPersistenceConfiguration.sessionAgentId
            newConversation.harnessPersistenceCwd = sourceConversation.harnessPersistenceCwd ?? Self.harnessCatalogWorkingDirectoryIfKnown()
            let splitMode = InteractionMode(rawValue: inheritedModeSnapshot.interactionModeRaw) ?? .chat
            newConversation.interactionMode = splitMode
            newConversation.modeProfileID = inheritedModeSnapshot.modeProfileID
            try copyInheritedJournalTranscriptEntriesForBranch(
                parentConversationID: sourceConversationID,
                childConversationID: newConversationID,
                anchorMessageID: messageID
            )
            try? appendBranchRef(
                parentConversationID: sourceConversationID,
                ref: ConversationBranchRef(childConversationID: newConversationID, branchedAtMessageID: messageID)
            )
            try? syncConversationCatalogStateToSessionBackend(conversation: newConversation)
            if let record = try sessionBackend.catalogConversation(id: newConversationID) {
                newConversation.controlPlaneRevision = UInt64(record.controlPlaneRevision)
            }
            copyConversationDirectoryIfNeeded(from: sourceConversationID, to: newConversationID)
            if splitMode == .plan || splitMode == .agent {
                try? AgentPlanStore.ensureConversationDirectory(for: newConversationID)
            }
            conversations.append(newConversation)
            logger?.info("[ConversationManager] persistSplitSelectingNewThread complete sourceConversationID=\(sourceConversationID) childConversationID=\(newConversationID) usedBackendFork=\(usedBackendFork)")
            return (newConversationID, messageID, newConversation)
        }

        throw ConversationServiceError.conversationNotFound
    }

    /// Mirrors catalog ``controlPlaneRevision`` on the in-memory ``ModelConversation`` (catalog writes already bump revision).
    func bumpControlPlaneRevision(conversationID: UUID) throws {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
            throw ConversationServiceError.conversationNotFound
        }
        var updated = conversations[index]
        if catalogRowExists(conversationID: conversationID),
           let record = try sessionBackend.catalogConversation(id: conversationID) {
            updated.controlPlaneRevision = UInt64(record.controlPlaneRevision)
        } else {
            updated.controlPlaneRevision += 1
        }
        conversations[index] = updated
    }

    /// Aligns in-memory ``ModelConversation`` with the v2 catalog topic after bootstrap disambiguation.
    func syncCachedTopicWithHarnessCatalog(conversationID: UUID, topic: String?) throws {
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            var updated = conversations[index]
            updated.topic = topic
            updated.updatedAt = Date()
            conversations[index] = updated
        }
    }

    // MARK: - Metadata / routing updates

    func updateConversationMetadata(
        conversationID: UUID,
        topic: String?,
        description: String?,
        metadata: JSON? = nil,
        interactionMode: InteractionMode? = nil,
        modeProfileID: String? = nil,
        skipControlPlaneRevisionBump: Bool = false
    ) throws -> Bool {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
            throw ConversationServiceError.conversationNotFound
        }

        let normalizedTopic = topic?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines)

        var updatedConversation = conversations[index]
        let priorModeProfileID = updatedConversation.modeProfileID
        updatedConversation.topic = (normalizedTopic?.isEmpty == false) ? normalizedTopic : nil
        updatedConversation.description = (normalizedDescription?.isEmpty == false) ? normalizedDescription : nil
        if let incoming = metadata {
            updatedConversation.metadata = ConversationMetadataActivatedSkills.mergingPreservingActivatedSkillNames(
                existing: conversations[index].metadata,
                incoming: incoming
            )
        } else {
            updatedConversation.metadata = nil
        }
        var modeChanged = false
        if let interactionMode {
            updatedConversation.interactionMode = interactionMode
            updatedConversation.modeProfileID = modeProfileID ?? interactionMode.rawValue
            modeChanged = true
        }
        if interactionMode == nil {
            updatedConversation.modeProfileID = modeProfileID ?? updatedConversation.modeProfileID
        }
        if updatedConversation.modeProfileID != priorModeProfileID {
            modeChanged = true
        }
        updatedConversation.updatedAt = Date()
        conversations[index] = updatedConversation

        try syncConversationCatalogStateToSessionBackend(conversation: updatedConversation)
        try? syncConversationTurnsInCache(conversationID: conversationID, interactionMode: updatedConversation.interactionMode)

        if modeChanged {
            let mode = updatedConversation.interactionMode
            if mode == .plan || mode == .agent {
                try? AgentPlanStore.ensureConversationDirectory(for: conversationID)
            }
        }
        if !skipControlPlaneRevisionBump {
            try bumpControlPlaneRevision(conversationID: conversationID)
        }
        return modeChanged
    }

    func stampTriggerHostConversation(
        conversationID: UUID,
        trigger: HarnessTrigger,
        sessionKey: String
    ) throws {
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            let existing = conversations[index]
            if TriggerHostConversationMetadata.isFullyConfiguredTriggerHost(
                metadata: existing.metadata,
                lineageKind: existing.lineageKind,
                origin: existing.origin
            ) {
                return
            }
            var updated = existing
            let metadata = TriggerHostConversationMetadata.stampHostMetadata(
                existing: updated.metadata,
                trigger: trigger,
                sessionKey: sessionKey
            )
            updated.metadata = ConversationMetadataActivatedSkills.mergingPreservingActivatedSkillNames(
                existing: updated.metadata,
                incoming: metadata
            )
            updated.lineageKind = .root
            updated.origin = .system
            updated.modeProfileID = updated.modeProfileID ?? "trigger-host"
            updated.updatedAt = Date()
            conversations[index] = updated
            try syncConversationCatalogStateToSessionBackend(conversation: updated)
            return
        }
        guard var record = try sessionBackend.catalogConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        let existingMetadata = record.metadataJSON.flatMap { json in
            try? JSONDecoder().decode(JSON.self, from: Data(json.utf8))
        }
        if TriggerHostConversationMetadata.isFullyConfiguredTriggerHost(
            metadata: existingMetadata,
            lineageKind: record.lineageKind,
            origin: record.origin
        ) {
            return
        }
        let metadata = TriggerHostConversationMetadata.stampHostMetadata(
            existing: existingMetadata,
            trigger: trigger,
            sessionKey: sessionKey
        )
        record.lineageKind = .root
        record.origin = .system
        record.metadataJSON = SessionCatalogRecord.metadataJSONString(from: metadata)
        record.modeProfileID = record.modeProfileID ?? "trigger-host"
        var patch = SessionConversationUpdatePatch()
        patch.lineageKind = .set(.root)
        patch.origin = .set(.system)
        patch.metadataJSON = .set(record.metadataJSON)
        patch.modeProfileID = .set(record.modeProfileID)
        patch.updatedAt = .set(Date())
        _ = try harnessSessionPersistence.updateSessionConversation(
            conversationID: conversationID,
            patch: patch,
            expectedRevision: UInt64(record.controlPlaneRevision)
        )
    }

    func updateConversationModelAndUserPrompt(conversationID: UUID, model: Model?, userSystemPrompt: String?, skipControlPlaneRevisionBump: Bool = false) throws -> ModelConversation {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
            throw ConversationServiceError.conversationNotFound
        }

        let prior = conversations[index]
        let modelChange = model.map { $0.id != prior.model.id } ?? false
        let promptChange: Bool = {
            guard let p = userSystemPrompt else { return false }
            return p != prior.systemPrompt
        }()

        guard modelChange || promptChange else {
            throw ConversationServiceError.noMeaningfulModelOrPromptChange
        }

        var updatedConversation = prior

        if modelChange, let newModel = model {
            updatedConversation.model = newModel
            updatedConversation.isModelAvailable = true
        }

        if promptChange, let newPrompt = userSystemPrompt {
            updatedConversation.systemPrompt = newPrompt
            if let sysIdx = updatedConversation.messages.firstIndex(where: { $0.role == .system }) {
                let old = updatedConversation.messages[sysIdx]
                updatedConversation.messages[sysIdx] = Message(
                    id: old.id,
                    role: .system,
                    content: newPrompt,
                    timestamp: old.timestamp,
                    images: old.images,
                    toolCalls: old.toolCalls,
                    toolCallId: old.toolCallId,
                    responseFormat: old.responseFormat
                )
            } else {
                let newId = UUID()
                let ts = Date()
                updatedConversation.messages.insert(
                    Message(id: newId, role: .system, content: newPrompt, timestamp: ts),
                    at: 0
                )
            }
        }

        updatedConversation.updatedAt = Date()
        conversations[index] = updatedConversation

        if promptChange, let sys = updatedConversation.messages.first(where: { $0.role == .system }) {
            try persistSystemPromptChangeToHarnessTranscript(conversationID: conversationID, systemMessage: sys)
        }
        try syncConversationCatalogStateToSessionBackend(conversation: updatedConversation)

        if !skipControlPlaneRevisionBump {
            try bumpControlPlaneRevision(conversationID: conversationID)
        }
        return updatedConversation
    }

    func updateConversationThinkingConfig(conversationID: UUID, thinkingConfig: ThinkingConfig?, skipControlPlaneRevisionBump: Bool = false) throws {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
            throw ConversationServiceError.conversationNotFound
        }

        var updatedConversation = conversations[index]
        var prefs = updatedConversation.routingPrefs ?? ConversationRoutingPrefs()
        var modelOptions = prefs.modelOptions ?? ConversationRoutingModelOptions()
        modelOptions.thinkingConfig = thinkingConfig
        prefs.modelOptions = modelOptions
        updatedConversation.routingPrefs = prefs
        updatedConversation.updatedAt = Date()
        conversations[index] = updatedConversation

        try syncConversationCatalogStateToSessionBackend(conversation: updatedConversation)
        if !skipControlPlaneRevisionBump {
            try bumpControlPlaneRevision(conversationID: conversationID)
        }
    }

    func persistConversationMetadataToCache(conversationID: UUID, metadata: JSON?) throws {
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            var updated = conversations[index]
            updated.metadata = metadata
            conversations[index] = updated
            try? syncConversationCatalogStateToSessionBackend(conversation: updated)
        }
    }

    /// Called from ``HarnessRuntimeSession`` after persisting new messages (same semantics as the former private helper).
    func syncConversationTurnsInCache(
        conversationID: UUID,
        interactionMode: InteractionMode,
        preferredTurns: [ConversationTurn]? = nil
    ) throws {
        try syncConversationTurnsInCacheImpl(
            conversationID: conversationID,
            interactionMode: interactionMode,
            preferredTurns: preferredTurns
        )
    }

    func syncConversationCatalogStateToSessionBackend(conversation: ModelConversation) throws {
        logger?.info("[ConversationManager] syncConversationCatalogStateToSessionBackend start conversationID=\(conversation.id) title=\(conversation.topic ?? "nil") topic=\(conversation.topic ?? "nil") mode=\(conversation.interactionMode.rawValue) controlPlaneRevision=\(conversation.controlPlaneRevision)")
        if let inMemory = harnessSessionPersistence as? InMemoryHarnessSessionPersistence {
            try bootstrapInMemoryCatalogIfMissing(inMemory, conversation: conversation)
        } else if !(harnessSessionPersistence is LocalHarnessSessionPersistence) {
            return
        }
        var patch = SessionConversationUpdatePatch()
        patch.topic = .set(conversation.topic)
        patch.description = .set(conversation.description)
        patch.modelName = .set(conversation.model.modelName)
        patch.interactionModeRaw = .set(conversation.interactionMode.rawValue)
        patch.modeProfileID = .set(conversation.modeProfileID)
        patch.source = .set(conversation.harnessPersistenceSource)
        patch.trustClass = .set(conversation.harnessPersistenceTrustClass)
        patch.parentConversationID = .set(conversation.parentConversationID)
        patch.userID = .set(conversation.ownerAccountID?.uuidString)
        patch.lifecycleStateRaw = .set(conversation.lifecycle.rawValue)
        patch.title = .set(conversation.topic)
        patch.cwd = .set(conversation.harnessPersistenceCwd)
        patch.updatedAt = .set(conversation.updatedAt)
        patch.endedAt = .set(conversation.lifecycle == .active ? nil : conversation.updatedAt)
        patch.endReason = .set(conversation.lifecycle == .active ? nil : conversation.lifecycle.rawValue)
        patch.modelConfigJSON = .set(SessionCatalogResourceCodec.modelConfigJSONHint(from: conversation))
        patch.resourceJSON = .set(SessionCatalogResourceCodec.encode(conversation))
        patch.currentRunID = .set(conversation.currentRunID)
        patch.lastActiveAt = .set(conversation.lastActiveAt ?? conversation.updatedAt)
        patch.resourceRunStatusRaw = .set(conversation.inferredResourceRunStatusForPersistence().rawValue)
        patch.metadataJSON = .set(SessionCatalogRecord.metadataJSONString(from: conversation.metadata))
        patch.systemPrompt = .set(conversation.systemPrompt.isEmpty ? nil : conversation.systemPrompt)
        patch.firstUserPrompt = .set(conversation.messages.first(where: { $0.role == .user })?.content)
        patch.lineageKind = .set(conversation.lineageKind)
        patch.origin = .set(conversation.origin)
        do {
            let record = try harnessSessionPersistence.updateSessionConversation(
                conversationID: conversation.id,
                patch: patch,
                expectedRevision: conversation.controlPlaneRevision
            )
            if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
                conversations[index].controlPlaneRevision = UInt64(record.controlPlaneRevision)
            }
            logger?.info("[ConversationManager] syncConversationCatalogStateToSessionBackend success conversationID=\(conversation.id) controlPlaneRevision=\(record.controlPlaneRevision)")
        } catch {
            logger?.error("[ConversationManager] syncConversationCatalogStateToSessionBackend failed conversationID=\(conversation.id) title=\(conversation.topic ?? "nil") error=\(error)")
            throw error
        }
    }

    private func bootstrapInMemoryCatalogIfMissing(
        _ inMemory: InMemoryHarnessSessionPersistence,
        conversation: ModelConversation
    ) throws {
        if try inMemory.catalogConversation(id: conversation.id) != nil {
            return
        }
        var record = SessionCatalogRecord(
            id: conversation.id,
            topic: conversation.topic,
            description: conversation.description,
            messageCount: conversation.messages.count,
            updatedAt: conversation.updatedAt,
            createdAt: conversation.createdAt,
            modelName: conversation.model.modelName,
            interactionModeRaw: conversation.interactionMode.rawValue,
            modeProfileID: conversation.modeProfileID
        )
        record.source = conversation.harnessPersistenceSource
        record.trustClass = conversation.harnessPersistenceTrustClass
        record.parentConversationID = conversation.parentConversationID
        record.userID = conversation.ownerAccountID?.uuidString
        record.lifecycleStateRaw = conversation.lifecycle.rawValue
        record.title = conversation.topic
        record.cwd = conversation.harnessPersistenceCwd
        record.agentId = SessionPersistenceLayout.defaultAgentId
        try inMemory.bootstrapEmptyConversation(record)
    }

    func encodeConversationMetadataJSON(_ metadata: JSON?) -> String? {
        guard let metadata,
              let data = try? JSONEncoder().encode(metadata) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func catalogRecordToModelConversation(
        record: SessionCatalogRecord,
        model: Model,
        isModelAvailable: Bool = true
    ) throws -> ModelConversation {
        let mode = InteractionMode(rawValue: record.interactionModeRaw) ?? .chat
        var newConversation = ModelConversation(
            id: record.id,
            model: model,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            systemPrompt: record.systemPrompt ?? "",
            topic: record.title ?? record.topic,
            description: record.description,
            isModelAvailable: isModelAvailable,
            interactionMode: mode,
            modeProfileID: record.modeProfileID,
            metadata: metadataFromCatalogRecord(record),
            splitFromConversationID: nil,
            splitThreadAfterMessageID: record.forkAnchorEntryID.flatMap {
                SessionEntryID.messageUUID(for: $0, in: (try? harnessSessionPersistence.readTranscriptEntries(conversationID: record.id, request: .full)) ?? [])
            },
            lineageKind: record.lineageKind,
            origin: record.origin
        )
        newConversation.controlPlaneRevision = UInt64(record.controlPlaneRevision)
        newConversation.parentConversationID = record.parentConversationID
        newConversation.harnessPersistenceSource = record.source
        newConversation.harnessPersistenceTrustClass = record.trustClass
        newConversation.harnessPersistenceCwd = record.cwd
        newConversation.harnessPersistenceAgentId = record.agentId
        newConversation.transcriptIntegrity = Self.conversationTranscriptIntegrity(from: record.transcriptIntegrity)
        if let raw = record.lifecycleStateRaw,
           let lifecycle = ConversationLifecycleState(rawValue: raw) {
            newConversation.lifecycle = lifecycle
        }
        hydrateConversationResourceFields(from: record, into: &newConversation)
        applyThinkingConfigHint(from: record.modelConfigJSON, into: &newConversation)

        do {
            newConversation.messages = try ConversationTranscriptLineage.activeMessages(
                conversationID: record.id,
                harness: harnessSessionPersistence
            )
        } catch {
            logger?.warning("catalogRecordToModelConversation transcript read failed conversationID=\(record.id) error=\(error)")
            if newConversation.transcriptIntegrity?.state != .quarantined {
                newConversation.messages = []
            }
        }
        if newConversation.systemPrompt.isEmpty,
           let systemContent = newConversation.messages.first(where: { $0.role == .system })?.content {
            newConversation.systemPrompt = systemContent
        }
        if mode == .agent {
            newConversation.turns = conversationTurns(messages: newConversation.messages)
        }
        return newConversation
    }

    static func conversationTranscriptIntegrity(from record: SessionTranscriptIntegrity?) -> ConversationTranscriptIntegrity? {
        guard let record else { return nil }
        let state: ConversationTranscriptIntegrityState = record.state == .quarantined ? .quarantined : .ok
        return ConversationTranscriptIntegrity(state: state, reason: record.reason)
    }

    func refreshTranscriptIntegrityFromMaintenance(report: SessionTranscriptIntegrityReport) throws {
        let affected = Set(report.samples.map(\.conversationID))
        guard !affected.isEmpty else { return }
        for conversationID in affected {
            guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { continue }
            guard let record = try harnessSessionPersistence.catalogConversation(id: conversationID) else { continue }
            var updated = conversations[index]
            updated.transcriptIntegrity = Self.conversationTranscriptIntegrity(from: record.transcriptIntegrity)
            if report.samples.contains(where: { $0.conversationID == conversationID && $0.maintenanceAction == .autoRepaired }) {
                updated.messages = try ConversationTranscriptLineage.activeMessages(
                    conversationID: conversationID,
                    harness: harnessSessionPersistence
                )
            }
            conversations[index] = updated
        }
    }

    private func metadataFromCatalogRecord(_ record: SessionCatalogRecord) -> JSON? {
        let json = record.metadataJSON
            ?? SessionCatalogResourceCodec.decode(record.resourceJSON)?.metadataJSON
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSON.self, from: data)
    }

    private func applyThinkingConfigHint(from modelConfigJSON: String?, into conversation: inout ModelConversation) {
        struct Hint: Codable { var thinkingConfig: ThinkingConfig? }
        guard let modelConfigJSON,
              let data = modelConfigJSON.data(using: .utf8),
              let hint = try? JSONDecoder().decode(Hint.self, from: data),
              let thinkingConfig = hint.thinkingConfig else {
            return
        }
        var prefs = conversation.routingPrefs ?? ConversationRoutingPrefs()
        var options = prefs.modelOptions ?? ConversationRoutingModelOptions()
        options.thinkingConfig = thinkingConfig
        prefs.modelOptions = options
        conversation.routingPrefs = prefs
    }

    // MARK: - Private

    private func decodeMessageIDsJSON(_ json: String) -> [UUID] {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return raw.compactMap(UUID.init(uuidString:))
    }

    private func encodeMessageIDsJSON(_ ids: [UUID]) -> String {
        let values = ids.map(\.uuidString)
        guard let data = try? JSONEncoder().encode(values),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private struct TurnSeed {
        let party: TurnParty
        let messageIDs: [UUID]
        let metadataJSON: String?
        let createdAt: Date?
        let updatedAt: Date?
    }

    private func turnSeedsFromMessages(_ messages: [Message]) -> [TurnSeed] {
        guard !messages.isEmpty else { return [] }
        var output: [TurnSeed] = []

        func append(party: TurnParty, ids: [UUID], first: Date?, last: Date?) {
            guard !ids.isEmpty else { return }
            output.append(TurnSeed(party: party, messageIDs: ids, metadataJSON: nil, createdAt: first, updatedAt: last))
        }

        var currentParty: TurnParty?
        var currentIDs: [UUID] = []
        var firstDate: Date?
        var lastDate: Date?
        var previousNonSystemMessage: Message?

        for message in messages {
            if message.role == .system {
                continue
            }
            let party: TurnParty = message.role == .user ? .user : .assistant
            let shouldSplitForAssistantNudge = {
                guard currentParty == .assistant, party == .assistant else { return false }
                guard let previous = previousNonSystemMessage else { return false }
                return previous.role == .assistant
                    && previous.toolCalls.isEmpty
                    && message.role == .assistant
            }()

            if currentParty == nil {
                currentParty = party
                firstDate = message.timestamp
            } else if currentParty != party || party == .user || shouldSplitForAssistantNudge {
                append(party: currentParty ?? .assistant, ids: currentIDs, first: firstDate, last: lastDate)
                currentIDs = []
                currentParty = party
                firstDate = message.timestamp
                lastDate = nil
            }
            currentIDs.append(message.id)
            lastDate = message.timestamp
            previousNonSystemMessage = message
        }

        append(party: currentParty ?? .assistant, ids: currentIDs, first: firstDate, last: lastDate)
        return output
    }

    private func turnSeedsFromConversationTurns(_ turns: [ConversationTurn]) -> [TurnSeed] {
        turns.compactMap { turn in
            guard !turn.messageIDs.isEmpty else { return nil }
            return TurnSeed(
                party: turn.party,
                messageIDs: turn.messageIDs,
                metadataJSON: turn.metadataJSON,
                createdAt: turn.createdAt,
                updatedAt: turn.updatedAt
            )
        }
    }

    private func syncConversationTurnsInCacheImpl(
        conversationID: UUID,
        interactionMode: InteractionMode,
        preferredTurns: [ConversationTurn]? = nil
    ) throws {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
            throw ConversationServiceError.conversationNotFound
        }

        guard interactionMode == .agent else {
            if !conversations[index].turns.isEmpty {
                conversations[index].turns = []
            }
            return
        }

        let seeds: [TurnSeed] = {
            if let preferredTurns, !preferredTurns.isEmpty {
                return turnSeedsFromConversationTurns(preferredTurns)
            }
            let ordered = conversations[index].messages.sorted { $0.timestamp < $1.timestamp }
            return turnSeedsFromMessages(ordered)
        }()

        var metadataByMessageIDsJSON: [String: String] = [:]
        for turn in conversations[index].turns {
            if let metadata = turn.metadataJSON {
                metadataByMessageIDsJSON[encodeMessageIDsJSON(turn.messageIDs)] = metadata
            }
        }

        conversations[index].turns = seeds.map { seed in
            let idsJSON = encodeMessageIDsJSON(seed.messageIDs)
            return ConversationTurn(
                id: UUID(),
                party: seed.party,
                messageIDs: seed.messageIDs,
                metadataJSON: seed.metadataJSON ?? metadataByMessageIDsJSON[idsJSON],
                createdAt: seed.createdAt,
                updatedAt: seed.updatedAt
            )
        }
    }

    private func copyConversationDirectoryIfNeeded(from sourceConversationID: UUID, to newConversationID: UUID) {
        let sourceURL = AgentPlanStore.conversationDirectoryURL(for: sourceConversationID)
        let destinationURL = AgentPlanStore.conversationDirectoryURL(for: newConversationID)
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return
        }

        do {
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            logger?.warning(
                "[ConversationManager] Failed to copy \(sourceURL.path) to \(destinationURL.path): \(error)"
            )
        }
    }
}
