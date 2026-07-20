import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Memory corpus search")
struct MemoryCorpusSearchTests {
    private struct StubCorpusSupplement: MemoryCorpusSupplementSearching {
        let pluginID: String
        let corpusName: String
        let searchHits: [MemorySearchHit]
        let getBodies: [String: String]

        func search(query: String, limit: Int) async -> [MemorySearchHit] {
            _ = query
            return Array(searchHits.prefix(limit))
        }

        func get(lookupID: String) async -> String? {
            getBodies[lookupID]
        }
    }

    private func makeMemoryDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("corpus-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeTopic(dir: URL, filename: String, body: String) throws {
        let store = AgentMemoryStore(memoryDirectory: dir)
        try store.writeTopic(
            filename: filename,
            content: """
            ---
            name: \(filename)
            description: \(body)
            type: reference
            ---
            \(body)
            """
        )
    }

    private func bootstrapService(memoryDir: URL, cwd: URL) async throws -> (DefaultMemoryService, UUID) {
        let service = DefaultMemoryService(config: .default)
        let conversationID = UUID()
        let context = MemorySessionContext(
            conversationID: conversationID,
            cwd: cwd.path,
            canonicalGitRoot: cwd.path,
            memoryDirectory: memoryDir
        )
        _ = try await service.bootstrapSession(context: context)
        return (service, conversationID)
    }

    private func supplementHit(
        lookupID: String,
        score: Double,
        snippet: String,
        corpus: String
    ) -> MemorySearchHit {
        MemorySearchHit(
            lookupID: lookupID,
            score: score,
            snippet: snippet,
            provenance: MemorySearchProvenance(
                corpus: corpus,
                provenanceLabel: "Stub wiki page",
                sourceType: "wiki-page",
                sourcePath: lookupID,
                citation: MemorySearchProvenance.citationToken(corpus: corpus, sourcePath: lookupID, lineRange: nil),
                updatedAt: nil,
                lineRange: nil
            )
        )
    }

    @Test("file backend hits include provenance fields")
    func fileBackendProvenance() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeTopic(dir: dir, filename: "user_role.md", body: "platform engineer observability dashboard")

        let hits = await HybridMemorySearch().search(query: "platform observability", memoryDirectory: dir, limit: 5)
        #expect(!hits.isEmpty)
        let hit = try #require(hits.first { $0.lookupID == "user_role.md" })
        #expect(hit.provenance.corpus == MemorySearchCorpusNames.builtinFile)
        #expect(hit.provenance.sourceType == "memory-topic")
        #expect(hit.provenance.sourcePath == "user_role.md")
        #expect(hit.provenance.citation.contains("user_role.md"))
        #expect(hit.provenance.updatedAt != nil)
        #expect(hit.provenance.lineRange != nil)
    }

    @Test("corpus supplement registry replaces same plugin ID")
    func registryReplaceByPluginID() async {
        let service = DefaultMemoryService(config: .default)
        let first = StubCorpusSupplement(
            pluginID: "wiki-plugin",
            corpusName: "stub-wiki-v1",
            searchHits: [],
            getBodies: [:]
        )
        let second = StubCorpusSupplement(
            pluginID: "wiki-plugin",
            corpusName: "stub-wiki-v2",
            searchHits: [],
            getBodies: [:]
        )
        await service.registerCorpusSupplement(first)
        await service.registerCorpusSupplement(second)
        let names = await service.corpusSupplementNames()
        #expect(names == ["stub-wiki-v2"])
    }

    @Test("corpus=all federates backend and supplement hits sorted by score")
    func corpusAllFederation() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeTopic(dir: dir, filename: "backend_topic.md", body: "backend metrics pipeline tokens")

        let (service, conversationID) = try await bootstrapService(memoryDir: dir, cwd: dir)
        let supplementHit = supplementHit(
            lookupID: "wiki-page.md",
            score: 99.0,
            snippet: "supplement wiki content",
            corpus: "stub-wiki"
        )
        await service.registerCorpusSupplement(
            StubCorpusSupplement(
                pluginID: "wiki-plugin",
                corpusName: "stub-wiki",
                searchHits: [supplementHit],
                getBodies: ["wiki-page.md": "full wiki body"]
            )
        )

        let hits = await service.searchMemory(
            conversationID: conversationID,
            query: "metrics pipeline",
            corpus: MemorySearchCorpusNames.all,
            limit: 10
        )
        #expect(hits.contains { $0.lookupID == "backend_topic.md" })
        #expect(hits.contains { $0.lookupID == "wiki-page.md" })
        #expect(hits.first?.lookupID == "wiki-page.md")
    }

    @Test("corpus targeting returns only supplement hits")
    func corpusTargeting() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeTopic(dir: dir, filename: "backend_only.md", body: "backend exclusive tokens")

        let (service, conversationID) = try await bootstrapService(memoryDir: dir, cwd: dir)
        await service.registerCorpusSupplement(
            StubCorpusSupplement(
                pluginID: "wiki-plugin",
                corpusName: "stub-wiki",
                searchHits: [
                    supplementHit(
                        lookupID: "wiki-only.md",
                        score: 50,
                        snippet: "wiki exclusive",
                        corpus: "stub-wiki"
                    ),
                ],
                getBodies: [:]
            )
        )

        let hits = await service.searchMemory(
            conversationID: conversationID,
            query: "exclusive",
            corpus: "stub-wiki",
            limit: 10
        )
        #expect(hits.count == 1)
        #expect(hits[0].lookupID == "wiki-only.md")
        #expect(hits[0].provenance.corpus == "stub-wiki")
    }

    @Test("getMemory routes to supplement or active backend")
    func getMemoryRouting() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeTopic(dir: dir, filename: "local_topic.md", body: "local backend body content")

        let (service, conversationID) = try await bootstrapService(memoryDir: dir, cwd: dir)
        await service.registerCorpusSupplement(
            StubCorpusSupplement(
                pluginID: "wiki-plugin",
                corpusName: "stub-wiki",
                searchHits: [],
                getBodies: ["remote.md": "remote supplement body"]
            )
        )

        let backendBody = await service.getMemory(conversationID: conversationID, lookupID: "local_topic.md", corpus: nil)
        #expect(backendBody?.contains("local backend body") == true)

        let supplementBody = await service.getMemory(
            conversationID: conversationID,
            lookupID: "remote.md",
            corpus: "stub-wiki"
        )
        #expect(supplementBody == "remote supplement body")
    }

    @Test("memory_search tool output includes corpus and cite tokens")
    func toolRenderingIncludesProvenance() async throws {
        let dir = try makeMemoryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeTopic(dir: dir, filename: "render_topic.md", body: "render provenance citation tokens")

        let provider = MemorySearchToolProvider(memoryDirectory: dir, search: HybridMemorySearch())
        let result = try await provider.executeTool(
            ToolCall(
                name: MemorySearchToolProvider.searchToolName,
                arguments: .object(["query": .string("render provenance")]),
                id: "render-1"
            )
        )
        #expect(result.success)
        #expect(result.content.contains("corpus="))
        #expect(result.content.contains("cite="))
        #expect(result.content.contains(MemorySearchCorpusNames.builtinFile))
    }
}
