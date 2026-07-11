import Foundation
import SwiftAgentKit

struct MemoryArtifact: Sendable, Equatable {
    let kind: String
    let workspaceDir: String
    let relativePath: String
    let absolutePath: String
    let contentType: String
}

struct MemoryBackendPromptSections: Sendable, Equatable {
    let memoryIndexText: String
    let recalledTopicBodiesText: String
    let taxonomyPromptText: String
    let driftGuardText: String
    let sensitiveDataPromptText: String
    let memoryPathDisclosureText: String
}

struct MemoryFlushPlan: Sendable, Equatable {
    let systemPrompt: String
    let userPrompt: String
    let writeGuardPolicy: PreCompactionFlushWriteGuard.Policy
}

struct MemoryCapability: Sendable {
    let pluginID: String
    let runtime: any MemoryRuntime
    let promptBuilder: (any MemoryPromptBuilding)?
    let flushPlanResolver: (any MemoryFlushPlanResolving)?
    let publicArtifacts: (any MemoryPublicArtifactsProviding)?

    init(
        pluginID: String,
        runtime: any MemoryRuntime,
        promptBuilder: (any MemoryPromptBuilding)? = nil,
        flushPlanResolver: (any MemoryFlushPlanResolving)? = nil,
        publicArtifacts: (any MemoryPublicArtifactsProviding)? = nil
    ) {
        self.pluginID = pluginID
        self.runtime = runtime
        self.promptBuilder = promptBuilder
        self.flushPlanResolver = flushPlanResolver
        self.publicArtifacts = publicArtifacts
    }

    /// Wraps a legacy lifecycle-hook provider as the exclusive active backend (test/transition API).
    static func fromLegacyLifecycleProvider(id: String, provider: any MemoryProviding) -> MemoryCapability {
        MemoryCapability(
            pluginID: id,
            runtime: LegacyLifecycleMemoryRuntime(provider: provider),
            promptBuilder: EmptyMemoryPromptBuilder(),
            flushPlanResolver: nil,
            publicArtifacts: nil
        )
    }
}

protocol MemoryPromptBuilding: Sendable {
    func buildPromptSections(
        context: MemorySessionContext,
        store: AgentMemoryStore,
        recalled: String,
        availableToolNames: [String]
    ) throws -> MemoryBackendPromptSections
}

protocol MemoryFlushPlanResolving: Sendable {
    func resolveFlushPlan(
        manifestLines: [String],
        middleTranscript: String,
        session: MemorySessionContext,
        store: AgentMemoryStore
    ) -> MemoryFlushPlan

    func flushedMemoryEntryIDs(
        from flushPaths: Set<String>,
        session: MemorySessionContext,
        maxEntries: Int
    ) -> [UUID]
}

protocol MemoryPublicArtifactsProviding: Sendable {
    func publicArtifacts(context: MemorySessionContext, store: AgentMemoryStore) -> [MemoryArtifact]
}

protocol MemoryRuntime: Sendable {
    func initialize(sessionID: UUID, context: MemorySessionContext) async throws
    func endSession(conversationID: UUID) async
    func shutdown() async
    func recallForTurn(request: MemoryRecallRequest) async throws -> MemoryRecallResult
    func onTurnEnded(request: MemoryTurnEndedRequest) async
    func onPreCompress(messages: [String]) async -> String
    func refreshSnapshotAfterFlush(conversationID: UUID) async throws
    func systemPromptBlocks(conversationID: UUID) async -> MemorySystemPromptBlocks?
    func currentSnapshotGeneration(conversationID: UUID) async -> Int
    func invalidateSnapshot(conversationID: UUID) async
    func manifestEntries(conversationID: UUID) async -> [MemoryManifestEntry]
    func hybridSearch() async -> HybridMemorySearch
    func updateSnapshot(conversationID: UUID, blocks: MemorySystemPromptBlocks, manifest: [MemoryManifestEntry]) async
    func runDreamingSweep(memoryDirectory: URL, rollback: Bool) async throws
    func bindSpawnPort(_ port: MemorySubAgentSpawnPort) async
    func drainPendingWork(timeoutMs: Int) async
    func store(for conversationID: UUID) async -> AgentMemoryStore?
    func sessionContext(for conversationID: UUID) async -> MemorySessionContext?
    func activeRecallSummary(
        session: MemorySessionContext,
        messages: [Message],
        anchorUserMessageID: UUID?,
        sessionEnabled: Bool,
        excludedSelectionKeys: Set<String>
    ) async -> ActiveMemoryRecallOutcome
    func warmStandingRecall(session: MemorySessionContext, sessionEnabled: Bool) async
    func prefetchSituationalRecall(
        session: MemorySessionContext,
        messages: [Message],
        anchorUserMessageID: UUID?,
        sessionEnabled: Bool
    ) async
    func invalidateStandingRecall(conversationID: UUID) async
}

