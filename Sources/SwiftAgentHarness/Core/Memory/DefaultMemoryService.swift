import Foundation
import Logging
import CryptoKit
import SwiftAgentKit

public actor DefaultMemoryService: MemoryServicing {
    private let config: MemoryConfiguration
    private let logger: Logger?
    private let snapshotStore: MemorySessionSnapshotStore
    private let writeTracker: MemoryWriteTracker
    private let recallSelector: MemoryRecallSelector
    private let extractor: BackgroundMemoryExtractor
    private let activeMemory: ActiveMemoryPreReplyService
    private let search: HybridMemorySearch
    private let dreaming: DreamingConsolidationScheduler
    private let providerRegistry: MemoryProviderRegistry
    private let spawnPortBox = MemorySubAgentSpawnPortBox()
    private var extractionRunner: MemoryExtractionRunning?
    private var sessionByConversation: [UUID: MemorySessionContext] = [:]
    private var storeByConversation: [UUID: AgentMemoryStore] = [:]
    private var hintTrackerByConversation: [UUID: SubdirectoryHintTracker] = [:]
    private let userConfigDir: URL

    /// Silenia / composition-root entry: caller supplies resolved memory configuration explicitly.
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
        self.snapshotStore = MemorySessionSnapshotStore()
        self.writeTracker = MemoryWriteTracker()
        self.recallSelector = MemoryRecallSelector(llmSelector: llmRecallSelector)
        self.extractor = BackgroundMemoryExtractor(config: config, logger: logger)
        self.search = HybridMemorySearch()
        self.activeMemory = ActiveMemoryPreReplyService(config: config)
        self.dreaming = DreamingConsolidationScheduler(config: config, logger: logger)
        self.userConfigDir = userConfigDir ?? MemoryConfigHome.resolve().appendingPathComponent("user", isDirectory: true)
        self.providerRegistry = MemoryProviderRegistry(builtin: BuiltinFileMemoryProvider())
    }

    func writeObserver() -> MemoryWriteTracker { writeTracker }

    func bootstrapSession(context: MemorySessionContext) async throws -> MemorySystemPromptBlocks {
        sessionByConversation[context.conversationID] = context
        hintTrackerByConversation[context.conversationID] = SubdirectoryHintTracker()
        let store = AgentMemoryStore(memoryDirectory: context.memoryDirectory)
        try store.ensureLayout()
        storeByConversation[context.conversationID] = store
        let providers = await providerRegistry.activeProviders()
        for provider in providers {
            try await provider.initialize(sessionID: context.conversationID, context: context)
        }
        let blocks = try buildBlocks(context: context, store: store, recalled: "")
        let manifest = store.manifest()
        await snapshotStore.capture(conversationID: context.conversationID, blocks: blocks, manifest: manifest)
        Task { await self.activeMemory.warmStanding(session: context) }
        return blocks
    }

    func systemPromptBlocks(conversationID: UUID) async -> MemorySystemPromptBlocks? {
        await snapshotStore.snapshot(for: conversationID)?.blocks
    }

    func recallForTurn(request: MemoryRecallRequest) async throws -> MemoryRecallResult {
        let selected = await recallSelector.selectRelevantFiles(request: request)
        guard let store = storeByConversation[request.session.conversationID] else {
            return MemoryRecallResult(selectedFilenames: selected, recalledBodiesText: "")
        }
        var bodies: [String] = []
        for filename in selected {
            if let body = try store.readTopicBody(filename: filename) {
                bodies.append("<!-- \(filename) -->\n\(body)")
            }
        }
        let recalled = MemoryContextFencer.fence(bodies.joined(separator: "\n\n"))
        return MemoryRecallResult(selectedFilenames: selected, recalledBodiesText: recalled)
    }

    func bindSpawnPort(_ port: MemorySubAgentSpawnPort) async {
        spawnPortBox.set(port)
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

    func spawnPort() -> MemorySubAgentSpawnPort? {
        spawnPortBox.get()
    }

    func runPreCompactionFlush(
        context: PreCompactionMemoryFlushContext,
        spawnPort: MemorySubAgentSpawnPort,
        logger: Logger?
    ) async -> PreCompactionMemoryFlushResult {
        guard config.preCompactionFlushEnabled else { return .skipped }
        guard !context.middleMessages.isEmpty else { return .skipped }
        guard let session = sessionByConversation[context.conversationID],
              let store = storeByConversation[context.conversationID] else { return .skipped }

        let pathsBefore = Set(await writeTracker.auxiliaryWrittenPaths(conversationID: context.conversationID))
        let messageStrings = context.middleMessages.map(\.content)
        let providers = await providerRegistry.activeProviders()
        for provider in providers {
            let note = await provider.onPreCompress(messages: messageStrings)
            if !note.isEmpty {
                logger?.info("[MemoryFlush] pre-compaction note: \(note.prefix(120))")
            }
        }

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
            let blocks = try buildBlocks(context: session, store: store, recalled: "")
            let manifest = store.manifest()
            await snapshotStore.capture(conversationID: context.conversationID, blocks: blocks, manifest: manifest)
        } catch {
            logger?.error("[PreCompactionMemoryFlush] snapshot refresh failed: \(error)")
            return .skipped
        }

        let version = await snapshotStore.generation(for: context.conversationID)
        let entryIDs = flushPaths.sorted()
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .filter { !$0.isEmpty && $0 != "MEMORY.md" }
            .prefix(context.maxFlushedMemoryEntries)
            .map { Self.manifestEntryID(filename: $0) }

        guard !entryIDs.isEmpty else { return .skipped }
        logger?.info("[PreCompactionMemoryFlush] flushed \(entryIDs.count) entries conversation=\(context.conversationID)")
        return PreCompactionMemoryFlushResult(
            succeeded: true,
            memoryStoreVersion: version,
            flushedMemoryEntryIDs: Array(entryIDs)
        )
    }

    nonisolated static func manifestEntryID(filename: String) -> UUID {
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

    func activeRecallSummary(
        session: MemorySessionContext,
        messages: [Message],
        anchorUserMessageID: UUID?
    ) async -> String? {
        guard let query = ActiveMemorySituationalQueryBuilder.build(
            messages: messages,
            anchorUserMessageID: anchorUserMessageID,
            config: config
        ) else {
            return nil
        }
        return await activeMemory.recallSummaryIfEnabled(session: session, userQuery: query)
    }

    func warmStandingRecall(session: MemorySessionContext) async {
        await activeMemory.warmStanding(session: session)
    }

    func prefetchSituationalRecall(
        session: MemorySessionContext,
        messages: [Message],
        anchorUserMessageID: UUID?
    ) async {
        guard let query = ActiveMemorySituationalQueryBuilder.build(
            messages: messages,
            anchorUserMessageID: anchorUserMessageID,
            config: config
        ) else { return }
        await activeMemory.prefetchSituational(session: session, userQuery: query)
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
        await extractor.scheduleIfNeeded(request: request) { req in
            await self.runScheduledExtraction(request: req)
        }
    }

    private func runScheduledExtraction(request: MemoryTurnEndedRequest) async {
        if let extractionRunner {
            await extractionRunner.startBackgroundExtraction(request: request)
        } else {
            await runExtractionPlaceholder(request: request)
        }
    }

    private func hintTracker(for conversationID: UUID) -> SubdirectoryHintTracker {
        if let existing = hintTrackerByConversation[conversationID] {
            return existing
        }
        let created = SubdirectoryHintTracker()
        hintTrackerByConversation[conversationID] = created
        return created
    }

    func onPreCompress(conversationID: UUID, messages: [String]) async throws {
        _ = conversationID
        _ = messages
    }

    public func drainPendingWork(timeoutMs: Int) async {
        await extractor.drain(timeoutMs: timeoutMs)
    }

    public func shutdown() async {
        await providerRegistry.shutdownAll()
    }

    func invalidateSnapshot(conversationID: UUID) async {
        await snapshotStore.invalidate(conversationID: conversationID)
    }

    func endSession(conversationID: UUID) async {
        sessionByConversation.removeValue(forKey: conversationID)
        storeByConversation.removeValue(forKey: conversationID)
        hintTrackerByConversation.removeValue(forKey: conversationID)
        await snapshotStore.endSession(conversationID: conversationID)
        await writeTracker.removeConversation(conversationID: conversationID)
        await activeMemory.endSession(conversationID: conversationID)
        await extractor.discardStashedWork(for: conversationID)
        await providerRegistry.endSessionAll(messages: [])
    }

    func currentSnapshotGeneration(conversationID: UUID) async -> Int {
        await snapshotStore.generation(for: conversationID)
    }

    func preCompactionFlushTimeoutMs() -> Int {
        config.preCompactionFlushTimeoutMs
    }

    func recordMemoryWrite(path: String, conversationID: UUID) async {
        await writeTracker.recordMainAgentWrite(path: path, conversationID: conversationID)
        await activeMemory.invalidateStanding(conversationID: conversationID)
    }

    func recordAuxiliaryMemoryWrite(path: String, conversationID: UUID) async {
        await writeTracker.recordAuxiliaryWrite(path: path, conversationID: conversationID)
    }

    func memoryDirectory(for conversationID: UUID) -> URL? {
        sessionByConversation[conversationID]?.memoryDirectory
    }

    func sessionContext(for conversationID: UUID) async -> MemorySessionContext? {
        sessionByConversation[conversationID]
    }

    func manifestEntries(conversationID: UUID) async -> [MemoryManifestEntry] {
        storeByConversation[conversationID]?.manifest() ?? []
    }

    func hybridSearch() -> HybridMemorySearch { search }

    func runDreamingSweep(memoryDirectory: URL, rollback: Bool = false) async throws {
        try await dreaming.runSweep(memoryDirectory: memoryDirectory, rollback: rollback)
    }

    func runDreamingSweep(conversationID: UUID, rollback: Bool = false) async throws {
        guard let context = sessionByConversation[conversationID] else { return }
        try await runDreamingSweep(memoryDirectory: context.memoryDirectory, rollback: rollback)
    }

    nonisolated func makeSessionContext(conversationID: UUID, cwd: String, chatType: MemoryChatType = .direct) throws -> MemorySessionContext {
        let gitRoot = GitRootResolver.canonicalGitRoot(for: cwd)
        let memoryDir = try AgentMemoryPathResolver.resolveMemoryDirectory(canonicalGitRoot: gitRoot, cwd: cwd)
        return MemorySessionContext(
            conversationID: conversationID,
            cwd: cwd,
            canonicalGitRoot: gitRoot,
            memoryDirectory: memoryDir,
            chatType: chatType
        )
    }

    private func buildBlocks(context: MemorySessionContext, store: AgentMemoryStore, recalled: String) throws -> MemorySystemPromptBlocks {
        let project = ProjectInstructionLoader.load(
            cwd: context.cwd,
            canonicalGitRoot: context.canonicalGitRoot,
            managedPath: config.managedInstructionsPath,
            userConfigDir: userConfigDir
        )
        let index = try store.readIndexSnapshot()
        let taxonomy = """
\(MemoryTypeTaxonomy.indexUsagePrompt)
\(MemoryTypeTaxonomy.whatNotToSavePrompt)
\(MemoryTypeTaxonomy.persistenceDistinctionPrompt)
"""
        var sensitive = MemoryTypeTaxonomy.sensitiveDataPrompt
        if config.teamMemoryEnabled {
            sensitive += "\n" + MemoryTypeTaxonomy.teamSensitiveDataPrompt
        }
        let pathDisclosure = """
You have a persistent, file-based memory system at \(context.memoryDirectory.path).
"""
        let generation = 0
        return MemorySystemPromptBlocks(
            projectInstructionsText: project.text,
            memoryIndexText: index.isEmpty ? "" : "# Agent memory index\n\(index)",
            recalledTopicBodiesText: recalled,
            taxonomyPromptText: taxonomy,
            driftGuardText: MemoryTypeTaxonomy.driftGuardPrompt,
            sensitiveDataPromptText: sensitive,
            memoryPathDisclosureText: pathDisclosure,
            snapshotGeneration: generation
        )
    }

    private func runExtractionPlaceholder(request: MemoryTurnEndedRequest) async {
        guard let store = storeByConversation[request.session.conversationID] else { return }
        let manifest = store.manifest().map(MemoryManifestScanner.formatManifestLine)
        logger?.debug("[MemoryExtractor] would extract with manifest lines=\(manifest.count)")
        _ = MemoryExtractionPrompts.systemPrompt(manifestLines: manifest, teamMemoryEnabled: config.teamMemoryEnabled)
    }
}
