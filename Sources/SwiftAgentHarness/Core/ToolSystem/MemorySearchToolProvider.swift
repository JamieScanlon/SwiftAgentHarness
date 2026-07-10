import EasyJSON
import Foundation
import SwiftAgentKit

public struct MemorySearchToolProvider: ToolProvider, ToolDescriptorHinting {
    public static let searchToolName = "memory_search"
    public static let getToolName = "memory_get"

    private let memoryDirectory: URL
    private let search: HybridMemorySearch
    private let recallStore: DreamRecallStore

    public var name: String { "MemorySearch" }
    public var descriptorHintsByToolName: [String: ToolDescriptorHints] {
        [
            Self.searchToolName: ToolDescriptorHints(effectClass: .readOnly, parallelHint: .parallelizable),
            Self.getToolName: ToolDescriptorHints(effectClass: .readOnly, parallelHint: .parallelizable),
        ]
    }

    init(memoryDirectory: URL, search: HybridMemorySearch, recallStore: DreamRecallStore? = nil) {
        self.memoryDirectory = memoryDirectory
        self.search = search
        self.recallStore = recallStore ?? DreamRecallStore(memoryDirectory: memoryDirectory)
    }

    public func availableTools() async -> [ToolDefinition] {
        [
            ToolDefinition(
                name: Self.searchToolName,
                description: "Search durable memory topic files by query.",
                parameters: [
                    .init(name: "query", description: "Search query", type: "string", required: true),
                ],
                type: .function
            ),
            ToolDefinition(
                name: Self.getToolName,
                description: "Read a memory topic file by filename.",
                parameters: [
                    .init(name: "filename", description: "Topic filename e.g. user_role.md", type: "string", required: true),
                ],
                type: .function
            ),
        ]
    }

    public func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
        switch toolCall.name {
        case Self.searchToolName:
            let query = extractString(from: toolCall.arguments, key: "query") ?? ""
            let hits = await search.search(query: query, memoryDirectory: memoryDirectory, limit: 10)
            try? recallStore.recordSearchHits(query: query, hits: hits)
            let rendered = hits.map { "[\($0.filename)] score=\($0.score): \($0.snippet)" }.joined(separator: "\n")
            return ToolResult(success: true, content: rendered, metadata: .object(["source": .string("memory_search")]), toolCallId: toolCall.id)
        case Self.getToolName:
            let filename = extractString(from: toolCall.arguments, key: "filename") ?? ""
            let store = AgentMemoryStore(memoryDirectory: memoryDirectory)
            guard let body = try store.readTopicBody(filename: filename) else {
                return ToolResult(success: false, content: "", metadata: .object(["source": .string("memory_search")]), toolCallId: toolCall.id, error: "Not found")
            }
            try? recallStore.recordGet(filename: filename, snippet: body)
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
