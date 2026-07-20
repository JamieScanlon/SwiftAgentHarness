import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Memory cross-tier dedupe policy")
struct MemoryCrossTierDedupPolicyTests {
    @Test("parses tier1 body markers into selection keys")
    func tier1BodyMarkerParsing() {
        let tier1 = """
        # Memory index
        [scope:project] <!-- topic-a.md -->
        line one

        [scope:user] <!-- prefs.md -->
        user pref
        """
        let keys = MemoryCrossTierDedupPolicy.bodyProjectedSelectionKeys(fromTier1Content: tier1)
        #expect(keys == ["topic-a.md", "user/prefs.md"])
    }

    @Test("filterTier2Hits preserves order and drops projected keys")
    func filterTier2HitsOrdering() {
        let hits = [
            MemoryRecallHit(selectionKey: "a.md", formattedBody: "a"),
            MemoryRecallHit(selectionKey: "b.md", formattedBody: "b"),
            MemoryRecallHit(selectionKey: "c.md", formattedBody: "c"),
        ]
        let filtered = MemoryCrossTierDedupPolicy.filterTier2Hits(hits, excluding: ["b.md"])
        #expect(filtered.map(\.selectionKey) == ["a.md", "c.md"])
    }

    @Test("parses recall message bodies into selection keys")
    func recallMessageParsing() {
        let body = MemoryRecallBodyFormatter.format(scope: .project, filename: "dup.md", body: "fact")
        let message = HarnessInjectedMessageMetadata.systemMessage(
            id: UUID(),
            content: """
\(HarnessInjectedMessagePrefixes.memoryRecall)
\(MemoryContextFencer.fence(body))
"""
        )
        let keys = MemoryCrossTierDedupPolicy.bodyProjectedSelectionKeys(fromRecallMessage: message)
        #expect(keys == ["dup.md"])
    }

    @Test("exclusion prompt fragment lists sorted keys")
    func exclusionPromptFragment() {
        let fragment = MemoryCrossTierDedupPolicy.exclusionPromptFragment(keys: ["z.md", "a.md"])
        #expect(fragment?.contains("a.md, z.md") == true)
        #expect(fragment?.contains("do not read or summarize") == true)
    }
}
