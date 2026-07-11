import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("MemoryRecallInjectionPolicy")
struct MemoryRecallInjectionPolicyTests {
    private func hit(_ key: String, body: String) -> MemoryRecallHit {
        MemoryRecallHit(selectionKey: key, formattedBody: body)
    }

    @Test("budgetedHits returns empty for empty input")
    func emptyInput() {
        #expect(MemoryRecallInjectionPolicy.budgetedHits([]).isEmpty)
    }

    @Test("budgetedHits truncates each file to per-file byte cap")
    func perFileCap() {
        let large = String(repeating: "x", count: 8_000)
        let hits = MemoryRecallInjectionPolicy.budgetedHits([hit("a.md", body: large)])
        #expect(hits.count == 1)
        #expect(Data(hits[0].formattedBody.utf8).count <= MemoryRecallInjectionPolicy.perFileByteCap)
        #expect(hits[0].formattedBody.contains(MemoryRecallInjectionPolicy.truncationMarker))
    }

    @Test("budgetedHits drops lowest-relevance hits when total cap exceeded")
    func totalCapDropsLowestRelevance() {
        let body = String(repeating: "a", count: 3_500)
        let hits = [
            hit("high.md", body: body),
            hit("mid.md", body: body),
            hit("low.md", body: body),
            hit("lowest.md", body: body),
            hit("extra.md", body: body),
        ]
        let budgeted = MemoryRecallInjectionPolicy.budgetedHits(hits)
        #expect(budgeted.count == 4)
        #expect(budgeted.map(\.selectionKey) == ["high.md", "mid.md", "low.md", "lowest.md"])
        let totalBytes = budgeted.reduce(0) { $0 + Data($1.formattedBody.utf8).count }
        #expect(totalBytes <= MemoryRecallInjectionPolicy.totalByteCap)
    }

    @Test("budgetedHits respects max hit count")
    func maxHitCount() {
        let hits = (0..<8).map { hit("f\($0).md", body: "small") }
        #expect(MemoryRecallInjectionPolicy.budgetedHits(hits).count == MemoryRecallInjectionPolicy.maxHitCount)
    }

    @Test("insertLateRecall places recall before last user message")
    func latePlacement() {
        let sys = Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: [])
        let u1 = Message(id: UUID(), role: .user, content: "first", timestamp: Date(), toolCalls: [])
        let a1 = Message(id: UUID(), role: .assistant, content: "reply", timestamp: Date(), toolCalls: [])
        let u2 = Message(id: UUID(), role: .user, content: "latest", timestamp: Date(), toolCalls: [])
        let recall = HarnessInjectedMessageMetadata.systemMessage(
            id: UUID(),
            content: "\(HarnessInjectedMessagePrefixes.memoryRecall)\nrecalled"
        )
        let out = MemoryRecallInjectionPolicy.insertLateRecall(recall, into: [sys, u1, a1, u2])
        #expect(out.count == 5)
        #expect(out[3].content.contains(HarnessInjectedMessagePrefixes.memoryRecall))
        #expect(out[4].role == .user)
        #expect(out[4].content == "latest")
    }

    @Test("insertLateRecall appends when no user message exists")
    func latePlacementNoUser() {
        let sys = Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: [])
        let recall = HarnessInjectedMessageMetadata.systemMessage(id: UUID(), content: "recall")
        let out = MemoryRecallInjectionPolicy.insertLateRecall(recall, into: [sys])
        #expect(out.count == 2)
        #expect(out[1].content == "recall")
    }

    @Test("hitsFittingCompactionGuard sheds hits when recall would trigger compaction")
    func compactionGuardShedsHits() {
        var messages: [Message] = [
            Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
        ]
        let chunk = String(repeating: "z", count: 6_000)
        for idx in 0..<10 {
            messages.append(Message(id: UUID(), role: .user, content: "u\(idx)-\(chunk)", timestamp: Date(), toolCalls: []))
            messages.append(Message(id: UUID(), role: .assistant, content: "a\(idx)-\(chunk)", timestamp: Date(), toolCalls: []))
        }
        messages.append(Message(id: UUID(), role: .user, content: "latest query", timestamp: Date(), toolCalls: []))

        let config = ContextCompactionConfiguration.default
        let modelLimit = 20_000
        let lastPrompt = modelLimit - 500
        let bigBody = String(repeating: "m", count: 3_500)
        let hits = (0..<5).map { hit("topic\($0).md", body: bigBody) }
        let recallID = UUID()

        let fitting = MemoryRecallInjectionPolicy.hitsFittingCompactionGuard(
            hits: hits,
            baseMessages: messages,
            recallEntryID: recallID,
            modelLimit: modelLimit,
            lastPromptTokens: lastPrompt,
            config: config
        )
        #expect(fitting.count < hits.count)
        guard let recallMessage = MemoryRecallInjectionPolicy.makeRecallMessage(hits: fitting, entryID: recallID) else {
            return
        }
        #expect(
            MemoryRecallInjectionPolicy.fitsWithoutCompactionTrigger(
                baseMessages: messages,
                recallMessage: recallMessage,
                modelLimit: modelLimit,
                lastPromptTokens: lastPrompt,
                config: config
            )
        )
    }

    @Test("makeRecallMessage fences surviving hits")
    func recallMessageFencing() {
        let hits = [hit("a.md", body: "content")]
        let msg = MemoryRecallInjectionPolicy.makeRecallMessage(hits: hits, entryID: UUID())!
        #expect(msg.content.contains(HarnessInjectedMessagePrefixes.memoryRecall))
        #expect(msg.content.contains("<memory-context>"))
    }
}
