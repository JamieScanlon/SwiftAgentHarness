import Foundation
import os
import Testing
@testable import SwiftAgentHarness

@Suite("TriggerSessionIndexDurable")
struct TriggerSessionIndexDurableTests {
    private func sampleTrigger() -> HarnessTrigger {
        HarnessTrigger(
            id: "t-durable",
            source: .channel,
            sourceMetadata: ["channel": "slack", "chatId": "U1"],
            payload: "",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty,
            routingMode: .isolated
        )
    }

    @Test("resolve-by-title hit reuses the durable conversation without creating")
    func resolveByTitleHit() async throws {
        let resolved = UUID()
        let created = OSAllocatedUnfairLock(initialState: 0)
        let index = TriggerSessionIndex(
            createConversation: { _ in
                created.withLock { $0 += 1 }
                return UUID()
            },
            resolveConversationByTitle: { _ in resolved }
        )
        let id = try await index.resolveOrCreateIsolated(sessionKey: "channel:slack:U1", trigger: sampleTrigger())
        #expect(id == resolved)
        #expect(created.withLock { $0 } == 0)
    }

    @Test("create-on-miss uses the session key as the conversation title")
    func createOnMissUsesKeyAsTitle() async throws {
        let capturedTitle = OSAllocatedUnfairLock<String?>(initialState: nil)
        let newID = UUID()
        let index = TriggerSessionIndex(
            createConversation: { title in
                capturedTitle.withLock { $0 = title }
                return newID
            },
            resolveConversationByTitle: { _ in nil }
        )
        let id = try await index.resolveOrCreateIsolated(sessionKey: "channel:slack:U1", trigger: sampleTrigger())
        #expect(id == newID)
        #expect(capturedTitle.withLock { $0 } == "channel:slack:U1")
    }

    @Test("in-memory cache prevents repeat resolution within a process")
    func inMemoryCache() async throws {
        let resolveCalls = OSAllocatedUnfairLock(initialState: 0)
        let stable = UUID()
        let index = TriggerSessionIndex(
            createConversation: { _ in UUID() },
            resolveConversationByTitle: { _ in
                resolveCalls.withLock { $0 += 1 }
                return stable
            }
        )
        let first = try await index.resolveOrCreateIsolated(sessionKey: "channel:slack:U1", trigger: sampleTrigger())
        let second = try await index.resolveOrCreateIsolated(sessionKey: "channel:slack:U1", trigger: sampleTrigger())
        #expect(first == second)
        #expect(resolveCalls.withLock { $0 } == 1)
    }

    @Test("lru eviction forces durable re-resolve")
    func lruEviction() async throws {
        let resolveCalls = OSAllocatedUnfairLock(initialState: 0)
        let stable = UUID()
        let index = TriggerSessionIndex(
            createConversation: { _ in UUID() },
            resolveConversationByTitle: { _ in
                resolveCalls.withLock { $0 += 1 }
                return stable
            },
            maxIsolatedSessionEntries: 2
        )
        _ = try await index.resolveOrCreateIsolated(sessionKey: "a", trigger: sampleTrigger())
        _ = try await index.resolveOrCreateIsolated(sessionKey: "b", trigger: sampleTrigger())
        _ = try await index.resolveOrCreateIsolated(sessionKey: "c", trigger: sampleTrigger())
        let beforeReResolve = resolveCalls.withLock { $0 }
        _ = try await index.resolveOrCreateIsolated(sessionKey: "a", trigger: sampleTrigger())
        #expect(resolveCalls.withLock { $0 } == beforeReResolve + 1)
    }

    @Test("reset clears in-memory cache")
    func resetClearsCache() async throws {
        let resolveCalls = OSAllocatedUnfairLock(initialState: 0)
        let stable = UUID()
        let index = TriggerSessionIndex(
            createConversation: { _ in UUID() },
            resolveConversationByTitle: { _ in
                resolveCalls.withLock { $0 += 1 }
                return stable
            },
            maxIsolatedSessionEntries: 8
        )
        _ = try await index.resolveOrCreateIsolated(sessionKey: "a", trigger: sampleTrigger())
        await index.reset()
        _ = try await index.resolveOrCreateIsolated(sessionKey: "a", trigger: sampleTrigger())
        #expect(resolveCalls.withLock { $0 } == 2)
    }
}
