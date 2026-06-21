import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Harness injection prefix registry")
struct HarnessInjectionPrefixRegistryTests {
    @Test("coverage prefixes match memory context injection header")
    func memoryContextHeaderMatchesRegistry() {
        let injectedHeader = HarnessInjectedMessagePrefixes.memoryContext
        #expect(HarnessInjectedMessagePrefixes.coveragePrefixes.contains(injectedHeader))
    }

    @Test("coverage prefixes match memory recall injection header")
    func memoryRecallHeaderMatchesRegistry() {
        let injectedHeader = HarnessInjectedMessagePrefixes.memoryRecall
        #expect(HarnessInjectedMessagePrefixes.coveragePrefixes.contains(injectedHeader))
    }

    @Test("coverage prefixes match active memory recall injection header")
    func activeMemoryRecallHeaderMatchesRegistry() {
        let injectedHeader = HarnessInjectedMessagePrefixes.activeMemoryRecall
        #expect(HarnessInjectedMessagePrefixes.coveragePrefixes.contains(injectedHeader))
    }

    @Test("coverage prefixes match trigger provenance injection header")
    func triggerProvenanceHeaderMatchesRegistry() {
        let injectedHeader = HarnessInjectedMessagePrefixes.triggerProvenance
        #expect(HarnessInjectedMessagePrefixes.coveragePrefixes.contains(injectedHeader))
    }

    @Test("injection site literals use registry prefixes")
    func injectionSiteLiteralsUseRegistryPrefixes() {
        let memoryContextSample = """
\(HarnessInjectedMessagePrefixes.memoryContext)
snapshot body
"""
        let memoryRecallSample = """
\(HarnessInjectedMessagePrefixes.memoryRecall)
recalled body
"""
        let activeRecallSample = """
\(HarnessInjectedMessagePrefixes.activeMemoryRecall)
active body
"""
        for sample in [memoryContextSample, memoryRecallSample, activeRecallSample] {
            let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(HarnessInjectedMessagePrefixes.coveragePrefixes.contains { trimmed.hasPrefix($0) })
        }
    }

    @Test("metadata flag marks injected system messages")
    func metadataFlagMarksInjectedMessages() {
        let message = HarnessInjectedMessageMetadata.systemMessage(
            id: UUID(),
            content: "harness payload without legacy prefix"
        )
        #expect(HarnessInjectedMessageMetadata.isHarnessInjected(message))
    }

    @Test("legacy prefix-only system messages remain injected")
    func legacyPrefixOnlyMessagesRemainInjected() {
        let message = Message(
            id: UUID(),
            role: .system,
            content: """
\(HarnessInjectedMessagePrefixes.memoryContext)
legacy body
""",
            timestamp: Date(),
            toolCalls: []
        )
        #expect(HarnessInjectedMessageMetadata.isHarnessInjected(message))
    }

    @Test("metadata flag excludes messages from compaction coverage without prefix")
    func metadataExcludesFromCompactionCoverageWithoutPrefix() {
        let injected = HarnessInjectedMessageMetadata.systemMessage(
            id: UUID(),
            content: "no legacy prefix header"
        )
        let thread = Message(id: UUID(), role: .user, content: "hello", timestamp: Date(), toolCalls: [])
        let coverage = ContextCompactionCheckpointSupport.transcriptForCompactionCoverage([injected, thread])
        #expect(coverage.map(\.id) == [thread.id])
    }
}
