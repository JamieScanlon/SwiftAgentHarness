import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite struct RegistryTranscriptMergeTests {

    private func message(
        id: UUID = UUID(),
        role: MessageRole = .user,
        content: String,
        timestamp: Date
    ) -> Message {
        Message(id: id, role: role, content: content, timestamp: timestamp)
    }

    @Test("stale shorter incoming preserves existing tail")
    func staleShorterIncomingPreservesExistingTail() {
        let base = Date(timeIntervalSince1970: 1_000)
        let a = message(content: "A", timestamp: base)
        let b = message(content: "B", timestamp: base.addingTimeInterval(1))
        let c = message(content: "C", timestamp: base.addingTimeInterval(2))

        let merged = RegistryTranscriptMerge.union(existing: [a, b, c], incoming: [a, b])
        #expect(merged.map(\.id) == [a.id, b.id, c.id])
    }

    @Test("equal-count divergent tails keep both messages")
    func equalCountDivergentTailsKeepBoth() {
        let base = Date(timeIntervalSince1970: 1_000)
        let a = message(content: "A", timestamp: base)
        let b = message(content: "B", timestamp: base.addingTimeInterval(1))
        let c = message(content: "C", timestamp: base.addingTimeInterval(2))
        let d = message(content: "D", timestamp: base.addingTimeInterval(3))

        let merged = RegistryTranscriptMerge.union(existing: [a, b, c], incoming: [a, b, d])
        #expect(merged.map(\.id) == [a.id, b.id, c.id, d.id])
    }

    @Test("existing longer plus incoming-only message keeps both")
    func existingLongerPlusIncomingOnlyKeepsBoth() {
        let base = Date(timeIntervalSince1970: 1_000)
        let a = message(content: "A", timestamp: base)
        let b = message(content: "B", timestamp: base.addingTimeInterval(1))
        let c = message(content: "C", timestamp: base.addingTimeInterval(2))
        let d = message(content: "D", timestamp: base.addingTimeInterval(3))
        let x = message(content: "X", timestamp: base.addingTimeInterval(4))

        let merged = RegistryTranscriptMerge.union(existing: [a, b, c, d], incoming: [a, b, x])
        #expect(merged.map(\.id) == [a.id, b.id, c.id, d.id, x.id])
    }

    @Test("same-ID incoming overrides existing content")
    func sameIDIncomingOverridesExistingContent() {
        let base = Date(timeIntervalSince1970: 1_000)
        let id = UUID()
        let oldC = message(id: id, content: "old", timestamp: base.addingTimeInterval(2))
        let newC = message(id: id, content: "new", timestamp: base.addingTimeInterval(2))
        let a = message(content: "A", timestamp: base)
        let b = message(content: "B", timestamp: base.addingTimeInterval(1))

        let merged = RegistryTranscriptMerge.union(existing: [a, b, oldC], incoming: [a, b, newC])
        #expect(merged.map(\.id) == [a.id, b.id, id])
        #expect(merged.last?.content == "new")
    }

    @Test("strict extension uses incoming end state")
    func strictExtensionUsesIncomingEndState() {
        let base = Date(timeIntervalSince1970: 1_000)
        let a = message(content: "A", timestamp: base)
        let b = message(content: "B", timestamp: base.addingTimeInterval(1))
        let c = message(content: "C", timestamp: base.addingTimeInterval(2))
        let d = message(content: "D", timestamp: base.addingTimeInterval(3))
        let e = message(content: "E", timestamp: base.addingTimeInterval(4))

        let merged = RegistryTranscriptMerge.union(existing: [a, b, c], incoming: [a, b, c, d, e])
        #expect(merged.map(\.id) == [a.id, b.id, c.id, d.id, e.id])
    }

    @Test("incoming-only extras sort by timestamp with stable tie-break")
    func incomingOnlyExtrasSortByTimestamp() {
        let base = Date(timeIntervalSince1970: 1_000)
        let a = message(content: "A", timestamp: base)
        let b = message(content: "B", timestamp: base.addingTimeInterval(1))
        let earlier = message(content: "earlier", timestamp: base.addingTimeInterval(2))
        let later = message(content: "later", timestamp: base.addingTimeInterval(3))
        let sameTimeFirst = message(content: "first", timestamp: base.addingTimeInterval(4))
        let sameTimeSecond = message(content: "second", timestamp: base.addingTimeInterval(4))

        let merged = RegistryTranscriptMerge.union(
            existing: [a, b],
            incoming: [a, b, later, earlier, sameTimeSecond, sameTimeFirst]
        )
        #expect(merged.map(\.id) == [a.id, b.id, earlier.id, later.id, sameTimeSecond.id, sameTimeFirst.id])
    }

    @Test("empty existing returns incoming")
    func emptyExistingReturnsIncoming() {
        let msg = message(content: "only", timestamp: Date())
        #expect(RegistryTranscriptMerge.union(existing: [], incoming: [msg]).map(\.id) == [msg.id])
    }

    @Test("empty incoming returns existing")
    func emptyIncomingReturnsExisting() {
        let msg = message(content: "only", timestamp: Date())
        #expect(RegistryTranscriptMerge.union(existing: [msg], incoming: []).map(\.id) == [msg.id])
    }
}
