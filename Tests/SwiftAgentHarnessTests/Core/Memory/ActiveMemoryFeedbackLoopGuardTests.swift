import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Active memory feedback-loop guard")
struct ActiveMemoryFeedbackLoopGuardTests {
    @Test("stripInjectedRecallArtifacts removes fenced prior recall and Active Memory Recall prefix")
    func stripRemovesInjectedArtifacts() {
        let prior = MemoryContextFencer.fence("User prefers Grafana dashboards.")
        let contaminated = """
        \(HarnessInjectedMessagePrefixes.activeMemoryRecall)
        \(prior)

        what about latency dashboards?
        """
        let cleaned = MemoryContextFencer.stripInjectedRecallArtifacts(contaminated)
        #expect(!cleaned.contains("<memory-context>"))
        #expect(!cleaned.contains("</memory-context>"))
        #expect(!cleaned.contains(HarnessInjectedMessagePrefixes.activeMemoryRecall))
        #expect(!cleaned.contains(MemoryContextFencer.systemNote))
        #expect(cleaned.contains("what about latency dashboards?"))
        #expect(!cleaned.contains("User prefers Grafana dashboards."))
    }

    @Test("situational prompts sanitize contaminated query before user prompt")
    func situationalPromptStripsContaminatedQuery() {
        let prior = MemoryContextFencer.fence("standing note about preferences")
        let contaminated = """
        \(HarnessInjectedMessagePrefixes.activeMemoryRecall)
        \(prior)
        fix the flaky test
        """
        let user = ActiveMemoryPreReplyPrompts.prompts(
            for: .situational,
            query: contaminated,
            maxSummaryChars: 220
        ).user
        #expect(!user.contains("<memory-context>"))
        #expect(!user.contains(HarnessInjectedMessagePrefixes.activeMemoryRecall))
        #expect(user.contains("fix the flaky test"))
    }

    @Test("standing and situational prompts include exclusion fragment when keys passed")
    func exclusionFragmentInPrompts() {
        let prompts = ActiveMemoryPreReplyPrompts.prompts(
            for: .situational,
            query: "latency review",
            excludedSelectionKeys: ["topic-a.md", "user/prefs.md"]
        )
        #expect(prompts.system.contains("topic-a.md, user/prefs.md"))
        #expect(prompts.system.contains("do not read or summarize"))
        let standing = ActiveMemoryPreReplyPrompts.prompts(
            for: .standing,
            query: nil,
            excludedSelectionKeys: ["topic-a.md"]
        )
        #expect(standing.system.contains("topic-a.md"))
    }
}
