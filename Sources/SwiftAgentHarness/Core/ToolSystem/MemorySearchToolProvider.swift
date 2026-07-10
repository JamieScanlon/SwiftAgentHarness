import EasyJSON
import Foundation
import SwiftAgentKit

public struct MemorySearchToolProvider: ToolProvider, ToolDescriptorHinting {
    public static let searchToolName = "memory_search"
    public static let getToolName = "memory_get"

    private let memoryDirectory: URL
    private let dependencies: MemorySearchToolDependencies
    private let recallStore: DreamRecallStore

    public var name: String { "MemorySearch" }
    public var descriptorHintsByToolName: [String: ToolDescriptorHints] {
        [
            Self.searchToolName: ToolDescriptorHints(effectClass: .readOnly, parallelHint: .parallelizable),
            Self.getToolName: ToolDescriptorHints(effectClass: .readOnly, parallelHint: .parallelizable),
        ]
    }

    init(memoryDirectory: URL, dependencies: MemorySearchToolDependencies, recallStore: DreamRecallStore? = nil) {
        self.memoryDirectory = memoryDirectory
        self.dependencies = dependencies
        self.recallStore = recallStore ?? DreamRecallStore(memoryDirectory: memoryDirectory)
    }

    init(memoryDirectory: URL, search: HybridMemorySearch, recallStore: DreamRecallStore? = nil) {
        self.memoryDirectory = memoryDirectory
        self.dependencies = MemorySearchToolDependencies(
            search: { query, corpus, limit in
                if let corpus, !corpus.isEmpty, corpus != MemorySearchCorpusNames.builtinFile, corpus != MemorySearchCorpusNames.all {
                    return []
                }
                return await search.search(query: query, memoryDirectory: memoryDirectory, limit: limit)
            },
            get: { lookupID, corpus in
                if let corpus, !corpus.isEmpty, corpus != MemorySearchCorpusNames.builtinFile {
                    return nil
                }
                let store = AgentMemoryStore(memoryDirectory: memoryDirectory)
                if let topic = try? store.readTopicBody(filename: lookupID) {
                    return topic
                }
                return try? store.readDailyBody(filename: lookupID)
            },
            activeCorpusName: { MemorySearchCorpusNames.builtinFile },
            availableCorpora: { [MemorySearchCorpusNames.builtinFile, MemorySearchCorpusNames.all] }
        )
        self.recallStore = recallStore ?? DreamRecallStore(memoryDirectory: memoryDirectory)
    }

    public func availableTools() async -> [ToolDefinition] {
        let corpora = await dependencies.availableCorpora()
        let corpusList = corpora.joined(separator: ", ")
        return [
            ToolDefinition(
                name: Self.searchToolName,
                description: """
Search durable memory by query. Optional corpus selects the searchable collection: omit or use the active backend (\(await dependencies.activeCorpusName())) for default memory only; use "all" to search the active backend plus every registered corpus supplement; or pass a specific corpus name (\(corpusList)). Results include provenance (corpus, citation, updated-at, line ranges when available).
""",
                parameters: [
                    .init(name: "query", description: "Search query", type: "string", required: true),
                    .init(name: "corpus", description: "Optional corpus selector: active backend name, \"all\", or a registered supplement name", type: "string", required: false),
                ],
                type: .function
            ),
            ToolDefinition(
                name: Self.getToolName,
                description: """
Read a memory search hit by lookup ID (usually a filename for the file backend). When the hit came from a non-default corpus, pass the same corpus name used in memory_search.
""",
                parameters: [
                    .init(name: "filename", description: "Lookup ID from memory_search (e.g. user_role.md)", type: "string", required: true),
                    .init(name: "corpus", description: "Corpus name when fetching a supplement hit; omit for the active backend", type: "string", required: false),
                ],
                type: .function
            ),
        ]
    }

    public func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
        switch toolCall.name {
        case Self.searchToolName:
            let query = extractString(from: toolCall.arguments, key: "query") ?? ""
            let corpus = extractString(from: toolCall.arguments, key: "corpus")
            let hits = await dependencies.search(query, corpus, 10)
            try? recallStore.recordSearchHits(query: query, hits: hits)
            let rendered = MemorySearchHitRenderer.renderList(hits)
            return ToolResult(success: true, content: rendered, metadata: .object(["source": .string("memory_search")]), toolCallId: toolCall.id)
        case Self.getToolName:
            let lookupID = extractString(from: toolCall.arguments, key: "filename") ?? ""
            let corpus = extractString(from: toolCall.arguments, key: "corpus")
            guard let body = await dependencies.get(lookupID, corpus) else {
                return ToolResult(success: false, content: "", metadata: .object(["source": .string("memory_search")]), toolCallId: toolCall.id, error: "Not found")
            }
            try? recallStore.recordGet(filename: lookupID, snippet: body)
            return ToolResult(success: true, content: body, metadata: .object(["source": .string("memory_search")]), toolCallId: toolCall.id)
        default:
            return ToolResult(success: false, content: "", metadata: .object(["source": .string("memory_search")]), toolCallId: toolCall.id, error: "Unknown tool")
        }
    }

    private func extractString(from arguments: JSON, key: String) -> String? {
        guard case .object(let dict) = arguments, let value = dict[key] else { return nil }
        if case .string(let s) = value { return s }
        return nil
    }
}
