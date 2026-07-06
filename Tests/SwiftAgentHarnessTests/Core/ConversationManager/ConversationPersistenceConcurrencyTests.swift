import Foundation
import SwiftAgentKit
import SwiftData
import Testing
@testable import SwiftAgentHarness

@Suite struct ConversationPersistenceConcurrencyTests {

    @Test("parallel registry reads and message appends stay consistent through persistence domain actor")
    func parallelRegistryAccessThroughActorDomain() async throws {
        let container = try HarnessConversationTestFixtures.makeInMemoryContainer()
        let harness = HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        let domain = ConversationPersistenceDomain.makeForTesting(container: container, logger: nil)
        let model = HarnessConversationTestFixtures.makeTestModel()
        let conv = try await domain.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        try await domain.resetConversationsFromCatalog(availableModels: [model])
        let conversationID = conv.id

        let writerCount = 8
        let readerCount = 8
        let messagesPerWriter = 4

        try await withThrowingTaskGroup(of: Void.self) { group in
            for writer in 0..<writerCount {
                group.addTask {
                    for index in 0..<messagesPerWriter {
                        let message = Message(
                            id: UUID(),
                            role: .user,
                            content: "writer-\(writer)-\(index)",
                            timestamp: Date().addingTimeInterval(Double(writer * 100 + index))
                        )
                        _ = try await domain.routingSaveMessage(
                            message,
                            for: conversationID,
                            resourceManager: nil,
                            logger: nil,
                            expectedPreviousTailHarnessMessageID: nil,
                            transcriptRunID: nil
                        )
                    }
                }
            }
            for _ in 0..<readerCount {
                group.addTask {
                    for _ in 0..<20 {
                        _ = await domain.listConversationInfo()
                        _ = await domain.modelConversation(id: conversationID)
                    }
                }
            }
            try await group.waitForAll()
        }

        let info = await domain.listConversationInfo()
        let ids = info.map(\.id)
        #expect(Set(ids).count == ids.count)

        let conversation = await domain.modelConversation(id: conversationID)
        let messageCount = conversation?.messages.count ?? 0
        #expect(messageCount >= writerCount * messagesPerWriter)

        let transcriptCount = try await domain.readTranscriptEntries(
            conversationID: conversationID,
            request: .full
        ).filter { $0.type == .message || $0.type == .system }.count
        #expect(transcriptCount >= 1 + writerCount * messagesPerWriter)
        _ = harness
    }

    @Test("replaceConversationInRegistry keeps longer in-memory transcript when snapshot is stale")
    func replaceConversationPreservesLongerTranscript() async throws {
        let container = try HarnessConversationTestFixtures.makeInMemoryContainer()
        let domain = ConversationPersistenceDomain.makeForTesting(container: container, logger: nil)
        let model = HarnessConversationTestFixtures.makeTestModel()
        let conv = try await domain.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        try await domain.resetConversationsFromCatalog(availableModels: [model])

        let assistant = Message(id: UUID(), role: .assistant, content: "final", timestamp: Date())
        _ = try await domain.routingSaveMessage(
            assistant,
            for: conv.id,
            resourceManager: nil,
            logger: nil,
            expectedPreviousTailHarnessMessageID: nil,
            transcriptRunID: nil
        )

        guard var stale = await domain.modelConversation(id: conv.id) else {
            Issue.record("conversation missing")
            return
        }
        stale.messages.removeLast()
        stale.state = .idle
        await domain.replaceConversationInRegistry(stale)

        let conversation = await domain.modelConversation(id: conv.id)
        #expect(conversation?.messages.contains(where: { $0.id == assistant.id }) == true)
        #expect(conversation?.state == .idle)
    }

