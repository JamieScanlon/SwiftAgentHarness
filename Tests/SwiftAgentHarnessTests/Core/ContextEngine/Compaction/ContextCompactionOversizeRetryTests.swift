import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// Covers the static "drop oldest 20%" helper used inside the oversize-retry loop.
/// Live LLM behaviour (3-attempt retry, marker prefix on each shrink) is exercised through
/// integration paths; this suite focuses on the pure transform that drives the shrink, so the
/// behaviour is testable without spinning up an Ollama backend.
@Suite("ContextCompactionOversizeRetry — dropOldestGroups")
struct ContextCompactionOversizeRetryTests {

    private static let marker = ContextCompactionConfiguration.defaultOversizeRetryMarker

    private static func makeMessages(count: Int) -> [Message] {
        (0..<count).map { i in
            Message(
                id: UUID(),
                role: i.isMultiple(of: 2) ? .user : .assistant,
                content: "msg-\(i)",
                timestamp: Date(),
                toolCalls: []
            )
        }
    }

    @Test("Empty input returns empty (no marker) — caller short-circuits")
    func emptyInputReturnsEmpty() {
        let dropped = OllamaContextCompactionSummarizer.dropOldestGroups([], fraction: 0.2, marker: Self.marker)
        #expect(dropped.isEmpty)
    }

    @Test("Single-message input drops zero and prepends a marker")
    func singleMessageDropsNothing() {
        let messages = Self.makeMessages(count: 1)
        let dropped = OllamaContextCompactionSummarizer.dropOldestGroups(messages, fraction: 0.2, marker: Self.marker)
        #expect(dropped.count == 2)
        #expect(dropped.first?.content == Self.marker)
        #expect(dropped.last?.content == "msg-0")
    }

    @Test("5 messages with fraction 0.2 drops 1 and prepends marker once")
    func fivewithFractionPointTwoDropsOne() {
        let messages = Self.makeMessages(count: 5)
        let dropped = OllamaContextCompactionSummarizer.dropOldestGroups(messages, fraction: 0.2, marker: Self.marker)
        #expect(dropped.count == 5) // 5 - 1 dropped + 1 marker = 5.
        #expect(dropped.first?.content == Self.marker)
        // First retained message after the marker should be msg-1 (msg-0 dropped).
        #expect(dropped[1].content == "msg-1")
    }

    @Test("100 messages with fraction 0.2 drops 20 and prepends one marker")
    func hundredWithFractionPointTwoDrops20() {
        let messages = Self.makeMessages(count: 100)
        let dropped = OllamaContextCompactionSummarizer.dropOldestGroups(messages, fraction: 0.2, marker: Self.marker)
        #expect(dropped.count == 81) // 100 - 20 + 1 marker.
        #expect(dropped.first?.content == Self.marker)
        #expect(dropped[1].content == "msg-20")
    }

    @Test("Successive calls do not double-prefix the marker")
    func successiveCallsAreIdempotentOnMarker() {
        let messages = Self.makeMessages(count: 100)
        let first = OllamaContextCompactionSummarizer.dropOldestGroups(messages, fraction: 0.2, marker: Self.marker)
        // Feed the previously-shrunk middle (with marker) back in. On the next shrink the helper
        // strips the existing marker before computing the drop count, so the result still has a
        // single marker at index 0.
        let second = OllamaContextCompactionSummarizer.dropOldestGroups(first, fraction: 0.2, marker: Self.marker)
        let markerCount = second.filter { $0.content == Self.marker }.count
        #expect(markerCount == 1)
        // Second pass: drop fraction is applied to the post-strip 80 messages → drop 16 → keep 64.
        // Plus one marker = 65.
        #expect(second.count == 65)
    }

    @Test("fraction 0 keeps all messages but still prepends the marker")
    func zeroFractionKeepsAllAndAddsMarker() {
        let messages = Self.makeMessages(count: 4)
        let dropped = OllamaContextCompactionSummarizer.dropOldestGroups(messages, fraction: 0, marker: Self.marker)
        #expect(dropped.count == 5)
        #expect(dropped.first?.content == Self.marker)
        #expect(dropped.last?.content == "msg-3")
    }

    @Test("fraction values outside [0, 0.95] are clamped")
    func fractionClamping() {
        let messages = Self.makeMessages(count: 100)
        // Negative fraction → clamped to 0 → keep everything (plus marker).
        let negative = OllamaContextCompactionSummarizer.dropOldestGroups(messages, fraction: -0.5, marker: Self.marker)
        #expect(negative.count == 101)
        // 5.0 → clamped to 0.95 → drop 95 → keep 5 + marker = 6.
        let huge = OllamaContextCompactionSummarizer.dropOldestGroups(messages, fraction: 5.0, marker: Self.marker)
        #expect(huge.count == 6)
        #expect(huge.first?.content == Self.marker)
    }

    @Test("Custom marker string is honoured")
    func customMarkerHonoured() {
        let messages = Self.makeMessages(count: 5)
        let custom = "[custom retry marker]"
        let dropped = OllamaContextCompactionSummarizer.dropOldestGroups(messages, fraction: 0.2, marker: custom)
        #expect(dropped.first?.content == custom)
    }
}
