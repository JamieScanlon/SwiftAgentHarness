import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Raw history mutation invariants")
struct RawHistoryMutationTests {
    private func makeHarnessStack(label: String) throws -> (
        stack: ConversationPersistenceStack,
        local: LocalHarnessSessionPersistence,
        root: URL
    ) {
        try HarnessConversationTestFixtures.makeLocalPersistenceStack(label: label)
    }

    private func makeModel() -> Model {
        HarnessConversationTestFixtures.makeTestModel(name: "rawhist:test")
    }

    @Test("Persisting a context compaction checkpoint does not change transcript message row count")
    func compactionCheckpointDoesNotDeleteRawRows() async throws {
        let fixture = try makeHarnessStack(label: "rawhist-compact")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let stack = fixture.stack
        let local = fixture.local
        let cm = stack.conversationManager
        let model = makeModel()
        var conv = try cm.createConversation(with: model, userSystemPrompt: "sys", topic: nil, description: nil, metadata: nil)
        let u1 = Message(id: UUID(), role: .user, content: "u1", timestamp: Date(), toolCalls: [])
        _ = try await stack.saveMessage(u1, for: conv.id, resourceManager: nil, logger: nil)
        conv = try #require(cm.modelConversation(id: conv.id))

        let countBefore = try HarnessConversationTestFixtures.messageShapedTranscriptCount(
            local: local,
            conversationID: conv.id
        )

        let cfg = ContextCompactionConfiguration(
            enabled: true,
            ollamaServerURL: URL(string: "http://localhost:11434")!,
            model: "m",
            fallbackContextLimitTokens: 131_072,
            charactersPerToken: 4,
            maxCompactedMiddleMessages: 15
        )
        let compactId = UUID()
        let compactMsg = Message(id: compactId, role: .assistant, content: "compact", timestamp: Date(), toolCalls: [])
        _ = try stack.persistContextCompactionCheckpoint(
            conversationID: conv.id,
            rawMiddleMessageIDs: [u1.id],
            compactedMiddleMessages: [compactMsg],
            coveredRawMiddle: [u1],
            kind: .summarized,
            config: cfg,
            expectedDerivedSequence: nil
        )

        let countAfter = try HarnessConversationTestFixtures.messageShapedTranscriptCount(
            local: local,
            conversationID: conv.id
        )
        #expect(countAfter == countBefore)
    }

    @Test("saveMessage accepts expectedPreviousTailHarnessMessageID when it matches active tail")
    func saveMessageTailCASMatch() async throws {
        let fixture = try makeHarnessStack(label: "rawhist-cas")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let stack = fixture.stack
        let cm = stack.conversationManager
        let model = makeModel()
        let conv = try cm.createConversation(with: model, userSystemPrompt: "sys", topic: nil, description: nil, metadata: nil)
        let u1 = Message(id: UUID(), role: .user, content: "u1", timestamp: Date(), toolCalls: [])
        _ = try await stack.saveMessage(u1, for: conv.id, resourceManager: nil, logger: nil)
        let u2 = Message(id: UUID(), role: .user, content: "u2", timestamp: Date(), toolCalls: [])
        _ = try await stack.saveMessage(
            u2,
            for: conv.id,
            resourceManager: nil,
            logger: nil,
            expectedPreviousTailHarnessMessageID: u1.id
        )
        let active = try ConversationTranscriptLineage.activeMessages(
            conversationID: conv.id,
            harness: cm.harnessSessionPersistence,
        )
        #expect(active.contains { $0.id == u1.id })
        #expect(active.contains { $0.id == u2.id })
    }

