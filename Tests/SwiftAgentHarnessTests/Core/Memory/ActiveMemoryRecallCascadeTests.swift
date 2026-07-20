import Foundation
import Testing
@testable import SwiftAgentHarness

private actor RecallSpawnCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

@Suite("Active memory recall cascade")
struct ActiveMemoryRecallCascadeTests {
    @Test("blocking recall spawns at most one child even when child turn would recurse")
    func singleSpawnPerBlockingRecall() async {
        let counter = RecallSpawnCounter()
        let port = MemorySubAgentSpawnPort(
            spawnBlockingRecall: { _, _, _, _, _, _ in
                await counter.increment()
                let nestedPort = MemorySubAgentSpawnPort(
                    spawnBlockingRecall: { _, _, _, _, _, _ in
                        await counter.increment()
                        return "nested-should-not-run"
                    },
                    spawnBackgroundExtraction: { _ in },
                    spawnBlockingPreCompactionFlush: { _, _, _ in false }
                )
                let nestedRunner = SubAgentPoolActiveMemoryRunner(spawnPort: nestedPort, config: .default)
                let childSession = MemorySessionContext(
                    conversationID: UUID(),
                    cwd: "/tmp",
                    canonicalGitRoot: nil,
                    memoryDirectory: URL(fileURLWithPath: "/tmp/memory")
                )
                let childScope = ConversationScope(
                    selfID: childSession.conversationID,
                    parentID: UUID(),
                    rootID: UUID(),
                    lineageKind: .subAgent,
                    origin: .system,
                    depth: 1
                )
                let nested = await ConversationScope.withCurrent(childScope) {
                    await nestedRunner.blockingRecallSummary(
                        session: childSession,
                        userQuery: "nested query",
                        lane: .situational,
                        timeoutMs: 1000,
                        maxSummaryChars: 100,
                        excludedSelectionKeys: []
                    )
                }
                #expect(nested == nil)
                return MemoryContextFencer.fence("recalled")
            },
            spawnBackgroundExtraction: { _ in },
            spawnBlockingPreCompactionFlush: { _, _, _ in false }
        )
        let runner = SubAgentPoolActiveMemoryRunner(spawnPort: port, config: .default)
        let parentSession = MemorySessionContext(
            conversationID: UUID(),
            cwd: "/tmp",
            canonicalGitRoot: nil,
            memoryDirectory: URL(fileURLWithPath: "/tmp/memory")
        )
        let parentScope = ConversationScope(
            selfID: parentSession.conversationID,
            parentID: nil,
            rootID: parentSession.conversationID,
            lineageKind: .root,
            origin: .user
        )
        let summary = await ConversationScope.withCurrent(parentScope) {
            await runner.blockingRecallSummary(
                session: parentSession,
                userQuery: "parent query",
                lane: .situational,
                timeoutMs: 1000,
                maxSummaryChars: 100,
                excludedSelectionKeys: []
            )
        }
        #expect(await counter.count == 1)
        #expect(summary?.contains("recalled") == true)
    }
}