struct EmptyMemoryPromptBuilder: MemoryPromptBuilding {
    func buildPromptSections(
        context: MemorySessionContext,
        store: AgentMemoryStore,
        recalled: String,
        availableToolNames: [String]
    ) throws -> MemoryBackendPromptSections {
        _ = context
        _ = store
        _ = recalled
        _ = availableToolNames
        return MemoryBackendPromptSections(
            memoryIndexText: "",
            recalledTopicBodiesText: "",
            taxonomyPromptText: "",
            driftGuardText: "",
            sensitiveDataPromptText: "",
            memoryPathDisclosureText: ""
        )
    }
}

struct LegacyLifecycleMemoryRuntime: MemoryRuntime {
    let provider: any MemoryProviding

    func initialize(sessionID: UUID, context: MemorySessionContext) async throws {
        try await provider.initialize(sessionID: sessionID, context: context)
    }

    func endSession(conversationID: UUID) async {
        _ = conversationID
        await provider.onSessionEnd(messages: [])
    }

    func shutdown() async {
        await provider.shutdown()
    }

    func recallForTurn(request: MemoryRecallRequest) async throws -> MemoryRecallResult {
        _ = request
        return MemoryRecallResult(selectedFilenames: [], hits: [])
    }

    func onTurnEnded(request: MemoryTurnEndedRequest) async {
        _ = request
    }

    func onPreCompress(messages: [String]) async -> String {
        await provider.onPreCompress(messages: messages)
    }

    func refreshSnapshotAfterFlush(conversationID: UUID) async throws {
        _ = conversationID
    }

    func systemPromptBlocks(conversationID: UUID) async -> MemorySystemPromptBlocks? {
        _ = conversationID
        return nil
    }

    func currentSnapshotGeneration(conversationID: UUID) async -> Int {
        _ = conversationID
        return 0
    }

    func invalidateSnapshot(conversationID: UUID) async {
        _ = conversationID
    }

    func manifestEntries(conversationID: UUID) async -> [MemoryManifestEntry] {
        _ = conversationID
        return []
    }

    func hybridSearch() async -> HybridMemorySearch {
        HybridMemorySearch()
    }

    func runDreamingSweep(memoryDirectory: URL, rollback: Bool) async throws {
        _ = memoryDirectory
        _ = rollback
    }

    func bindSpawnPort(_ port: MemorySubAgentSpawnPort) async {
        _ = port
    }

    func drainPendingWork(timeoutMs: Int) async {
        _ = timeoutMs
    }

    func store(for conversationID: UUID) async -> AgentMemoryStore? {
        _ = conversationID
        return nil
    }

    func sessionContext(for conversationID: UUID) async -> MemorySessionContext? {
        _ = conversationID
        return nil
    }

    func activeRecallSummary(
        session: MemorySessionContext,
        messages: [Message],
        anchorUserMessageID: UUID?,
        sessionEnabled: Bool,
        excludedSelectionKeys: Set<String> = []
    ) async -> ActiveMemoryRecallOutcome {
        _ = session
        _ = messages
        _ = anchorUserMessageID
        _ = sessionEnabled
        _ = excludedSelectionKeys
        return .skipped(reason: "legacy_provider", queryMode: .recent)
    }

    func warmStandingRecall(session: MemorySessionContext, sessionEnabled: Bool) async {
        _ = session
        _ = sessionEnabled
    }

    func prefetchSituationalRecall(
        session: MemorySessionContext,
        messages: [Message],
        anchorUserMessageID: UUID?,
        sessionEnabled: Bool
    ) async {
        _ = session
        _ = messages
        _ = anchorUserMessageID
        _ = sessionEnabled
    }

    func invalidateStandingRecall(conversationID: UUID) async {
        _ = conversationID
    }

    func updateSnapshot(conversationID: UUID, blocks: MemorySystemPromptBlocks, manifest: [MemoryManifestEntry]) async {
        _ = conversationID
        _ = blocks
        _ = manifest
    }
}
