import Foundation
import EasyJSON
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Memory recall selection policy")
struct MemoryRecallSelectionPolicyTests {
    private func referenceEntry(
        filename: String = "grafana.md",
        name: String = "Grafana dashboards",
        description: String = "How to use grafana dashboards"
    ) -> MemoryManifestEntry {
        MemoryManifestEntry(
            filename: filename,
            memoryType: .reference,
            name: name,
            description: description,
            updatedAt: nil
        )
    }

    @Test("activeToolNames collects tool call names from messages")
    func activeToolNamesFromMessages() {
        let messages = [
            Message(
                id: UUID(),
                role: .assistant,
                content: "",
                timestamp: Date(),
                toolCalls: [ToolCall(name: "memory_search", arguments: .object([:]), id: "1")]
            ),
            Message(
                id: UUID(),
                role: .assistant,
                content: "",
                timestamp: Date(),
                toolCalls: [ToolCall(name: "read_file", arguments: .object([:]), id: "2")]
            ),
        ]
        let names = MemoryRecallSelectionPolicy.activeToolNames(from: messages)
        #expect(names == ["memory_search", "read_file"])
    }

    @Test("heuristic min score drops weak single-token matches")
    func heuristicThresholdDropsWeakMatch() async {
        let selector = HeuristicMemoryRecallSelector(minScore: 4)
        let session = MemorySessionContext(
            conversationID: UUID(),
            cwd: "/tmp",
            canonicalGitRoot: nil,
            memoryDirectory: URL(fileURLWithPath: "/tmp/memory")
        )
        let entries = [
            MemoryManifestEntry(
                filename: "topic.md",
                memoryType: .project,
                name: "Topic",
                description: "unrelated description",
                updatedAt: nil
            ),
        ]
        let weak = await selector.selectRelevantFiles(
            request: MemoryRecallRequest(
                session: session,
                userQuery: "topic",
                manifestEntries: entries
            )
        )
        #expect(weak.isEmpty)
    }

    @Test("heuristic min score keeps strong multi-token matches")
    func heuristicThresholdKeepsStrongMatch() async {
        let selector = HeuristicMemoryRecallSelector(minScore: 4)
        let session = MemorySessionContext(
            conversationID: UUID(),
            cwd: "/tmp",
            canonicalGitRoot: nil,
            memoryDirectory: URL(fileURLWithPath: "/tmp/memory")
        )
        let entries = [
            MemoryManifestEntry(
                filename: "topic3.md",
                memoryType: .reference,
                name: "Topic 3",
                description: "desc 3",
                updatedAt: nil
            ),
        ]
        let strong = await selector.selectRelevantFiles(
            request: MemoryRecallRequest(
                session: session,
                userQuery: "topic 3 desc",
                manifestEntries: entries
            )
        )
        #expect(strong == ["topic3.md"])
    }

    @Test("usage-reference memories drop when tool is actively in use")
    func dropsUsageReferenceWhenToolActive() {
        let entry = referenceEntry(description: "How to use memory_search effectively")
        let filtered = MemoryRecallSelectionPolicy.filterUsageReferenceRedundancy(
            selectionKeys: [entry.selectionKey],
            manifest: [entry],
            activeToolNames: ["memory_search"]
        )
        #expect(filtered.isEmpty)
    }

    @Test("gotcha reference memories are kept when tool is actively in use")
    func keepsGotchaReferenceWhenToolActive() {
        let entry = referenceEntry(description: "Known issue with memory_search timeouts")
        let filtered = MemoryRecallSelectionPolicy.filterUsageReferenceRedundancy(
            selectionKeys: [entry.selectionKey],
            manifest: [entry],
            activeToolNames: ["memory_search"]
        )
        #expect(filtered == [entry.selectionKey])
    }

    @Test("post-filter preserves relevance order")
    func preservesOrder() {
        let usage = referenceEntry(filename: "a.md", name: "A", description: "memory_search usage guide")
        let gotcha = referenceEntry(filename: "b.md", name: "B", description: "memory_search gotcha")
        let project = MemoryManifestEntry(
            filename: "c.md",
            memoryType: .project,
            name: "C",
            description: "project fact",
            updatedAt: nil
        )
        let manifest = [usage, gotcha, project]
        let result = MemoryRecallSelectionPolicy.applyPostSelectionFilters(
            selectionKeys: [usage.selectionKey, gotcha.selectionKey, project.selectionKey],
            manifest: manifest,
            activeToolNames: ["memory_search"]
        )
        #expect(result == [gotcha.selectionKey, project.selectionKey])
    }
}
