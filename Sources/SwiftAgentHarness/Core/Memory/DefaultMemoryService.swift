import Foundation
import Logging
import SwiftAgentKit

public actor DefaultMemoryService: MemoryServicing {
    private let config: MemoryConfiguration
    private let logger: Logger?
    private let writeTracker: MemoryWriteTracker
    private let capabilityRegistry: MemoryCapabilityRegistry
    private let corpusSupplementRegistry = MemoryCorpusSupplementRegistry()
    private let spawnPortBox = MemorySubAgentSpawnPortBox()
    private var hintTrackerByConversation: [UUID: SubdirectoryHintTracker] = [:]
    private var softPreCompactionFlushCompleted: Set<UUID> = []
    private var preCompactionFlushDedupeByConversation: [UUID: PreCompactionFlushDedupeState] = [:]
    private var preCompactionFlushWriteGuardByConversation: [UUID: PreCompactionFlushWriteGuard.Policy] = [:]
    private let userConfigDir: URL

    public init(
        config: MemoryConfiguration,
        logger: Logger? = nil,
        userConfigDir: URL? = nil
    ) {
        self.init(config: config, logger: logger, userConfigDir: userConfigDir, llmRecallSelector: nil)
    }

    init(
        config: MemoryConfiguration = MemoryConfigurationLoader.loadFromPromptConfigBundle(),
        logger: Logger? = nil,
        userConfigDir: URL? = nil,
        llmRecallSelector: MemoryLLMRecallSelecting? = nil
    ) {
        self.config = config
        self.logger = logger
        self.writeTracker = MemoryWriteTracker()
        self.userConfigDir = userConfigDir ?? MemoryConfigHome.resolve().appendingPathComponent("user", isDirectory: true)
        let factory = FileStoreMemoryCapabilityFactory.makeDefault(
            config: config,
            logger: logger,
            llmRecallSelector: llmRecallSelector
        )
        self.capabilityRegistry = MemoryCapabilityRegistry(defaultCapability: factory.capability)
    }

    func writeObserver() -> MemoryWriteTracker { writeTracker }

    func bootstrapSession(context: MemorySessionContext) async throws -> MemorySystemPromptBlocks {
        hintTrackerByConversation[context.conversationID] = SubdirectoryHintTracker()
        let capability = await capabilityRegistry.activeCapability()
        try await capability.runtime.initialize(sessionID: context.conversationID, context: context)
        let blocks = try await buildBlocks(context: context, capability: capability, recalled: "")
        let manifest = await capability.runtime.manifestEntries(conversationID: context.conversationID)
        await capability.runtime.updateSnapshot(conversationID: context.conversationID, blocks: blocks, manifest: manifest)
        return blocks
    }

    func systemPromptBlocks(conversationID: UUID) async -> MemorySystemPromptBlocks? {
        await capabilityRegistry.activeCapability().runtime.systemPromptBlocks(conversationID: conversationID)
    }

    func recallForTurn(request: MemoryRecallRequest) async throws -> MemoryRecallResult {
        let capability = await capabilityRegistry.activeCapability()
        return try await capability.runtime.recallForTurn(request: request)
    }

    func bindSpawnPort(_ port: MemorySubAgentSpawnPort) async {
        spawnPortBox.set(port)
        let capability = await capabilityRegistry.activeCapability()
        await capability.runtime.bindSpawnPort(port)
    }

    func spawnPort() -> MemorySubAgentSpawnPort? {
        spawnPortBox.get()
    }

    func resolveFlushPlan(
        conversationID: UUID,
        manifestLines: [String],
        middleTranscript: String
    ) async -> MemoryFlushPlan? {
        let capability = await capabilityRegistry.activeCapability()
        guard let resolver = capability.flushPlanResolver,
              let session = await capability.runtime.sessionContext(for: conversationID),
              let store = await capability.runtime.store(for: conversationID) else { return nil }
        return resolver.resolveFlushPlan(
            manifestLines: manifestLines,
            middleTranscript: middleTranscript,
            session: session,
            store: store
        )
    }

    func flushedMemoryEntryIDs(
        conversationID: UUID,
        flushPaths: Set<String>,
        maxEntries: Int
    ) async -> [UUID] {
        let capability = await capabilityRegistry.activeCapability()
        guard let resolver = capability.flushPlanResolver,
              let session = await capability.runtime.sessionContext(for: conversationID) else { return [] }
        return resolver.flushedMemoryEntryIDs(
            from: flushPaths,
            session: session,
            maxEntries: maxEntries
        )
    }

    func runPreCompactionFlush(
        context: PreCompactionMemoryFlushContext,
        spawnPort: MemorySubAgentSpawnPort,
        logger: Logger?
    ) async -> PreCompactionMemoryFlushResult {
        guard config.preCompactionFlushEnabled else { return .skipped }
        guard !context.middleMessages.isEmpty else { return .skipped }
        let capability = await capabilityRegistry.activeCapability()
        guard let session = await capability.runtime.sessionContext(for: context.conversationID),
              let store = await capability.runtime.store(for: context.conversationID) else { return .skipped }

        let manifestLines = await extractionManifestLines(conversationID: context.conversationID)
        let middleTranscript = MemoryExtractionPrompts.recentTranscriptSlice(
            messages: context.middleMessages,
            limit: context.middleMessages.count
        )
        guard !middleTranscript.isEmpty,
              let plan = capability.flushPlanResolver?.resolveFlushPlan(
                manifestLines: manifestLines,
                middleTranscript: middleTranscript,
                session: session,
                store: store
              ) else { return .skipped }

        registerPreCompactionFlushWriteGuard(
            conversationID: context.conversationID,
            policy: plan.writeGuardPolicy
        )
        defer {
            clearPreCompactionFlushWriteGuard(conversationID: context.conversationID)
        }

        let pathsBefore = Set(await writeTracker.auxiliaryWrittenPaths(conversationID: context.conversationID))

        let completed = await spawnPort.spawnBlockingPreCompactionFlush(
            context.conversationID,
            context.middleMessages,
            context.timeoutMs
        )
        guard completed else {
            logger?.warning("[PreCompactionMemoryFlush] timed out or failed conversation=\(context.conversationID)")
            return .skipped
        }

        let pathsAfter = Set(await writeTracker.auxiliaryWrittenPaths(conversationID: context.conversationID))
        let flushPaths = pathsAfter.subtracting(pathsBefore)
        guard !flushPaths.isEmpty else {
            logger?.debug("[PreCompactionMemoryFlush] sub-agent completed without memory writes conversation=\(context.conversationID)")
            return .skipped
        }

        do {
            try await capability.runtime.refreshSnapshotAfterFlush(conversationID: context.conversationID)
            let blocks = try await buildBlocks(context: session, capability: capability, recalled: "")
            let manifest = store.manifest()
            await capability.runtime.updateSnapshot(conversationID: context.conversationID, blocks: blocks, manifest: manifest)
        } catch {
            logger?.error("[PreCompactionMemoryFlush] snapshot refresh failed: \(error)")
            return .skipped
        }

        let version = await capability.runtime.currentSnapshotGeneration(conversationID: context.conversationID)
        let entryIDs = await flushedMemoryEntryIDs(
            conversationID: context.conversationID,
            flushPaths: flushPaths,
            maxEntries: context.maxFlushedMemoryEntries
        )

        guard !entryIDs.isEmpty else { return .skipped }
        logger?.info("[PreCompactionMemoryFlush] flushed \(entryIDs.count) entries conversation=\(context.conversationID)")
        return PreCompactionMemoryFlushResult(
            succeeded: true,
            memoryStoreVersion: version,
            flushedMemoryEntryIDs: Array(entryIDs)
        )
    }

    func activeRecallSummary(
        session: MemorySessionContext,
        messages: [Message],
        anchorUserMessageID: UUID?,
        sessionEnabled: Bool = true,
        excludedSelectionKeys: Set<String> = []
    ) async -> ActiveMemoryRecallOutcome {
        let capability = await capabilityRegistry.activeCapability()
        return await capability.runtime.activeRecallSummary(
            session: session,
            messages: messages,
            anchorUserMessageID: anchorUserMessageID,
            sessionEnabled: sessionEnabled,
            excludedSelectionKeys: excludedSelectionKeys
        )
    }

    func warmStandingRecall(session: MemorySessionContext, sessionEnabled: Bool = true) async {
        let capability = await capabilityRegistry.activeCapability()
        await capability.runtime.warmStandingRecall(session: session, sessionEnabled: sessionEnabled)
    }

    func prefetchSituationalRecall(
        session: MemorySessionContext,
        messages: [Message],
        anchorUserMessageID: UUID?,
        sessionEnabled: Bool = true
    ) async {
        let capability = await capabilityRegistry.activeCapability()
        await capability.runtime.prefetchSituationalRecall(
            session: session,
            messages: messages,
            anchorUserMessageID: anchorUserMessageID,
            sessionEnabled: sessionEnabled
        )
    }

    func appendSubdirectoryHintsIfNeeded(
        conversationID: UUID,
        toolName: String,
        toolArgumentsJSON: String?,
        toolResultContent: String
    ) async -> String {
        let tracker = hintTracker(for: conversationID)
        return await tracker.appendHintsIfNeeded(
            toolName: toolName,
            toolArgumentsJSON: toolArgumentsJSON,
            toolResultContent: toolResultContent
        )
    }

    func onTurnEnded(request: MemoryTurnEndedRequest) async {
        await writeTracker.resetTurn(conversationID: request.session.conversationID)
        let capability = await capabilityRegistry.activeCapability()
        await capability.runtime.onTurnEnded(request: request)
    }

    func onPreCompress(conversationID: UUID, messages: [String]) async throws {
        _ = conversationID
        _ = await collectProviderPreCompressNotes(messages: messages)
    }

    public func drainPendingWork(timeoutMs: Int) async {
        let capability = await capabilityRegistry.activeCapability()
        await capability.runtime.drainPendingWork(timeoutMs: timeoutMs)
    }

    public func shutdown() async {
        await capabilityRegistry.shutdownActive()
    }

    func invalidateSnapshot(conversationID: UUID) async {
        let capability = await capabilityRegistry.activeCapability()
        await capability.runtime.invalidateSnapshot(conversationID: conversationID)
    }

    func endSession(conversationID: UUID) async {
        hintTrackerByConversation.removeValue(forKey: conversationID)
        softPreCompactionFlushCompleted.remove(conversationID)
        preCompactionFlushDedupeByConversation.removeValue(forKey: conversationID)
        preCompactionFlushWriteGuardByConversation.removeValue(forKey: conversationID)
        await writeTracker.removeConversation(conversationID: conversationID)
        await capabilityRegistry.endSessionActive(conversationID: conversationID)
    }

    func hasCompletedSoftPreCompactionFlush(conversationID: UUID) -> Bool {
        softPreCompactionFlushCompleted.contains(conversationID)
    }

    func markSoftPreCompactionFlushCompleted(conversationID: UUID) {
        softPreCompactionFlushCompleted.insert(conversationID)
    }

    func filterPreCompactionFlushMiddle(conversationID: UUID, middle: [Message]) -> [Message] {
        var state = preCompactionFlushDedupeByConversation[conversationID] ?? PreCompactionFlushDedupeState()
        let novel = state.filterNovelMiddle(middle)
        preCompactionFlushDedupeByConversation[conversationID] = state
        return novel
    }

    func shouldSkipPreCompactionFlushFingerprint(conversationID: UUID, fingerprint: String) -> Bool {
        var state = preCompactionFlushDedupeByConversation[conversationID] ?? PreCompactionFlushDedupeState()
        let skip = state.shouldSkipFingerprint(fingerprint)
        preCompactionFlushDedupeByConversation[conversationID] = state
        return skip
    }

    func recordPreCompactionFlushMiddle(conversationID: UUID, middle: [Message]) {
        guard !middle.isEmpty else { return }
        var state = preCompactionFlushDedupeByConversation[conversationID] ?? PreCompactionFlushDedupeState()
        state.recordSuccessfulFlush(middle: middle)
        preCompactionFlushDedupeByConversation[conversationID] = state
    }

    func clearPreCompactionFlushCycle(conversationID: UUID) {
        softPreCompactionFlushCompleted.remove(conversationID)
        preCompactionFlushDedupeByConversation[conversationID]?.beginNewCycle()
        preCompactionFlushDedupeByConversation.removeValue(forKey: conversationID)
    }

    func clearSoftPreCompactionFlush(conversationID: UUID) {
        clearPreCompactionFlushCycle(conversationID: conversationID)
    }

    func activePublicArtifacts(conversationID: UUID) async -> [MemoryArtifact] {
        let capability = await capabilityRegistry.activeCapability()
        guard let provider = capability.publicArtifacts,
              let session = await capability.runtime.sessionContext(for: conversationID),
              let store = await capability.runtime.store(for: conversationID) else { return [] }
        return provider.publicArtifacts(context: session, store: store)
    }

    func registerPreCompactionFlushWriteGuard(
        conversationID: UUID,
        policy: PreCompactionFlushWriteGuard.Policy
    ) {
        preCompactionFlushWriteGuardByConversation[conversationID] = policy
    }

    func clearPreCompactionFlushWriteGuard(conversationID: UUID) {
        preCompactionFlushWriteGuardByConversation.removeValue(forKey: conversationID)
    }

    func validatePreCompactionFlushWrite(
        conversationID: UUID,
        absolutePath: String,
        priorContent: String?,
        newContent: String
    ) -> String? {
        guard let policy = preCompactionFlushWriteGuardByConversation[conversationID] else { return nil }
        let basename = URL(fileURLWithPath: absolutePath).lastPathComponent
        let result: Result<Void, PreCompactionFlushWriteGuard.Violation>
        if let priorContent {
            result = PreCompactionFlushWriteGuard.validateEditFile(
                basename: basename,
                priorContent: priorContent,
                newContent: newContent,
                policy: policy
            )
        } else {
            result = PreCompactionFlushWriteGuard.validateWriteFile(
                basename: basename,
                content: newContent,
                policy: policy
            )
        }
        switch result {
        case .success:
            return nil
        case .failure(let violation):
            return violation.userMessage
        }
    }

    func currentSnapshotGeneration(conversationID: UUID) async -> Int {
        let capability = await capabilityRegistry.activeCapability()
        return await capability.runtime.currentSnapshotGeneration(conversationID: conversationID)
    }

    func collectProviderPreCompressNotes(messages: [String]) async -> String {
        let capability = await capabilityRegistry.activeCapability()
        let note = await capability.runtime.onPreCompress(messages: messages)
        return note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func registerActiveMemoryCapability(_ capability: MemoryCapability) async {
        await capabilityRegistry.replaceActive(capability)
    }

    func registerExternalMemoryProvider(id: String, provider: any MemoryProviding) async throws {
        await capabilityRegistry.replaceActive(.fromLegacyLifecycleProvider(id: id, provider: provider))
    }

    func activeMemoryPluginID() async -> String {
        await capabilityRegistry.activePluginID()
    }

    func registerCorpusSupplement(_ supplement: any MemoryCorpusSupplementSearching) async {
        await corpusSupplementRegistry.register(supplement)
    }

    func corpusSupplementNames() async -> [String] {
        await corpusSupplementRegistry.corpusNames()
    }

    func searchMemory(conversationID: UUID, query: String, corpus: String?, limit: Int = 10) async -> [MemorySearchHit] {
        guard let coordinator = await makeSearchCoordinator(conversationID: conversationID) else { return [] }
        return await coordinator.search(query: query, corpus: corpus, limit: limit)
    }

    func getMemory(conversationID: UUID, lookupID: String, corpus: String?) async -> String? {
        guard let coordinator = await makeSearchCoordinator(conversationID: conversationID) else { return nil }
        return await coordinator.get(lookupID: lookupID, corpus: corpus)
    }

    func memorySearchToolDependencies(conversationID: UUID) async -> MemorySearchToolDependencies? {
        guard let coordinator = await makeSearchCoordinator(conversationID: conversationID) else { return nil }
        let activeCorpus = await activeMemoryPluginID()
        return MemorySearchToolDependencies(
            search: { query, corpus, limit in
                await coordinator.search(query: query, corpus: corpus, limit: limit)
            },
            get: { lookupID, corpus in
                await coordinator.get(lookupID: lookupID, corpus: corpus)
            },
            activeCorpusName: { activeCorpus },
            availableCorpora: { await coordinator.availableCorpora() }
        )
    }

    func preCompactionFlushTimeoutMs() -> Int {
        config.preCompactionFlushTimeoutMs
    }

    func recordMemoryWrite(path: String, conversationID: UUID) async {
        await writeTracker.recordMainAgentWrite(path: path, conversationID: conversationID)
        let capability = await capabilityRegistry.activeCapability()
        await capability.runtime.invalidateStandingRecall(conversationID: conversationID)
    }

    func recordAuxiliaryMemoryWrite(path: String, conversationID: UUID) async {
        await writeTracker.recordAuxiliaryWrite(path: path, conversationID: conversationID)
    }

    func sessionContext(for conversationID: UUID) async -> MemorySessionContext? {
        let capability = await capabilityRegistry.activeCapability()
        return await capability.runtime.sessionContext(for: conversationID)
    }

    func manifestEntries(conversationID: UUID) async -> [MemoryManifestEntry] {
        let capability = await capabilityRegistry.activeCapability()
        return await capability.runtime.manifestEntries(conversationID: conversationID)
    }

    func extractionManifestLines(conversationID: UUID) async -> [String] {
        let entries = await manifestEntries(conversationID: conversationID)
        return entries.map(MemoryManifestScanner.formatManifestLine)
    }

    func hybridSearch() async -> HybridMemorySearch {
        let capability = await capabilityRegistry.activeCapability()
        return await capability.runtime.hybridSearch()
    }

    func runDreamingSweep(memoryDirectory: URL, rollback: Bool = false) async throws {
        let capability = await capabilityRegistry.activeCapability()
        try await capability.runtime.runDreamingSweep(memoryDirectory: memoryDirectory, rollback: rollback)
    }

    func runDreamingSweep(conversationID: UUID, rollback: Bool = false) async throws {
        let capability = await capabilityRegistry.activeCapability()
        guard let context = await capability.runtime.sessionContext(for: conversationID) else { return }
        try await capability.runtime.runDreamingSweep(memoryDirectory: context.memoryDirectory, rollback: rollback)
    }

    nonisolated func makeSessionContext(conversationID: UUID, cwd: String, chatType: MemoryChatType = .direct) throws -> MemorySessionContext {
        let gitRoot = GitRootResolver.canonicalGitRoot(for: cwd)
        let memoryDir = try AgentMemoryPathResolver.resolveMemoryDirectory(canonicalGitRoot: gitRoot, cwd: cwd)
        let userMemoryDir = try AgentMemoryPathResolver.resolveUserMemoryDirectory()
        return MemorySessionContext(
            conversationID: conversationID,
            cwd: cwd,
            canonicalGitRoot: gitRoot,
            memoryDirectory: memoryDir,
            userMemoryDirectory: userMemoryDir,
            chatType: chatType
        )
    }

    private func buildBlocks(
        context: MemorySessionContext,
        capability: MemoryCapability,
        recalled: String
    ) async throws -> MemorySystemPromptBlocks {
        let project = ProjectInstructionLoader.load(
            cwd: context.cwd,
            canonicalGitRoot: context.canonicalGitRoot,
            managedPath: config.managedInstructionsPath,
            userConfigDir: userConfigDir
        )
        guard let store = await capability.runtime.store(for: context.conversationID) else {
            return MemorySystemPromptBlocks(
                projectInstructionsText: project.text,
                memoryIndexText: "",
                recalledTopicBodiesText: recalled,
                taxonomyPromptText: "",
                driftGuardText: "",
                sensitiveDataPromptText: "",
                memoryPathDisclosureText: "",
                snapshotGeneration: 0
            )
        }
        let promptBuilder = capability.promptBuilder ?? EmptyMemoryPromptBuilder()
        let sections = try promptBuilder.buildPromptSections(
            context: context,
            store: store,
            recalled: recalled,
            availableToolNames: []
        )
        return MemorySystemPromptBlocks(
            projectInstructionsText: project.text,
            memoryIndexText: sections.memoryIndexText,
            recalledTopicBodiesText: sections.recalledTopicBodiesText,
            taxonomyPromptText: sections.taxonomyPromptText,
            driftGuardText: sections.driftGuardText,
            sensitiveDataPromptText: sections.sensitiveDataPromptText,
            memoryPathDisclosureText: sections.memoryPathDisclosureText,
            snapshotGeneration: 0
        )
    }

    private func hintTracker(for conversationID: UUID) -> SubdirectoryHintTracker {
        if let existing = hintTrackerByConversation[conversationID] {
            return existing
        }
        let created = SubdirectoryHintTracker()
        hintTrackerByConversation[conversationID] = created
        return created
    }

    private func makeSearchCoordinator(conversationID: UUID) async -> MemorySearchCoordinator? {
        let capability = await capabilityRegistry.activeCapability()
        guard let session = await capability.runtime.sessionContext(for: conversationID) else { return nil }
        let searchEngine = await capability.runtime.hybridSearch()
        let activeCorpus = await activeMemoryPluginID()
        let memoryDirectory = session.memoryDirectory
        return MemorySearchCoordinator(
            activeCorpusName: activeCorpus,
            backendSearch: { query, limit in
                await searchEngine.search(query: query, memoryDirectory: memoryDirectory, limit: limit)
            },
            backendGet: { lookupID in
                guard let store = await capability.runtime.store(for: conversationID) else { return nil }
                if let topic = try? store.readTopicBody(filename: lookupID) {
                    return topic
                }
                return try? store.readDailyBody(filename: lookupID)
            },
            supplementRegistry: corpusSupplementRegistry
        )
    }
}
