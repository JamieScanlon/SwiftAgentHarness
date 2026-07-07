import Foundation
import SwiftAgentHarness
import SwiftData
import Testing

@Suite("Conversation event schema", .serialized)
struct ConversationEventSchemaTests {
    @Test("Latest schema is anchors-only")
    func latestSchemaIsAnchorsOnly() throws {
        let schema = HarnessPersistenceSchema.latest
        let names = Set(schema.entities.map(\.name))
        #expect(names == ["CachedSchemaAnchor"])
        _ = try HarnessTestModelContainer.makeInMemory()
    }
}

@Suite("ConversationJournalStream taxonomy")
struct ConversationJournalStreamTests {
    @Test("message_appended maps to raw stream")
    func rawKind() {
        #expect(ConversationJournalStream(persistedEventKind: "message_appended") == .raw)
    }

    @Test("compaction_applied maps to derived stream")
    func derivedKind() {
        #expect(ConversationJournalStream(persistedEventKind: "compaction_applied") == .derived)
    }
}
