import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite struct ConversationTopicPublicationConcurrencyTests {

    @Test("parallel topic publication calls complete through ports")
    func parallelTopicPublicationCalls() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "topic-publication-concurrency")
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
        let topics = fixture.services.topics
        let invalidatedKinds = [HarnessCheckpointInvalidationKind.contextCompaction]
        let lifecyclePayload = RuntimeLifecycleEventPayload(
            name: .toolCallStarted,
            conversationID: conversationID,
            runID: UUID(),
            toolName: "filesystem_read",
            toolCallID: "tool-concurrency",
            source: "test.concurrency"
        )

        let taskCount = 12
        let iterationsPerTask = 10

        await withTaskGroup(of: Void.self) { group in
            for taskIndex in 0..<taskCount {
                group.addTask {
                    for iteration in 0..<iterationsPerTask {
                        switch taskIndex % 3 {
                        case 0:
                            await topics.publishCheckpointInvalidationOnTopic(
                                conversationID: conversationID,
                                invalidatedKinds: invalidatedKinds
                            )
                        case 1:
                            await topics.publishConversationTopicEventIfConfigured(
                                conversationID: conversationID,
                                payload: .streamDone
                            )
                        default:
                            await topics.publishRuntimeLifecycleWithFanout(lifecyclePayload)
                        }
                        _ = iteration
                    }
                }
            }
            await group.waitForAll()
        }
    }
}
