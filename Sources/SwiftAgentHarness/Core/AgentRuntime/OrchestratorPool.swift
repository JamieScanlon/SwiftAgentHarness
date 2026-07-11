import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator

struct OrchestratorKey: Hashable, Sendable {
    let conversationID: UUID
    let modelName: String
}

struct OrchestratorHandle: Hashable, Sendable {
    let key: OrchestratorKey
    let entryID: UUID
}

struct OrchestratorPoolEntryTokenSnapshot: Sendable {
    var lastPromptTokens: Int?
    var lastContextLimitTokens: Int?
    var lastRemainingContextTokens: Int?
    var lastModelRequestAt: Date?
}

struct OrchestratorAcquisition: Sendable {
    let handle: OrchestratorHandle
    let orchestrator: SwiftAgentKitOrchestrator
    let queuedLLM: QueuedLLM
}

typealias OrchestratorPoolTeardown = @Sendable (SwiftAgentKitOrchestrator) async -> Void
typealias OrchestratorPoolBuildFactory = @Sendable () async -> BuiltOrchestrator?

/// Per-(conversationID, model) orchestrator pool. Serializes all mutations in the actor.
///
/// **In-flight invalidate:** `invalidate(conversationID:)` is a no-op while the first `acquire`
/// for that conversation is still in `buildIfMissing` (no keyed entry exists yet). A mode change
/// racing that window may produce a stale-config orchestrator on first use.
actor OrchestratorPool {
    private struct Entry {
        let id: UUID
        let key: OrchestratorKey
        var orchestrator: SwiftAgentKitOrchestrator
        var queuedLLM: QueuedLLM
        var refCount: Int
        var lastUsedAt: Date
        var lifecycle: ChatRuntimeLifecycle
        var tokenSnapshot: OrchestratorPoolEntryTokenSnapshot
        var lastOrchestrationEmissionConversationID: UUID?
        var pendingInvalidation: Bool
    }

    private let maxEntries: Int
    private let idleTTLSeconds: TimeInterval
    private var entriesByID: [UUID: Entry] = [:]
    private var entryIDByKey: [OrchestratorKey: UUID] = [:]
    private var entryIDByConversation: [UUID: UUID] = [:]
    private var inFlightBuilds: [OrchestratorKey: Task<UUID?, Never>] = [:]
    private var pinnedOrchestratorConversationID: UUID?
    private var teardownHandler: OrchestratorPoolTeardown?
    private var pendingTeardownByKey: [OrchestratorKey: Task<Void, Never>] = [:]
    private var teardownGenerationByKey: [OrchestratorKey: UInt64] = [:]

    init(maxEntries: Int = Int.max, idleTTLSeconds: TimeInterval = 300) {
        self.maxEntries = max(1, maxEntries)
        self.idleTTLSeconds = idleTTLSeconds
    }

    func setTeardownHandler(_ handler: @escaping OrchestratorPoolTeardown) {
        teardownHandler = handler
    }

    func entryCount() -> Int { entriesByID.count }

    func clearBinding() async {
        let ids = Array(entriesByID.keys)
        for id in ids {
            await removeEntry(id: id, force: true)
        }
        pinnedOrchestratorConversationID = nil
    }

    // MARK: - Conversation-keyed resolution

    func orchestrator(for conversationID: UUID) -> SwiftAgentKitOrchestrator? {
        guard let entryID = entryIDByConversation[conversationID],
              let entry = entriesByID[entryID] else {
            return nil
        }
        return entry.orchestrator
    }

    func orchestratorConversationID(for conversationID: UUID) -> UUID? {
        guard entryIDByConversation[conversationID] != nil else { return nil }
        return conversationID
    }

    func queuedLLM(for conversationID: UUID) -> QueuedLLM? {
        guard let entryID = entryIDByConversation[conversationID],
              let entry = entriesByID[entryID] else {
            return nil
        }
        return entry.queuedLLM
    }

    // MARK: - Acquire / release

    func acquire(
        conversationID: UUID,
        modelName: String,
        buildIfMissing: @escaping OrchestratorPoolBuildFactory
    ) async -> OrchestratorAcquisition? {
        let key = OrchestratorKey(conversationID: conversationID, modelName: modelName)
        if let entryID = entryIDByKey[key], var entry = entriesByID[entryID] {
            return bumpAcquisition(key: key, entryID: entryID, entry: &entry)
        }
        if let inFlight = inFlightBuilds[key] {
            guard let entryID = await inFlight.value else { return nil }
            return acquisition(for: entryID, key: key)
        }
        let buildTask = Task {
            await completeAcquireBuild(
                key: key,
                conversationID: conversationID,
                buildIfMissing: buildIfMissing
            )
        }
        inFlightBuilds[key] = buildTask
        let entryID = await buildTask.value
        inFlightBuilds.removeValue(forKey: key)
        guard let entryID else { return nil }
        return reservedAcquisition(for: entryID, key: key)
    }

    func release(_ handle: OrchestratorHandle) async {
        guard var entry = entriesByID[handle.entryID] else { return }
        entry.refCount = max(0, entry.refCount - 1)
        entry.lastUsedAt = Date()
        if entry.refCount == 0, entry.pendingInvalidation {
            await removeEntry(id: handle.entryID, force: true)
            return
        }
        entriesByID[handle.entryID] = entry
        await evictIdle()
    }

    func invalidate(conversationID: UUID) async {
        guard let entryID = entryIDByConversation[conversationID],
              var entry = entriesByID[entryID] else {
            return
        }
        unhookEntryFromLookup(entry)
        if entry.refCount > 0 {
            entry.pendingInvalidation = true
            entriesByID[entryID] = entry
            return
        }
        await removeEntry(id: entryID, force: true)
    }

    func evictIdle() async {
        let now = Date()
        let candidateIDs = entriesByID.values
            .filter { $0.refCount == 0 && !$0.pendingInvalidation }
            .filter { now.timeIntervalSince($0.lastUsedAt) >= idleTTLSeconds }
            .sorted { $0.lastUsedAt < $1.lastUsedAt }
            .map(\.id)
        for id in candidateIDs {
            guard let entry = entriesByID[id], entry.refCount == 0 else { continue }
            await removeEntry(id: id, force: true)
        }
        while entriesByID.count > maxEntries {
            guard await evictOneIdleEntryIfPossible() else { break }
        }
    }

    // MARK: - Per-entry lifecycle

    func lifecycleSnapshot(for conversationID: UUID) -> ChatRuntimeLifecycle? {
        guard let entryID = entryID(forConversationID: conversationID),
              let entry = entriesByID[entryID] else {
            return nil
        }
        return entry.lifecycle
    }

    func activeStreamingLifecycleSnapshot() -> ChatRuntimeLifecycle {
        let streaming = entriesByID.values.filter { $0.lifecycle.generationTask != nil }
        guard streaming.count == 1, let entry = streaming.first else {
            return ChatRuntimeLifecycle()
        }
        return entry.lifecycle
    }

    func mutateLifecycle(
        for conversationID: UUID,
        mutate: @Sendable (inout ChatRuntimeLifecycle) -> Void
    ) {
        _ = mutateEntry(forConversationID: conversationID) { entry in
            mutate(&entry.lifecycle)
        }
    }

    func mutateActiveStreamingLifecycle(mutate: @Sendable (inout ChatRuntimeLifecycle) -> Void) {
        let streaming = entriesByID.values.filter { $0.lifecycle.generationTask != nil }
        guard streaming.count == 1, let entryID = streaming.first?.id,
              var entry = entriesByID[entryID] else {
            return
        }
        mutate(&entry.lifecycle)
        entriesByID[entryID] = entry
    }

    // MARK: - Per-entry token snapshot

    func tokenSnapshot(for conversationID: UUID) -> OrchestratorPoolEntryTokenSnapshot? {
        guard let entryID = entryID(forConversationID: conversationID),
              let entry = entriesByID[entryID] else {
            return nil
        }
        return entry.tokenSnapshot
    }

    func lastModelRequestAt(for conversationID: UUID) -> Date? {
        tokenSnapshot(for: conversationID)?.lastModelRequestAt
    }

    func resetTokenSnapshot(for conversationID: UUID) {
        _ = mutateEntry(forConversationID: conversationID) { entry in
            entry.tokenSnapshot = OrchestratorPoolEntryTokenSnapshot()
        }
    }

    func resetAllTokenSnapshots() {
        for entryID in entriesByID.keys {
            entriesByID[entryID]?.tokenSnapshot = OrchestratorPoolEntryTokenSnapshot()
        }
    }

    func applyLLMContextSnapshot(
        for conversationID: UUID,
        from response: LLMResponse,
        requestConfig: LLMRequestConfig
    ) {
        guard mutateEntry(forConversationID: conversationID, mutate: { entry in
            entry.tokenSnapshot.lastModelRequestAt = Date()
            if let meta = response.metadata {
                entry.tokenSnapshot.lastContextLimitTokens = meta.contextWindowTokens ?? requestConfig.maxTokens
                entry.tokenSnapshot.lastPromptTokens = meta.promptTokens
                entry.tokenSnapshot.lastRemainingContextTokens = LLMTokenMetadataBuilder.effectiveRemainingContextTokens(from: meta)
            } else {
                entry.tokenSnapshot.lastContextLimitTokens = requestConfig.maxTokens
                entry.tokenSnapshot.lastRemainingContextTokens = nil
                entry.tokenSnapshot.lastPromptTokens = nil
            }
        }) else {
            return
        }
    }

    func orchestrationEmissionConversationID(for conversationID: UUID) -> UUID? {
        guard let entryID = entryIDByConversation[conversationID],
              let entry = entriesByID[entryID] else {
            return nil
        }
        return entry.lastOrchestrationEmissionConversationID
    }

    func setOrchestrationEmissionConversationID(_ emissionID: UUID?, forEntry entryConversationID: UUID) {
        guard let entryID = entryIDByConversation[entryConversationID],
              var entry = entriesByID[entryID] else {
            return
        }
        entry.lastOrchestrationEmissionConversationID = emissionID
        entriesByID[entryID] = entry
    }

    func testing_setOrchestratorConversationID(_ conversationID: UUID?) async {
        guard let conversationID else {
            pinnedOrchestratorConversationID = nil
            await clearBinding()
            return
        }
        pinnedOrchestratorConversationID = conversationID
        if entryIDByConversation[conversationID] == nil, let firstID = entriesByID.keys.first {
            entryIDByConversation[conversationID] = firstID
        }
    }

    func testing_setLastPromptTokens(_ value: Int?, for conversationID: UUID) {
        _ = mutateEntry(forConversationID: conversationID) { entry in
            entry.tokenSnapshot.lastPromptTokens = value
        }
    }

    func testing_currentLastPromptTokens(for conversationID: UUID) -> Int? {
        guard let entryID = entryID(forConversationID: conversationID),
              let entry = entriesByID[entryID] else {
            return nil
        }
        return entry.tokenSnapshot.lastPromptTokens
    }

    func testing_setLastContextLimitTokens(_ value: Int?, for conversationID: UUID) {
        _ = mutateEntry(forConversationID: conversationID) { entry in
            entry.tokenSnapshot.lastContextLimitTokens = value
        }
    }

    func testing_currentLastContextLimitTokens(for conversationID: UUID) -> Int? {
        guard let entryID = entryID(forConversationID: conversationID),
              let entry = entriesByID[entryID] else {
            return nil
        }
        return entry.tokenSnapshot.lastContextLimitTokens
    }

    func testing_poolRefCount(for conversationID: UUID) -> Int {
        guard let entryID = entryID(forConversationID: conversationID),
              let entry = entriesByID[entryID] else {
            return 0
        }
        return entry.refCount
    }

    func testing_pendingTeardownCount() -> Int {
        pendingTeardownByKey.count
    }

    func testing_drainPendingTeardowns() async {
        let tasks = Array(pendingTeardownByKey.values)
        for task in tasks {
            await task.value
        }
    }

    // MARK: - Private

    private func entryID(forConversationID conversationID: UUID) -> UUID? {
        if let entryID = entryIDByConversation[conversationID] {
            return entryID
        }
        return entriesByID.values.first(where: { entry in
            entry.key.conversationID == conversationID
                && (entry.refCount > 0 || entry.lifecycle.generationTask != nil)
        })?.id
    }

    @discardableResult
    private func mutateEntry(
        forConversationID conversationID: UUID,
        mutate: (inout Entry) -> Void
    ) -> Bool {
        guard let entryID = entryID(forConversationID: conversationID),
              var entry = entriesByID[entryID] else {
            return false
        }
        mutate(&entry)
        entriesByID[entryID] = entry
        return true
    }

    private func unhookEntryFromLookup(_ entry: Entry) {
        entryIDByKey.removeValue(forKey: entry.key)
        for (conversationID, mappedEntryID) in entryIDByConversation where mappedEntryID == entry.id {
            entryIDByConversation.removeValue(forKey: conversationID)
        }
    }

    private func bumpAcquisition(
        key: OrchestratorKey,
        entryID: UUID,
        entry: inout Entry
    ) -> OrchestratorAcquisition {
        entry.refCount += 1
        entry.lastUsedAt = Date()
        entriesByID[entryID] = entry
        return OrchestratorAcquisition(
            handle: OrchestratorHandle(key: key, entryID: entryID),
            orchestrator: entry.orchestrator,
            queuedLLM: entry.queuedLLM
        )
    }

    private func acquisition(for entryID: UUID, key: OrchestratorKey) -> OrchestratorAcquisition? {
        guard var entry = entriesByID[entryID] else { return nil }
        return bumpAcquisition(key: key, entryID: entryID, entry: &entry)
    }

    private func reservedAcquisition(for entryID: UUID, key: OrchestratorKey) -> OrchestratorAcquisition? {
        guard let entry = entriesByID[entryID] else { return nil }
        return OrchestratorAcquisition(
            handle: OrchestratorHandle(key: key, entryID: entryID),
            orchestrator: entry.orchestrator,
            queuedLLM: entry.queuedLLM
        )
    }

    private func completeAcquireBuild(
        key: OrchestratorKey,
        conversationID: UUID,
        buildIfMissing: @escaping OrchestratorPoolBuildFactory
    ) async -> UUID? {
        if let entryID = entryIDByKey[key] {
            return entryID
        }
        if let existingConvEntryID = entryIDByConversation[conversationID],
           entriesByID[existingConvEntryID] != nil {
            await invalidate(conversationID: conversationID)
        }
        while entriesByID.count >= maxEntries {
            guard await evictOneIdleEntryIfPossible() else { break }
        }
        await pendingTeardownByKey[key]?.value
        pendingTeardownByKey.removeValue(forKey: key)
        guard let built = await buildIfMissing() else { return nil }
        let entryID = UUID()
        let entry = Entry(
            id: entryID,
            key: key,
            orchestrator: built.orchestrator,
            queuedLLM: built.queuedLLM,
            refCount: 1,
            lastUsedAt: Date(),
            lifecycle: ChatRuntimeLifecycle(),
            tokenSnapshot: OrchestratorPoolEntryTokenSnapshot(),
            lastOrchestrationEmissionConversationID: nil,
            pendingInvalidation: false
        )
        entriesByID[entryID] = entry
        entryIDByKey[key] = entryID
        entryIDByConversation[conversationID] = entryID
        return entryID
    }

    @discardableResult
    private func evictOneIdleEntryIfPossible() async -> Bool {
        guard let victim = entriesByID.values
            .filter({ $0.refCount == 0 && !$0.pendingInvalidation })
            .min(by: { $0.lastUsedAt < $1.lastUsedAt }) else {
            return false
        }
        await removeEntry(id: victim.id, force: true)
        return true
    }

    private func scheduleTeardown(for entry: Entry) {
        let key = entry.key
        let orchestrator = entry.orchestrator
        let prior = pendingTeardownByKey[key]
        let generation = (teardownGenerationByKey[key] ?? 0) + 1
        teardownGenerationByKey[key] = generation
        pendingTeardownByKey[key] = Task(priority: .userInitiated) {
            await prior?.value
            if let teardownHandler {
                await teardownHandler(orchestrator)
            }
            await self.finishPendingTeardown(key: key, generation: generation)
        }
    }

    private func finishPendingTeardown(key: OrchestratorKey, generation: UInt64) {
        guard teardownGenerationByKey[key] == generation else { return }
        pendingTeardownByKey.removeValue(forKey: key)
        teardownGenerationByKey.removeValue(forKey: key)
    }

    private func removeEntry(id: UUID, force: Bool) async {
        guard let entry = entriesByID[id] else { return }
        if !force, entry.refCount > 0 { return }
        entriesByID.removeValue(forKey: id)
        entryIDByKey.removeValue(forKey: entry.key)
        if entryIDByConversation[entry.key.conversationID] == id {
            entryIDByConversation.removeValue(forKey: entry.key.conversationID)
        }
        scheduleTeardown(for: entry)
    }
}
