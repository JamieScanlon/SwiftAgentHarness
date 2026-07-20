import Foundation
import Logging
import CryptoKit
import SwiftAgentKit

enum FileStoreMemoryManifestEntryID {
    static func entryID(filename: String) -> UUID {
        let digest = SHA256.hash(data: Data("memory-manifest:\(filename)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

struct FileStoreMemoryPromptBuilder: MemoryPromptBuilding {
    let config: MemoryConfiguration

    func buildPromptSections(
        context: MemorySessionContext,
        store: AgentMemoryStore,
        recalled: String,
        availableToolNames: [String]
    ) throws -> MemoryBackendPromptSections {
        _ = availableToolNames
        let projectIndex = try store.readIndexSnapshot()
        let userStore = AgentMemoryStore(
            memoryDirectory: context.userMemoryDirectory,
            indexCapProfile: .user
        )
        let userIndex = try userStore.readIndexSnapshot()
        let combinedIndex = MemoryIndexPromptComposer.combinedIndexText(
            userIndex: userIndex,
            projectIndex: projectIndex
        )
        let taxonomy = """
\(MemoryTypeTaxonomy.indexUsagePrompt)
\(MemoryTypeTaxonomy.whatNotToSavePrompt)
\(MemoryTypeTaxonomy.persistenceDistinctionPrompt)
\(MemoryTypeTaxonomy.declarativeVsProceduralRoutingPrompt)
\(MemoryTypeTaxonomy.userTierWriteRoutingPrompt)
"""
        var sensitive = MemoryTypeTaxonomy.sensitiveDataPrompt
        if config.teamMemoryEnabled {
            sensitive += "\n" + MemoryTypeTaxonomy.teamSensitiveDataPrompt
        }
        let pathDisclosure = """
You have a persistent, file-based memory system. Project memory: \(context.memoryDirectory.path). User memory (cross-project): \(context.userMemoryDirectory.path).
"""
        return MemoryBackendPromptSections(
            memoryIndexText: combinedIndex,
            recalledTopicBodiesText: recalled,
            taxonomyPromptText: taxonomy,
            driftGuardText: MemoryTypeTaxonomy.driftGuardPrompt,
            sensitiveDataPromptText: sensitive,
            memoryPathDisclosureText: pathDisclosure
        )
    }
}

struct FileStoreMemoryFlushPlanResolver: MemoryFlushPlanResolving {
    let config: MemoryConfiguration
    let logger: Logger?

    func resolveFlushPlan(
        manifestLines: [String],
        middleTranscript: String,
        session: MemorySessionContext,
        store: AgentMemoryStore
    ) -> MemoryFlushPlan {
        _ = session
        let customBody = PreCompactionFlushCustomPromptLoader.load(
            path: config.preCompactionFlushSystemPromptPath,
            logger: logger
        )
        let systemPrompt = MemoryPreCompactionFlushPrompts.systemPrompt(
            manifestLines: manifestLines,
            customBody: customBody,
            teamMemoryEnabled: config.teamMemoryEnabled
        )
        let userPrompt = MemoryPreCompactionFlushPrompts.userPrompt(middleTranscript: middleTranscript)
        return MemoryFlushPlan(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            writeGuardPolicy: PreCompactionFlushWriteGuard.Policy(
                manifestTopicFilenames: Set(store.listTopicFilenames())
            )
        )
    }

    func flushedMemoryEntryIDs(
        from flushPaths: Set<String>,
        session: MemorySessionContext,
        maxEntries: Int
    ) -> [UUID] {
        let curatedBasenames = PreCompactionFlushWriteGuard.curatedTopicBasenames(
            fromAbsolutePaths: flushPaths,
            memoryDirectory: session.memoryDirectory
        )
        return curatedBasenames
            .prefix(maxEntries)
            .map { FileStoreMemoryManifestEntryID.entryID(filename: $0) }
    }
}

struct FileStoreMemoryPublicArtifactsProvider: MemoryPublicArtifactsProviding {
    func publicArtifacts(context: MemorySessionContext, store: AgentMemoryStore) -> [MemoryArtifact] {
        var artifacts: [MemoryArtifact] = []
        let memoryRoot = context.memoryDirectory.path
        let indexPath = context.memoryDirectory.appendingPathComponent("MEMORY.md").path
        if FileManager.default.fileExists(atPath: indexPath) {
            artifacts.append(
                MemoryArtifact(
                    kind: "memory-index",
                    workspaceDir: memoryRoot,
                    relativePath: "MEMORY.md",
                    absolutePath: indexPath,
                    contentType: "text/markdown"
                )
            )
        }
        for filename in store.listTopicFilenames() {
            let absolute = context.memoryDirectory.appendingPathComponent(filename).path
            artifacts.append(
                MemoryArtifact(
                    kind: "memory-topic",
                    workspaceDir: memoryRoot,
                    relativePath: filename,
                    absolutePath: absolute,
                    contentType: "text/markdown"
                )
            )
        }
        if let dailyNames = try? FileManager.default.contentsOfDirectory(atPath: memoryRoot) {
            for name in dailyNames.sorted() where AgentMemoryStore.isDailyFilename(name) {
                let absolute = context.memoryDirectory.appendingPathComponent(name).path
                artifacts.append(
                    MemoryArtifact(
                        kind: "memory-daily",
                        workspaceDir: memoryRoot,
                        relativePath: name,
                        absolutePath: absolute,
                        contentType: "text/markdown"
                    )
                )
            }
        }
        return artifacts
    }
}

actor FileStoreMemoryBackend: MemoryRuntime {
    private let config: MemoryConfiguration
    private let logger: Logger?
    private let snapshotStore: MemorySessionSnapshotStore
    private let recallSelector: MemoryRecallSelector
    private let extractor: BackgroundMemoryExtractor
    private let activeMemory: ActiveMemoryPreReplyService
    private let search: HybridMemorySearch
    private let dreaming: DreamingConsolidationScheduler
    private var extractionRunner: MemoryExtractionRunning?
    private var sessionByConversation: [UUID: MemorySessionContext] = [:]
    private var storeByConversation: [UUID: AgentMemoryStore] = [:]
    private var userStoreByDirectory: [String: AgentMemoryStore] = [:]

    init(
        config: MemoryConfiguration,
        logger: Logger? = nil,
        llmRecallSelector: MemoryLLMRecallSelecting? = nil
    ) {
        self.config = config
        self.logger = logger
        self.snapshotStore = MemorySessionSnapshotStore()
        self.recallSelector = MemoryRecallSelector(
            llmSelector: llmRecallSelector,
            heuristicMinScore: config.recallSelectorHeuristicMinScore
        )
        self.extractor = BackgroundMemoryExtractor(config: config, logger: logger)
        self.activeMemory = ActiveMemoryPreReplyService(config: config, logger: logger)
        self.search = HybridMemorySearch()
        self.dreaming = DreamingConsolidationScheduler(config: config, logger: logger)
    }

    func initialize(sessionID: UUID, context: MemorySessionContext) async throws {
        _ = sessionID
        sessionByConversation[context.conversationID] = context
        let store = AgentMemoryStore(memoryDirectory: context.memoryDirectory)
        try store.ensureLayout()
        storeByConversation[context.conversationID] = store
        try ensureUserStore(for: context.userMemoryDirectory)
        Task { await self.activeMemory.warmStanding(session: context) }
    }

    private func userStoreDirectoryKey(_ directory: URL) -> String {
        directory.standardizedFileURL.path
    }

    private func userStore(for context: MemorySessionContext) -> AgentMemoryStore? {
        userStoreByDirectory[userStoreDirectoryKey(context.userMemoryDirectory)]
    }

    @discardableResult
    private func ensureUserStore(for userMemoryDirectory: URL) throws -> AgentMemoryStore {
        let key = userStoreDirectoryKey(userMemoryDirectory)
        if let existing = userStoreByDirectory[key] {
            return existing
        }
        let store = AgentMemoryStore(
            memoryDirectory: userMemoryDirectory,
            indexCapProfile: .user
        )
        try store.ensureLayout()
        userStoreByDirectory[key] = store
        return store
    }

    func endSession(conversationID: UUID) async {
        sessionByConversation.removeValue(forKey: conversationID)
        storeByConversation.removeValue(forKey: conversationID)
        await snapshotStore.endSession(conversationID: conversationID)
        await activeMemory.endSession(conversationID: conversationID)
        await extractor.discardStashedWork(for: conversationID)
    }

    func shutdown() async {}

    func recallForTurn(request: MemoryRecallRequest) async throws -> MemoryRecallResult {
        let selected = await recallSelector.selectRelevantFiles(request: request)
        return try await recallHits(selectionKeys: selected, session: request.session)
    }

    func recallHits(selectionKeys: [String], session: MemorySessionContext) async throws -> MemoryRecallResult {
        guard let projectStore = storeByConversation[session.conversationID] else {
            return MemoryRecallResult(selectedFilenames: selectionKeys, hits: [])
        }
        var hits: [MemoryRecallHit] = []
        for selectionKey in selectionKeys {
            guard let resolved = MemoryRecallSelectionResolver.resolve(
                selectionKey: selectionKey,
                projectStore: projectStore,
                userStore: userStore(for: session)
            ),
                  let body = try resolved.store.readTopicBody(filename: resolved.filename) else {
                continue
            }
            let formatted = MemoryRecallBodyFormatter.format(
                scope: resolved.tierScope,
                filename: resolved.filename,
                body: body
            )
            hits.append(MemoryRecallHit(selectionKey: selectionKey, formattedBody: formatted))
        }
        return MemoryRecallResult(selectedFilenames: selectionKeys, hits: hits)
    }

    func onTurnEnded(request: MemoryTurnEndedRequest) async {
        await extractor.scheduleIfNeeded(request: request) { req in
            await self.runScheduledExtraction(request: req)
        }
    }

    func onPreCompress(messages: [String]) async -> String {
        _ = messages
        return ""
    }

    func refreshSnapshotAfterFlush(conversationID: UUID) async throws {
        _ = conversationID
    }

    func systemPromptBlocks(conversationID: UUID) async -> MemorySystemPromptBlocks? {
        await snapshotStore.snapshot(for: conversationID)?.blocks
    }

    func currentSnapshotGeneration(conversationID: UUID) async -> Int {
        await snapshotStore.generation(for: conversationID)
    }

    func invalidateSnapshot(conversationID: UUID) async {
        await snapshotStore.invalidate(conversationID: conversationID)
    }

    func manifestEntries(conversationID: UUID) async -> [MemoryManifestEntry] {
        let sessionUserStore: AgentMemoryStore?
        if let session = sessionByConversation[conversationID] {
            sessionUserStore = userStore(for: session)
        } else {
            sessionUserStore = nil
        }
        return MemoryManifestAggregator.combinedEntries(
            userStore: sessionUserStore,
            projectStore: storeByConversation[conversationID]
        )
    }

    func hybridSearch() async -> HybridMemorySearch { search }

    func updateSnapshot(
        conversationID: UUID,
        blocks: MemorySystemPromptBlocks,
        manifest: [MemoryManifestEntry]
    ) async {
        await snapshotStore.capture(conversationID: conversationID, blocks: blocks, manifest: manifest)
    }

    func runDreamingSweep(memoryDirectory: URL, rollback: Bool) async throws {
        try await dreaming.runSweep(memoryDirectory: memoryDirectory, rollback: rollback)
    }

    func bindSpawnPort(_ port: MemorySubAgentSpawnPort) async {
        let activeRunner = SubAgentPoolActiveMemoryRunner(
            spawnPort: port,
            config: config,
            logger: logger
        )
        await activeMemory.setRunner(activeRunner)
        extractionRunner = SubAgentPoolMemoryExtractionRunner(
            spawnPort: port,
            config: config,
            logger: logger
        )
    }

    func drainPendingWork(timeoutMs: Int) async {
        await extractor.drain(timeoutMs: timeoutMs)
    }

    func store(for conversationID: UUID) async -> AgentMemoryStore? {
        storeByConversation[conversationID]
    }

    func userTierStore() async -> AgentMemoryStore? {
        nil
    }

    func sessionContext(for conversationID: UUID) async -> MemorySessionContext? {
        sessionByConversation[conversationID]
    }

    func activeRecallSummary(
        session: MemorySessionContext,
        messages: [Message],
        anchorUserMessageID: UUID?,
        sessionEnabled: Bool,
        excludedSelectionKeys: Set<String> = []
    ) async -> ActiveMemoryRecallOutcome {
        guard let query = ActiveMemorySituationalQueryBuilder.build(
            messages: messages,
            anchorUserMessageID: anchorUserMessageID,
            config: config
        ) else {
            return .skipped(reason: "no_query", queryMode: config.activeMemoryQueryMode)
        }
        return await activeMemory.recallOutcomeIfEnabled(
            session: session,
            userQuery: query,
            sessionEnabled: sessionEnabled,
            excludedSelectionKeys: excludedSelectionKeys
        )
    }

    func warmStandingRecall(session: MemorySessionContext, sessionEnabled: Bool) async {
        await activeMemory.warmStanding(session: session, sessionEnabled: sessionEnabled)
    }

    func prefetchSituationalRecall(
        session: MemorySessionContext,
        messages: [Message],
        anchorUserMessageID: UUID?,
        sessionEnabled: Bool
    ) async {
        guard let query = ActiveMemorySituationalQueryBuilder.build(
            messages: messages,
            anchorUserMessageID: anchorUserMessageID,
            config: config
        ) else { return }
        await activeMemory.prefetchSituational(
            session: session,
            userQuery: query,
            sessionEnabled: sessionEnabled
        )
    }

    func invalidateStandingRecall(conversationID: UUID) async {
        await activeMemory.invalidateStanding(conversationID: conversationID)
    }

    private func runScheduledExtraction(request: MemoryTurnEndedRequest) async {
        if let extractionRunner {
            await extractionRunner.startBackgroundExtraction(request: request)
        } else {
            await runExtractionPlaceholder(request: request)
        }
    }

    private func runExtractionPlaceholder(request: MemoryTurnEndedRequest) async {
        guard let store = storeByConversation[request.session.conversationID] else { return }
        let manifest = store.manifest().map(MemoryManifestScanner.formatManifestLine)
        logger?.debug("[MemoryExtractor] would extract with manifest lines=\(manifest.count)")
        _ = MemoryExtractionPrompts.systemPrompt(manifestLines: manifest, teamMemoryEnabled: config.teamMemoryEnabled)
    }
}

enum FileStoreMemoryCapabilityFactory {
    static func makeDefault(
        config: MemoryConfiguration,
        logger: Logger? = nil,
        llmRecallSelector: MemoryLLMRecallSelecting? = nil
    ) -> (backend: FileStoreMemoryBackend, capability: MemoryCapability) {
        let backend = FileStoreMemoryBackend(
            config: config,
            logger: logger,
            llmRecallSelector: llmRecallSelector
        )
        let capability = MemoryCapability(
            pluginID: "builtin-file",
            runtime: backend,
            promptBuilder: FileStoreMemoryPromptBuilder(config: config),
            flushPlanResolver: FileStoreMemoryFlushPlanResolver(config: config, logger: logger),
            publicArtifacts: FileStoreMemoryPublicArtifactsProvider()
        )
        return (backend, capability)
    }
}
