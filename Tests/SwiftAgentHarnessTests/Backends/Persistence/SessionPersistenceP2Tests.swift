import EasyJSON
import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import SwiftData
import Testing

@Suite("Harness session persistence P2 (latest seq, dedupe, tail poll)")
struct SessionPersistenceP2Tests {
    private func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "p2-test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    @Test func latestTranscriptSequenceAfterHarnessCreate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-p2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try makeContainer()
        let manager = ConversationManager(container: container, logger: nil)
        let local = try LocalHarnessSessionPersistence(root: root)
        manager.setHarnessSessionPersistenceOverride(local)
        let conversation = try manager.createConversation(
            with: makeModel(),
            userSystemPrompt: "p2",
            topic: "P2",
            description: nil as String?,
            metadata: nil as JSON?,
            interactionMode: .chat
        )

        #expect(try local.latestTranscriptSequence(conversationID: conversation.id) == conversation.messages.count)
    }

    @Test func dedupeSqliteRejectsDuplicateKeyUntilExpiry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-p2-dedupe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)

        let k = "idempotency-test-key"
        #expect(try local.dedupeCheckAndSet(key: k, ttlSeconds: 3600) == true)
        #expect(try local.dedupeCheckAndSet(key: k, ttlSeconds: 3600) == false)

        let store = try local.dedupeStore()
        #expect(try store.dedupeCheckAndSet(key: k, ttlSeconds: 3600, now: Date().addingTimeInterval(4000)) == true)
    }

    @Test func managerMetadataUpdateMirrorsToSessionBackendCatalog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-p2-update-mirror-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try makeContainer()
        let manager = ConversationManager(container: container, logger: nil)
        let local = try LocalHarnessSessionPersistence(root: root)
        manager.setHarnessSessionPersistenceOverride(local)

        let created = try manager.createConversation(
            with: makeModel(),
            userSystemPrompt: "sys",
            topic: "Before",
            description: "D0",
            metadata: nil as JSON?,
            interactionMode: .chat
        )
        let changed = try manager.updateConversationMetadata(
            conversationID: created.id,
            topic: "After",
            description: "D1",
            metadata: .object(["k": .string("v")]),
            interactionMode: .plan
        )
        #expect(changed == true)
        let row = try #require(try local.catalogConversation(id: created.id))
        #expect(row.topic == "After")
        #expect(row.title == "After")
        #expect(row.description == "D1")
        #expect(row.interactionModeRaw == InteractionMode.plan.rawValue)
            }

    @Test func tailPollObservesAppendAndRetentionExceeded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-p2-tail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let cid = UUID()
        var row = SessionCatalogRecord(
            id: cid,
            topic: "tail",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        row.modelName = makeModel().modelName
        try local.bootstrapEmptyConversation(row)

        #expect(try local.latestTranscriptSequence(conversationID: cid) == 0)

        let poll: Duration = .milliseconds(25)
        let seqReader = TranscriptLatestSequenceReader(local: local, conversationID: cid)
        let stream = TranscriptTailPolling.tailEvents(
            conversationID: cid,
            pollInterval: poll,
            sinceSequence: 0,
            retention: nil,
            latestSequence: { try seqReader.read() }
        )

        let seq = try local.nextTranscriptSequence(conversationID: cid)
        let entry = SessionTranscriptEntry(
            sequence: seq,
            entryId: .generate(),
            parentEntryId: nil,
            type: .message,
            timestamp: Date(),
            payloadJSON: "{}"
        )
        try local.appendTranscriptEntry(conversationID: cid, entry: entry)

        let bumped = try await awaitNextEventAfter(firstSeq: 0, stream: stream, timeout: .milliseconds(2000))
        #expect(bumped.latestSequence >= 1)

        let bad = TranscriptTailPolling.tailEvents(
            conversationID: cid,
            pollInterval: poll,
            sinceSequence: 0,
            retention: TranscriptTailRetentionPolicy(maxSequenceLag: 0),
            latestSequence: { try seqReader.read() }
        )
        await #expect(throws: SessionPersistenceError.self) {
            for try await _ in bad {}
        }
    }
}

private final class TranscriptLatestSequenceReader: Sendable {
    let local: LocalHarnessSessionPersistence
    let conversationID: UUID
    init(local: LocalHarnessSessionPersistence, conversationID: UUID) {
        self.local = local
        self.conversationID = conversationID
    }

    func read() throws -> Int {
        try local.latestTranscriptSequence(conversationID: conversationID)
    }
}

private extension SessionPersistenceP2Tests {
    func awaitNextEventAfter(firstSeq: Int, stream: AsyncThrowingStream<TranscriptTailEvent, Error>, timeout: Duration) async throws -> TranscriptTailEvent {
        try await withThrowingTaskGroup(of: TranscriptTailEvent?.self) { group in
            group.addTask {
                for try await e in stream where e.latestSequence > firstSeq {
                    return e
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            let v = try await group.next() ?? nil
            group.cancelAll()
            guard let e = v else {
                throw SessionPersistenceError.unsupportedOperation("tail next timeout")
            }
            return e
        }
    }
}
