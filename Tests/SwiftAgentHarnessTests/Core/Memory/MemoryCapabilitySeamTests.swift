import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Memory capability seams")
struct MemoryCapabilitySeamTests {
    private struct StubPromptBuilder: MemoryPromptBuilding {
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
                memoryIndexText: "STUB-INDEX",
                recalledTopicBodiesText: recalled,
                taxonomyPromptText: "STUB-TAXONOMY",
                driftGuardText: "",
                sensitiveDataPromptText: "",
                memoryPathDisclosureText: "STUB-PATH"
            )
        }
    }

    private struct StubFlushPlanResolver: MemoryFlushPlanResolving {
        func resolveFlushPlan(
            manifestLines: [String],
            middleTranscript: String,
            session: MemorySessionContext,
            store: AgentMemoryStore
        ) -> MemoryFlushPlan {
            _ = manifestLines
            _ = middleTranscript
            _ = session
            _ = store
            return MemoryFlushPlan(
                systemPrompt: "STUB-FLUSH-SYSTEM",
                userPrompt: "STUB-FLUSH-USER",
                writeGuardPolicy: PreCompactionFlushWriteGuard.Policy(manifestTopicFilenames: ["existing.md"])
            )
        }

        func flushedMemoryEntryIDs(
            from flushPaths: Set<String>,
            session: MemorySessionContext,
            maxEntries: Int
        ) -> [UUID] {
            _ = session
            return flushPaths
                .map { URL(fileURLWithPath: $0).lastPathComponent }
                .filter { AgentMemoryStore.isDailyFilename($0) }
                .prefix(maxEntries)
                .map { _ in UUID(uuidString: "00000000-0000-4000-8000-000000000001")! }
        }
    }

    private struct StubPublicArtifactsProvider: MemoryPublicArtifactsProviding {
        func publicArtifacts(context: MemorySessionContext, store: AgentMemoryStore) -> [MemoryArtifact] {
            _ = store
            return [
                MemoryArtifact(
                    kind: "stub-export",
                    workspaceDir: context.memoryDirectory.path,
                    relativePath: "stub.md",
                    absolutePath: context.memoryDirectory.appendingPathComponent("stub.md").path,
                    contentType: "text/markdown"
                ),
            ]
        }
    }

    private actor StubSeamRuntime: MemoryRuntime {
        private var session: MemorySessionContext?
        private var store: AgentMemoryStore?

        func initialize(sessionID: UUID, context: MemorySessionContext) async throws {
            _ = sessionID
            session = context
            store = AgentMemoryStore(memoryDirectory: context.memoryDirectory)
            try store?.ensureLayout()
        }

        func endSession(conversationID: UUID) async {
            _ = conversationID
            session = nil
            store = nil
        }

        func shutdown() async {}

        func recallForTurn(request: MemoryRecallRequest) async throws -> MemoryRecallResult {
            _ = request
            return MemoryRecallResult(selectedFilenames: [], recalledBodiesText: "")
        }

        func onTurnEnded(request: MemoryTurnEndedRequest) async { _ = request }

        func onPreCompress(messages: [String]) async -> String {
            _ = messages
            return ""
        }

        func refreshSnapshotAfterFlush(conversationID: UUID) async throws { _ = conversationID }

        func systemPromptBlocks(conversationID: UUID) async -> MemorySystemPromptBlocks? {
            _ = conversationID
            return nil
        }

        func currentSnapshotGeneration(conversationID: UUID) async -> Int {
            _ = conversationID
            return 1
        }

        func invalidateSnapshot(conversationID: UUID) async { _ = conversationID }

        func manifestEntries(conversationID: UUID) async -> [MemoryManifestEntry] {
            _ = conversationID
            return []
        }

        func hybridSearch() async -> HybridMemorySearch { HybridMemorySearch() }

        func updateSnapshot(
            conversationID: UUID,
            blocks: MemorySystemPromptBlocks,
            manifest: [MemoryManifestEntry]
        ) async {
            _ = conversationID
            _ = blocks
            _ = manifest
        }

        func runDreamingSweep(memoryDirectory: URL, rollback: Bool) async throws {
            _ = memoryDirectory
            _ = rollback
        }

        func bindSpawnPort(_ port: MemorySubAgentSpawnPort) async { _ = port }

        func drainPendingWork(timeoutMs: Int) async { _ = timeoutMs }

        func store(for conversationID: UUID) async -> AgentMemoryStore? {
            _ = conversationID
            return store
        }

        func sessionContext(for conversationID: UUID) async -> MemorySessionContext? {
            _ = conversationID
            return session
        }

        func activeRecallSummary(
            session: MemorySessionContext,
            messages: [Message],
            anchorUserMessageID: UUID?,
            sessionEnabled: Bool
        ) async -> ActiveMemoryRecallOutcome {
            _ = session
            _ = messages
            _ = anchorUserMessageID
            _ = sessionEnabled
            return .skipped(reason: "stub", queryMode: .recent)
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

        func invalidateStandingRecall(conversationID: UUID) async { _ = conversationID }
    }

    private func stubCapability() -> MemoryCapability {
        MemoryCapability(
            pluginID: "stub-seam-backend",
            runtime: StubSeamRuntime(),
            promptBuilder: StubPromptBuilder(),
            flushPlanResolver: StubFlushPlanResolver(),
            publicArtifacts: StubPublicArtifactsProvider()
        )
    }

    @Test("Prompt swap uses active backend promptBuilder sections")
    func promptSwapUsesBackendSections() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mem-seam-prompt-\(UUID().uuidString)", isDirectory: true)
        let memoryDir = dir.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let service = DefaultMemoryService(config: .default)
        await service.registerActiveMemoryCapability(stubCapability())
        let conversationID = UUID()
        let context = MemorySessionContext(
            conversationID: conversationID,
            cwd: dir.path,
            canonicalGitRoot: dir.path,
            memoryDirectory: memoryDir
        )
        let blocks = try await service.bootstrapSession(context: context)
        #expect(blocks.memoryIndexText == "STUB-INDEX")
        #expect(blocks.taxonomyPromptText == "STUB-TAXONOMY")
        #expect(blocks.memoryPathDisclosureText == "STUB-PATH")
        #expect(!blocks.taxonomyPromptText.contains("indexUsagePrompt"))
    }

    @Test("Flush policy swap uses backend write guard policy")
    func flushPolicySwapUsesBackendWriteGuard() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mem-seam-flush-\(UUID().uuidString)", isDirectory: true)
        let memoryDir = dir.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let service = DefaultMemoryService(config: .default)
        await service.registerActiveMemoryCapability(stubCapability())
        let conversationID = UUID()
        let context = MemorySessionContext(
            conversationID: conversationID,
            cwd: dir.path,
            canonicalGitRoot: dir.path,
            memoryDirectory: memoryDir
        )
        _ = try await service.bootstrapSession(context: context)

        let plan = await service.resolveFlushPlan(
            conversationID: conversationID,
            manifestLines: [],
            middleTranscript: "middle transcript"
        )
        let resolvedPlan = try #require(plan)
        #expect(resolvedPlan.systemPrompt == "STUB-FLUSH-SYSTEM")
        #expect(resolvedPlan.writeGuardPolicy.manifestTopicFilenames == ["existing.md"])

        await service.registerPreCompactionFlushWriteGuard(
            conversationID: conversationID,
            policy: resolvedPlan.writeGuardPolicy
        )
        let existingPath = memoryDir.appendingPathComponent("existing.md").path
        let violation = await service.validatePreCompactionFlushWrite(
            conversationID: conversationID,
            absolutePath: existingPath,
            priorContent: nil,
            newContent: """
---
name: Existing
description: desc
type: reference
---
Body
"""
        )
        #expect(violation != nil)
    }

    @Test("activePublicArtifacts returns backend exports")
    func activePublicArtifactsReturnsBackendExports() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mem-seam-artifacts-\(UUID().uuidString)", isDirectory: true)
        let memoryDir = dir.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let service = DefaultMemoryService(config: .default)
        await service.registerActiveMemoryCapability(stubCapability())
        let conversationID = UUID()
        let context = MemorySessionContext(
            conversationID: conversationID,
            cwd: dir.path,
            canonicalGitRoot: dir.path,
            memoryDirectory: memoryDir
        )
        _ = try await service.bootstrapSession(context: context)
        let artifacts = await service.activePublicArtifacts(conversationID: conversationID)
        #expect(artifacts.count == 1)
        #expect(artifacts.first?.kind == "stub-export")
        #expect(artifacts.first?.relativePath == "stub.md")
        #expect(await service.activeMemoryPluginID() == "stub-seam-backend")
    }

    @Test("File backend public artifacts include daily staging files")
    func fileBackendExportsDailyArtifacts() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mem-seam-daily-\(UUID().uuidString)", isDirectory: true)
        let memoryDir = dir.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let service = DefaultMemoryService(config: .default)
        let conversationID = UUID()
        let context = MemorySessionContext(
            conversationID: conversationID,
            cwd: dir.path,
            canonicalGitRoot: dir.path,
            memoryDirectory: memoryDir
        )
        _ = try await service.bootstrapSession(context: context)
        let store = AgentMemoryStore(memoryDirectory: memoryDir)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dailyDate = calendar.date(from: DateComponents(year: 2026, month: 7, day: 10))!
        try store.appendDailyNote("note", date: dailyDate, calendar: calendar)
        let artifacts = await service.activePublicArtifacts(conversationID: conversationID)
        #expect(artifacts.contains { $0.kind == "memory-daily" })
        #expect(artifacts.contains { $0.relativePath == "2026-07-10.md" })
    }
}
