import Foundation
@testable import SwiftAgentHarness
import Testing

@Suite("SubAgentModeProfileConversationPruner")
struct SubAgentModeProfileConversationPrunerTests {
    private func makePersistence(label: String) throws -> LocalHarnessSessionPersistence {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sha-prune-\(label)-\(UUID().uuidString)", isDirectory: true)
        try SessionPersistenceLayout.ensureDirectory(root)
        return try LocalHarnessSessionPersistence(root: root, agentId: SessionPersistenceLayout.defaultAgentId)
    }

    private func baseParams(parent: UUID?, lineage: ConversationLineageKind, modeProfileID: String?) -> SessionConversationCreationParams {
        SessionConversationCreationParams(
            agentId: SessionPersistenceLayout.defaultAgentId,
            source: "test",
            trustClass: "user",
            parentConversationID: parent,
            forkAnchorMessageID: nil,
            cwd: nil,
            modelName: "test-model",
            interactionModeRaw: InteractionMode.agent.rawValue,
            modeProfileID: modeProfileID,
            title: nil,
            topic: nil,
            description: nil,
            userID: nil,
            lifecycleStateRaw: ConversationLifecycleState.active.rawValue,
            modelConfigJSON: nil,
            createdAt: Date(),
            lineageKind: lineage,
            origin: .user
        )
    }

    @Test("listCandidates includes only matching sub-agent rows", arguments: ["memory-extraction", "memory-active-recall"])
    func listCandidatesFiltersCorrectly(modeProfileID: String) throws {
        let persistence = try makePersistence(label: modeProfileID)
        let root = try persistence.createConversation(baseParams(parent: nil, lineage: .root, modeProfileID: "agent"))
        _ = try persistence.createConversation(baseParams(parent: root.id, lineage: .subAgent, modeProfileID: modeProfileID))
        let otherProfile = modeProfileID == "memory-extraction" ? "memory-active-recall" : "memory-extraction"
        _ = try persistence.createConversation(baseParams(parent: root.id, lineage: .subAgent, modeProfileID: otherProfile))

        let candidates = try SubAgentModeProfileConversationPruner.listCandidates(
            using: persistence,
            modeProfileID: modeProfileID
        )
        #expect(candidates.count == 1)
    }

    @Test("prune execute removes only the requested mode profile", arguments: ["memory-extraction", "memory-active-recall"])
    func pruneExecuteDeletesOnlyTargets(modeProfileID: String) throws {
        let persistence = try makePersistence(label: "execute-\(modeProfileID)")
        let root = try persistence.createConversation(baseParams(parent: nil, lineage: .root, modeProfileID: "agent"))
        let target = try persistence.createConversation(baseParams(parent: root.id, lineage: .subAgent, modeProfileID: modeProfileID))
        let otherProfile = modeProfileID == "memory-extraction" ? "memory-active-recall" : "memory-extraction"
        let other = try persistence.createConversation(baseParams(parent: root.id, lineage: .subAgent, modeProfileID: otherProfile))

        let report = try SubAgentModeProfileConversationPruner.prune(
            using: persistence,
            modeProfileID: modeProfileID,
            execute: true
        )
        #expect(report.deletedCount == 1)

        let remaining = try persistence.listCatalogConversations().map(\.id)
        #expect(remaining.contains(root.id))
        #expect(remaining.contains(other.id))
        #expect(!remaining.contains(target.id))
        #expect(!FileManager.default.fileExists(atPath: persistence.transcriptFileURL(conversationID: target.id).path))
    }
}