    @Test("applyRegistryTranscriptTruncation shortens transcript when replaceConversationInRegistry would preserve longer list")
    func applyRegistryTranscriptTruncationBypassesMergeGuard() async throws {
        let container = try HarnessConversationTestFixtures.makeInMemoryContainer()
        let domain = ConversationPersistenceDomain.makeForTesting(container: container, logger: nil)
        let model = HarnessConversationTestFixtures.makeTestModel()
        let conv = try await domain.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        try await domain.resetConversationsFromCatalog(availableModels: [model])

        let assistant = Message(id: UUID(), role: .assistant, content: "final", timestamp: Date())
        _ = try await domain.routingSaveMessage(
            assistant,
            for: conv.id,
            resourceManager: nil,
            logger: nil,
            expectedPreviousTailHarnessMessageID: nil,
            transcriptRunID: nil
        )

        guard var truncated = await domain.modelConversation(id: conv.id) else {
            Issue.record("conversation missing")
            return
        }
        truncated.messages.removeLast()
        truncated.state = .idle
        await domain.applyRegistryTranscriptTruncation(truncated)

        let conversation = await domain.modelConversation(id: conv.id)
        #expect(conversation?.messages.contains(where: { $0.id == assistant.id }) == false)
        #expect(conversation?.state == .idle)
    }

    @Test("replaceConversationInRegistry unions equal-count divergent tails")
    func replaceConversationUnionsDivergentEqualCountTails() async throws {
        let container = try HarnessConversationTestFixtures.makeInMemoryContainer()
        let domain = ConversationPersistenceDomain.makeForTesting(container: container, logger: nil)
        let model = HarnessConversationTestFixtures.makeTestModel()
        let conv = try await domain.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        try await domain.resetConversationsFromCatalog(availableModels: [model])

        let user = Message(id: UUID(), role: .user, content: "hello", timestamp: Date())
        _ = try await domain.routingSaveMessage(
            user,
            for: conv.id,
            resourceManager: nil,
            logger: nil,
            expectedPreviousTailHarnessMessageID: nil,
            transcriptRunID: nil
        )

        guard let base = await domain.modelConversation(id: conv.id) else {
            Issue.record("conversation missing")
            return
        }
        let staleBase = base.messages

        let msgC = Message(id: UUID(), role: .assistant, content: "C", timestamp: Date().addingTimeInterval(1))
        var withC = base
        withC.messages = staleBase + [msgC]
        await domain.replaceConversationInRegistry(withC)

        let msgD = Message(id: UUID(), role: .assistant, content: "D", timestamp: Date().addingTimeInterval(2))
        var withD = base
        withD.messages = staleBase + [msgD]
        await domain.replaceConversationInRegistry(withD)

        let conversation = await domain.modelConversation(id: conv.id)
        #expect(conversation?.messages.contains(where: { $0.id == msgC.id }) == true)
        #expect(conversation?.messages.contains(where: { $0.id == msgD.id }) == true)
    }

    @Test("replaceConversationInRegistry keeps incoming-only message when existing is longer")
    func replaceConversationKeepsIncomingOnlyWhenExistingIsLonger() async throws {
        let container = try HarnessConversationTestFixtures.makeInMemoryContainer()
        let domain = ConversationPersistenceDomain.makeForTesting(container: container, logger: nil)
        let model = HarnessConversationTestFixtures.makeTestModel()
        let conv = try await domain.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        try await domain.resetConversationsFromCatalog(availableModels: [model])

        let user1 = Message(id: UUID(), role: .user, content: "one", timestamp: Date())
        let user2 = Message(id: UUID(), role: .user, content: "two", timestamp: Date().addingTimeInterval(1))
        let user3 = Message(id: UUID(), role: .user, content: "three", timestamp: Date().addingTimeInterval(2))
        for message in [user1, user2, user3] {
            _ = try await domain.routingSaveMessage(
                message,
                for: conv.id,
                resourceManager: nil,
                logger: nil,
                expectedPreviousTailHarnessMessageID: nil,
                transcriptRunID: nil
            )
        }

        guard let full = await domain.modelConversation(id: conv.id) else {
            Issue.record("conversation missing")
            return
        }
        #expect(full.messages.count >= 4)

        let stalePrefix = Array(full.messages.prefix(2))
        let newTail = Message(id: UUID(), role: .assistant, content: "new", timestamp: Date().addingTimeInterval(10))
        var staleWithNew = full
        staleWithNew.messages = stalePrefix + [newTail]
        await domain.replaceConversationInRegistry(staleWithNew)

        let conversation = await domain.modelConversation(id: conv.id)
        #expect(conversation?.messages.contains(where: { $0.id == newTail.id }) == true)
        #expect(conversation?.messages.contains(where: { $0.id == user3.id }) == true)
    }
}
