import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite struct SessionProjectionConcurrencyTests {

    @Test("parallel catalog reads and projection refresh complete through session ports")
    func parallelCatalogReadsAndProjectionRefresh() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "session-projection-concurrency")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = Model(
            protocol: .ollama,
            modelName: "test:latest",
            serverURL: URL(string: "http://localhost:11434")!,
            capabilities: [],
            modelProtocol: .ollama
        )
        let (conversationID, _) = try await HarnessConversationTestFixtures.seedTwoDistinctRegistryConversations(
            host: fixture.host,
            model: model
        )
        let host = fixture.host
        let catalog = await host.conversationDomainServices.catalog
        let messaging = await host.conversationMessagingRuntimeService

        let readerCount = 8
        let writerCount = 4

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<readerCount {
                group.addTask {
                    for _ in 0..<20 {
                        _ = await catalog.getConversation(id: conversationID)
                        _ = try? await catalog.listMessagesThrowing(conversationID: conversationID)
                    }
                }
            }
            for writer in 0..<writerCount {
                group.addTask {
                    for index in 0..<5 {
                        await host.testing_applyOrchestratorMessages([
                            Message(
                                id: UUID(),
                                role: .assistant,
                                content: "writer-\(writer)-\(index)",
                                timestamp: Date(),
                                toolCalls: []
                            ),
                        ])
                        await messaging.refreshProjectedConversationMessages(conversationID: conversationID)
                    }
                }
            }
            await group.waitForAll()
        }

        let conversation = await catalog.getConversation(id: conversationID)
        #expect(conversation != nil)
        #expect((conversation?.messages.isEmpty ?? true) == false)
    }

    @Test("applySnapshotIfNotStale drops stale frontier and publishes on content change")
    func applySnapshotFrontierGating() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "session-projection-apply")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = Model(
            protocol: .ollama,
            modelName: "test:latest",
            serverURL: URL(string: "http://localhost:11434")!,
            capabilities: [],
            modelProtocol: .ollama
        )
        let (conversationID, _) = try await HarnessConversationTestFixtures.seedTwoDistinctRegistryConversations(
            host: fixture.host,
            model: model
        )
        let host = fixture.host
        let port = fixture.services.sessionProjection
        try await host.selectConversation(conversationID: conversationID)

        let messages = [Message(id: UUID(), role: .user, content: "cached", timestamp: Date())]
        let hash = ConversationEventLogService.contentHash(for: messages)

        await host.testing_seedProjectionPublishState(
            conversationID: conversationID,
            frontierEventID: 100,
            contentHash: hash
        )

        let stale = await port.applySnapshotIfNotStale(
            conversationID: conversationID,
            messages: messages,
            frontierEventID: 50,
            contentHash: hash
        )
        guard case .droppedStale(let projected, let current) = stale else {
            Issue.record("expected stale drop")
            return
        }
        #expect(projected == 50)
        #expect(current == 100)

        let changed = [Message(id: UUID(), role: .user, content: "changed", timestamp: Date())]
        let changedHash = ConversationEventLogService.contentHash(for: changed)
        let applied = await port.applySnapshotIfNotStale(
            conversationID: conversationID,
            messages: changed,
            frontierEventID: 100,
            contentHash: changedHash
        )
        guard case .applied(let shouldPublish) = applied else {
            Issue.record("expected applied outcome")
            return
        }
        #expect(shouldPublish == true)
    }
}
