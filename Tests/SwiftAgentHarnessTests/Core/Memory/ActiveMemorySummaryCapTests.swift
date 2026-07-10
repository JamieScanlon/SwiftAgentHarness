import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Active memory summary cap")
struct ActiveMemorySummaryCapTests {
    @Test("default activeMemoryMaxSummaryChars is 220")
    func defaultIsCompactNoteBudget() {
        #expect(MemoryConfiguration.default.activeMemoryMaxSummaryChars == 220)
    }

    @Test("loader clamps activeMemoryMaxSummaryChars to 40...1000")
    func loaderClampsSummaryChars() {
        #expect(
            MemoryConfigurationLoader.load(fromMemoryObject: ["activeMemoryMaxSummaryChars": 39])
                .activeMemoryMaxSummaryChars == 40
        )
        #expect(
            MemoryConfigurationLoader.load(fromMemoryObject: ["activeMemoryMaxSummaryChars": 220])
                .activeMemoryMaxSummaryChars == 220
        )
        #expect(
            MemoryConfigurationLoader.load(fromMemoryObject: ["activeMemoryMaxSummaryChars": 1001])
                .activeMemoryMaxSummaryChars == 1_000
        )
        #expect(
            MemoryConfigurationLoader.load(fromMemoryObject: [:])
                .activeMemoryMaxSummaryChars == 220
        )
    }

    @Test("truncatedNote leaves under-budget notes unchanged")
    func truncateUnderBudgetUnchanged() {
        let note = "User prefers Grafana dashboards."
        #expect(ActiveMemoryRecallOutput.truncatedNote(note, maxChars: 220) == note)
    }

    @Test("truncatedNote clips with ellipsis inside budget")
    func truncateOverBudgetAppendsEllipsis() {
        let note = String(repeating: "a", count: 50)
        let capped = ActiveMemoryRecallOutput.truncatedNote(note, maxChars: 20)
        #expect(capped.count == 20)
        #expect(capped.hasSuffix("…"))
        #expect(capped == String(repeating: "a", count: 19) + "…")
    }

    @Test("prompts mention configured character budget")
    func promptsMentionCharBudget() {
        let (system, user) = ActiveMemoryPreReplyPrompts.prompts(
            for: .situational,
            query: "latency",
            maxSummaryChars: 220
        )
        #expect(system.contains("220"))
        #expect(system.lowercased().contains("characters"))
        #expect(user.contains("220"))

        let standing = ActiveMemoryPreReplyPrompts.prompts(
            for: .standing,
            query: nil,
            maxSummaryChars: 180
        ).system
        #expect(standing.contains("180"))
    }
}
