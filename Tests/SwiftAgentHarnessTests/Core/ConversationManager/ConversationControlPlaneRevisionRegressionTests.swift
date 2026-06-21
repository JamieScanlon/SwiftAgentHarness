import Foundation
import SwiftAgentKit
import SwiftData
import Testing
@testable import SwiftAgentHarness

@Suite("Conversation control plane revision regression", .serialized)
struct ConversationControlPlaneRevisionRegressionTests {

    @Test("replaceConversationInRegistry preserves newer controlPlaneRevision from registry")
    func replaceConversationPreservesNewerRevision() async throws {
        let fixture = try makeFixture(label: "revision-preserve")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let conversationID = try await seedConversation(fixture: fixture)
        try await fixture.domain.persistBudgetSnapshot(
            conversationID: conversationID,
            snapshot: ConversationBudgetSnapshot(contextBudgetRemainingTokens: 42_000)
        )

        guard var stale = await fixture.domain.modelConversation(id: conversationID) else {
            Issue.record("conversation missing after budget persist")
            return
        }
        let advancedRevision = stale.controlPlaneRevision
        stale.controlPlaneRevision = advancedRevision - 1
        stale.state = .generating
        await fixture.domain.replaceConversationInRegistry(stale)

        let inMemory = await fixture.domain.modelConversation(id: conversationID)
        let catalogRevision = try fixture.local.catalogConversation(id: conversationID)?.controlPlaneRevision
        #expect(inMemory?.controlPlaneRevision == advancedRevision)
        #expect(catalogRevision == Int(advancedRevision))
        #expect(inMemory?.state == .generating)
    }

    @Test("persistBudgetSnapshot succeeds after stale registry replace")
    func budgetSnapshotPersistSurvivesStaleRegistryReplace() async throws {
        let fixture = try makeFixture(label: "revision-budget-survives")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let conversationID = try await seedConversation(fixture: fixture)
        guard var stale = await fixture.domain.modelConversation(id: conversationID) else {
            Issue.record("conversation missing")
            return
        }

        try await fixture.domain.persistBudgetSnapshot(
            conversationID: conversationID,
            snapshot: ConversationBudgetSnapshot(contextBudgetRemainingTokens: 32_000)
        )

        guard let afterPersist = await fixture.domain.modelConversation(id: conversationID) else {
            Issue.record("conversation missing after persist")
            return
        }
        let advancedRevision = afterPersist.controlPlaneRevision
        #expect(advancedRevision == stale.controlPlaneRevision + 1)

        stale.state = .generating
        await fixture.domain.replaceConversationInRegistry(stale)

        try await fixture.domain.persistBudgetSnapshot(
            conversationID: conversationID,
            snapshot: ConversationBudgetSnapshot(contextBudgetRemainingTokens: 31_000)
        )

        let updated = await fixture.domain.modelConversation(id: conversationID)
        #expect(updated?.controlPlaneRevision == advancedRevision + 1)
        #expect(updated?.budgetSnapshot?.contextBudgetRemainingTokens == 31_000)
    }

    @Test("messaging update with stale snapshot still allows budget persist")
    func messagingUpdateWithStaleSnapshotStillPersistsBudget() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "revision-messaging-update")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let model = HarnessConversationTestFixtures.makeTestModel()
        let conversationID = try await HarnessConversationTestFixtures.seedRegistryConversation(
            host: fixture.host,
            model: model
        )
        let domain = await fixture.host.persistenceDomain

        guard var stale = await domain.modelConversation(id: conversationID) else {
            Issue.record("conversation missing")
            return
        }

        try await domain.persistBudgetSnapshot(
            conversationID: conversationID,
            snapshot: ConversationBudgetSnapshot(contextBudgetRemainingTokens: 28_000)
        )

        guard let afterPersist = await domain.modelConversation(id: conversationID) else {
            Issue.record("conversation missing after first budget persist")
            return
        }
        let advancedRevision = afterPersist.controlPlaneRevision

        stale.agenticPhase = .started
        stale.llmRequestPhase = .streaming
        await fixture.services.conversationMessagingRuntimeService.update(conversation: stale)

        try await domain.persistBudgetSnapshot(
            conversationID: conversationID,
            snapshot: ConversationBudgetSnapshot(contextBudgetRemainingTokens: 27_000)
        )

        let updated = await domain.modelConversation(id: conversationID)
        #expect(updated?.controlPlaneRevision == advancedRevision + 1)
        #expect(updated?.budgetSnapshot?.contextBudgetRemainingTokens == 27_000)
        #expect(updated?.agenticPhase == .started)
        #expect(updated?.llmRequestPhase == .streaming)
    }

    private struct LocalFixture {
        let domain: ConversationPersistenceDomain
        let local: LocalHarnessSessionPersistence
        let root: URL
    }

    private func makeFixture(label: String) throws -> LocalFixture {
        let (stack, local, root) = try HarnessConversationTestFixtures.makeLocalPersistenceStack(label: label)
        let domain = ConversationPersistenceDomain.makeForTesting(
            container: stack.modelContainer,
            logger: nil,
            harnessSessionPersistenceOverride: local
        )
        return LocalFixture(domain: domain, local: local, root: root)
    }

    private func seedConversation(fixture: LocalFixture) async throws -> UUID {
        let model = HarnessConversationTestFixtures.makeTestModel()
        let conversation = try await fixture.domain.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: "revision-test",
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        try await fixture.domain.resetConversationsFromCatalog(availableModels: [model])
        return conversation.id
    }
}
