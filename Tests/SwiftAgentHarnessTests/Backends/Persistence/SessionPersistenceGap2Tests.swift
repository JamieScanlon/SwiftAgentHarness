import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("Harness session persistence Gap 2 (filtered list + README create)")
struct SessionPersistenceGap2Tests {

    @Test func localSQLiteFilteredListRespectsSourceCwdSinceAndCursor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        var recA = SessionCatalogRecord(
            id: UUID(),
            topic: "a",
            description: nil,
            messageCount: 0,
            updatedAt: base.addingTimeInterval(30),
            createdAt: base,
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        recA.source = "cli"
        recA.cwd = "/tmp/gap2-a"
        recA.lifecycleStateRaw = ConversationLifecycleState.active.rawValue
        try local.bootstrapEmptyConversation(recA)

        var recB = SessionCatalogRecord(
            id: UUID(),
            topic: "b",
            description: nil,
            messageCount: 0,
            updatedAt: base.addingTimeInterval(20),
            createdAt: base,
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        recB.source = "cli"
        recB.cwd = "/tmp/gap2-other"
        recB.lifecycleStateRaw = ConversationLifecycleState.active.rawValue
        try local.bootstrapEmptyConversation(recB)

        var recC = SessionCatalogRecord(
            id: UUID(),
            topic: "c",
            description: nil,
            messageCount: 0,
            updatedAt: base.addingTimeInterval(10),
            createdAt: base,
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        recC.source = "api"
        recC.cwd = "/tmp/gap2-a"
        recC.lifecycleStateRaw = ConversationLifecycleState.active.rawValue
        try local.bootstrapEmptyConversation(recC)

        let filter = SessionConversationListFilter(
            agentId: nil,
            source: "cli",
            cwd: "/tmp/gap2-a",
            lifecycleState: ConversationLifecycleState.active.rawValue,
            since: base.addingTimeInterval(15)
        )

        let page1 = try local.listConversations(filter, limit: 1, cursor: nil)
        #expect(page1.records.count == 1)
        #expect(page1.records[0].id == recA.id)
        #expect(page1.nextCursor != nil)

        let page2 = try local.listConversations(filter, limit: 10, cursor: page1.nextCursor)
        #expect(page2.records.isEmpty)
        #expect(page2.nextCursor == nil)
    }

    @Test func createConversationAssignsIdAndFieldsInMemory() throws {
        let mem = InMemoryHarnessSessionPersistence()
        let params = SessionConversationCreationParams(
            agentId: SessionPersistenceLayout.defaultAgentId,
            source: "cli",
            trustClass: "user",
            parentConversationID: nil,
            forkAnchorMessageID: nil,
            cwd: "/tmp/create",
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
            title: "T",
            topic: "T",
            description: nil,
            userID: nil,
            lifecycleStateRaw: ConversationLifecycleState.active.rawValue,
            modelConfigJSON: nil,
            createdAt: Date()
        )
        let created = try mem.createConversation(params)
        let roundTrip = try mem.catalogConversation(id: created.id)
        #expect(roundTrip?.cwd == "/tmp/create")
        #expect(roundTrip?.source == "cli")
        #expect(roundTrip?.trustClass == "user")
        #expect(roundTrip?.lifecycleStateRaw == ConversationLifecycleState.active.rawValue)
    }

    @Test func createConversationRejectsEmptyRequiredSource() throws {
        let mem = InMemoryHarnessSessionPersistence()
        let params = SessionConversationCreationParams(
            agentId: SessionPersistenceLayout.defaultAgentId,
            source: "   ",
            trustClass: "user",
            parentConversationID: nil,
            forkAnchorMessageID: nil,
            cwd: "/tmp/create",
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
            title: "T",
            topic: "T",
            description: nil,
            userID: nil,
            lifecycleStateRaw: ConversationLifecycleState.active.rawValue,
            modelConfigJSON: nil,
            createdAt: Date()
        )
        #expect(throws: SessionPersistenceError.self) {
            _ = try mem.createConversation(params)
        }
    }

    @Test func createConversationDefaultsTrustClassWhenMissing() throws {
        let mem = InMemoryHarnessSessionPersistence()
        let params = SessionConversationCreationParams(
            agentId: SessionPersistenceLayout.defaultAgentId,
            source: "cli",
            trustClass: nil,
            parentConversationID: nil,
            forkAnchorMessageID: nil,
            cwd: "/tmp/create",
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
            title: "T",
            topic: "T",
            description: nil,
            userID: nil,
            lifecycleStateRaw: nil,
            modelConfigJSON: nil,
            createdAt: Date()
        )
        let created = try mem.createConversation(params)
        let roundTrip = try #require(try mem.catalogConversation(id: created.id))
        #expect(roundTrip.trustClass == "user")
        #expect(roundTrip.lifecycleStateRaw == ConversationLifecycleState.active.rawValue)
    }

    @Test func listConversationsInMemoryMatchesDimensions() throws {
        let mem = InMemoryHarnessSessionPersistence()
        let id1 = UUID()
        var r1 = SessionCatalogRecord(
            id: id1,
            topic: "x",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        r1.source = "z"
        try mem.bootstrapEmptyConversation(r1)

        let page = try mem.listConversations(
            SessionConversationListFilter(agentId: nil, source: "z", cwd: nil, lifecycleState: nil, since: nil),
            limit: 5,
            cursor: nil
        )
        #expect(page.records.count == 1)
        #expect(page.records[0].id == id1)
    }

    @Test func listConversationsAgentFilterMismatchReturnsEmptyOnBothBackends() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap2-agent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try LocalHarnessSessionPersistence(root: root)
        let mem = InMemoryHarnessSessionPersistence()
        let record = SessionCatalogRecord(
            id: UUID(),
            topic: "agent",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        try local.bootstrapEmptyConversation(record)
        try mem.bootstrapEmptyConversation(record)

        let filter = SessionConversationListFilter(agentId: "other-agent", source: nil, cwd: nil, lifecycleState: nil, since: nil)
        let localPage = try local.listConversations(filter, limit: 10, cursor: nil)
        let memPage = try mem.listConversations(filter, limit: 10, cursor: nil)
        #expect(localPage.records.isEmpty)
        #expect(memPage.records.isEmpty)
        #expect(localPage.nextCursor == nil)
        #expect(memPage.nextCursor == nil)
    }

    @Test func listConversationsMalformedCursorFallsBackToFirstPage() throws {
        let mem = InMemoryHarnessSessionPersistence()
        var first = SessionCatalogRecord(
            id: UUID(),
            topic: "first",
            description: nil,
            messageCount: 0,
            updatedAt: Date(timeIntervalSince1970: 2_000),
            createdAt: Date(timeIntervalSince1970: 2_000),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        first.source = "cli"
        var second = SessionCatalogRecord(
            id: UUID(),
            topic: "second",
            description: nil,
            messageCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_000),
            createdAt: Date(timeIntervalSince1970: 1_000),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        second.source = "cli"
        try mem.bootstrapEmptyConversation(first)
        try mem.bootstrapEmptyConversation(second)

        let filter = SessionConversationListFilter(agentId: nil, source: "cli", cwd: nil, lifecycleState: nil, since: nil)
        let page = try mem.listConversations(filter, limit: 1, cursor: "not|a|cursor")
        #expect(page.records.count == 1)
        #expect(page.records[0].id == first.id)
    }
}
