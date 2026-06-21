import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// Tail/cursor semantics over harness transcript hydration (replaces SwiftData ``loadCachedMessages`` for registry).
@Suite("Harness transcript cursor load")
struct HarnessTranscriptCursorLoadTests {

    private func sortedActiveMessages(_ messages: [Message]) -> [Message] {
        messages.sorted { lhs, rhs in
            let lhsFirst = lhs.role == .system
            let rhsFirst = rhs.role == .system
            if lhsFirst, !rhsFirst { return true }
            if !lhsFirst, rhsFirst { return false }
            return lhs.timestamp < rhs.timestamp
        }
    }

    private func cursorPage(
        messages: [Message],
        sinceHarnessMessageID: UUID?,
        limit: Int
    ) -> [Message] {
        guard limit > 0 else { return [] }
        let ordered = sortedActiveMessages(messages)
        let slice: ArraySlice<Message>
        if let since = sinceHarnessMessageID {
            if let idx = ordered.firstIndex(where: { $0.id == since }) {
                slice = ordered.dropFirst(idx + 1)
            } else {
                slice = ordered[...]
            }
        } else {
            slice = ordered[...]
        }
        return Array(slice.prefix(limit))
    }

    @Test("Nil cursor returns prefix by active sort order")
    func nilCursorPrefix() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "cursor-nil")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = HarnessConversationTestFixtures.makeTestModel()
        let id = try await HarnessConversationTestFixtures.seedRegistryConversation(
            host: fixture.host,
            model: model,
            extraMessages: [Message(id: UUID(), role: .user, content: "a", timestamp: Date(), toolCalls: [])]
        )
        let conv = try #require(await fixture.host.listConversationInfo().first(where: { $0.id == id }))
        let page = cursorPage(messages: conv.messages, sinceHarnessMessageID: nil, limit: 10)
        #expect(page.count == 2)
    }

    @Test("Exclusive cursor returns rows strictly after anchor harness id")
    func exclusiveTail() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "cursor-tail")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = HarnessConversationTestFixtures.makeTestModel()
        let u1 = Message(id: UUID(), role: .user, content: "a", timestamp: Date(), toolCalls: [])
        let u2 = Message(id: UUID(), role: .user, content: "b", timestamp: Date().addingTimeInterval(1), toolCalls: [])
        let id = try await HarnessConversationTestFixtures.seedRegistryConversation(
            host: fixture.host,
            model: model,
            extraMessages: [u1, u2]
        )
        let conv = try #require(await fixture.host.listConversationInfo().first(where: { $0.id == id }))
        let tail = cursorPage(messages: conv.messages, sinceHarnessMessageID: u1.id, limit: 10)
        #expect(tail.count == 1)
        #expect(tail[0].id == u2.id)
    }

    @Test("Unknown cursor falls back to head window (compat refetch)")
    func unknownCursorFallback() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "cursor-unknown")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = HarnessConversationTestFixtures.makeTestModel()
        let id = try await HarnessConversationTestFixtures.seedRegistryConversation(
            host: fixture.host,
            model: model,
            extraMessages: [Message(id: UUID(), role: .user, content: "a", timestamp: Date(), toolCalls: [])]
        )
        let conv = try #require(await fixture.host.listConversationInfo().first(where: { $0.id == id }))
        let page = cursorPage(messages: conv.messages, sinceHarnessMessageID: UUID(), limit: 10)
        #expect(page.count == 2)
    }

    @Test("Zero limit yields empty array")
    func zeroLimit() {
        #expect(cursorPage(messages: [Message(id: UUID(), role: .user, content: "x", timestamp: Date(), toolCalls: [])], sinceHarnessMessageID: nil, limit: 0).isEmpty)
    }
}