    @Test("saveMessage rejects stale expectedPreviousTailHarnessMessageID")
    func saveMessageTailCASConflict() async throws {
        let fixture = try makeHarnessStack(label: "rawhist-cas-conflict")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let stack = fixture.stack
        let cm = stack.conversationManager
        let model = makeModel()
        let conv = try cm.createConversation(with: model, userSystemPrompt: "sys", topic: nil, description: nil, metadata: nil)
        let u1 = Message(id: UUID(), role: .user, content: "u1", timestamp: Date(), toolCalls: [])
        _ = try await stack.saveMessage(u1, for: conv.id, resourceManager: nil, logger: nil)
        let u2 = Message(id: UUID(), role: .user, content: "u2", timestamp: Date(), toolCalls: [])
        await #expect(throws: ConversationServiceError.self) {
            try await stack.saveMessage(
                u2,
                for: conv.id,
                resourceManager: nil,
                logger: nil,
                expectedPreviousTailHarnessMessageID: UUID()
            )
        }
    }

    @Test("saveMessage preserves append order when timestamps are skewed")
    func saveMessageAppendOrderBeatsTimestampSkew() async throws {
        let fixture = try makeHarnessStack(label: "rawhist-order")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let stack = fixture.stack
        let cm = stack.conversationManager
        let model = makeModel()
        let conv = try stack.conversationManager.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: nil,
            description: nil,
            metadata: nil
        )

        let base = Date()
        let user = Message(
            id: UUID(),
            role: .user,
            content: "user-first",
            timestamp: base,
            toolCalls: []
        )
        let assistant = Message(
            id: UUID(),
            role: .assistant,
            content: "assistant-second-but-backdated",
            timestamp: base.addingTimeInterval(-30),
            toolCalls: []
        )

        _ = try await stack.saveMessage(user, for: conv.id, resourceManager: nil, logger: nil)
        _ = try await stack.saveMessage(assistant, for: conv.id, resourceManager: nil, logger: nil)

        let active = try ConversationTranscriptLineage.activeMessages(
            conversationID: conv.id,
            harness: cm.harnessSessionPersistence,
        )
        let roles = active.map(\.role)
        #expect(Array(roles.prefix(3)) == [.system, .user, .assistant])
    }

    @Test("Revert rewinds head_entry_id without tombstones or deleting JSONL rows")
    func revertPreservesPhysicalRows() async throws {
        let fixture = try makeHarnessStack(label: "rawhist-revert")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let stack = fixture.stack
        let cm = stack.conversationManager
        let harness = cm.harnessSessionPersistence
        let model = makeModel()
        let conv = try cm.createConversation(with: model, userSystemPrompt: "sys", topic: nil, description: nil, metadata: nil)
        let u1 = Message(id: UUID(), role: .user, content: "u1", timestamp: Date(), toolCalls: [])
        let a1 = Message(id: UUID(), role: .assistant, content: "a1", timestamp: Date(), toolCalls: [])
        let u2 = Message(id: UUID(), role: .user, content: "u2", timestamp: Date(), toolCalls: [])
        _ = try await stack.saveMessage(u1, for: conv.id, resourceManager: nil, logger: nil)
        _ = try await stack.saveMessage(a1, for: conv.id, resourceManager: nil, logger: nil)
        _ = try await stack.saveMessage(u2, for: conv.id, resourceManager: nil, logger: nil)

        let jsonlBefore = try harness.readTranscriptEntries(conversationID: conv.id, request: .full).count

        let prefix = try stack.revertConversationPreservingPrefixThroughUserMessage(
            conversationID: conv.id,
            userMessageID: u1.id
        )

        #expect(try harness.readTranscriptEntries(conversationID: conv.id, request: .full).count == jsonlBefore)

        let head = try #require(try harness.activeHeadEntryId(conversationID: conv.id))
        #expect(head == SessionEntryID.fromMessageUUID(u1.id))

        #expect(prefix.count == 2)
        #expect(prefix.contains(where: { $0.id == u1.id }))
        #expect(!prefix.contains(where: { $0.id == a1.id }))
        #expect(!prefix.contains(where: { $0.id == u2.id }))

        try HarnessConversationTestFixtures.resetRegistryFromCatalog(manager: cm, availableModels: [model])
        let reloaded = try #require(cm.modelConversation(id: conv.id))
        #expect(reloaded.messages.count == 2)

        let projectedBase = cm.transcriptBaseMessages(for: reloaded)
        #expect(projectedBase.count == 2)
        #expect(projectedBase.contains(where: { $0.id == u1.id }))
        #expect(!projectedBase.contains(where: { $0.id == a1.id }))
        #expect(!projectedBase.contains(where: { $0.id == u2.id }))

        let u3 = Message(id: UUID(), role: .user, content: "u3", timestamp: Date(), toolCalls: [])
        _ = try await stack.saveMessage(u3, for: conv.id, resourceManager: nil, logger: nil)
        let children = try harness.childTranscriptEntries(
            conversationID: conv.id,
            parentEntryId: SessionEntryID.fromMessageUUID(u1.id)
        )
        #expect(children.count >= 2)
    }
}
