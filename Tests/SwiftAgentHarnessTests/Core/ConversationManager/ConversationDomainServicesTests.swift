import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Conversation domain services")
struct ConversationDomainServicesTests {
    private func makeContainer() throws -> ModelContainer {
                return try HarnessTestModelContainer.makeInMemory()
    }

    private func makeModel(name: String = "domain-service-model") -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: name,
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    @Test("catalog service returns projected conversation")
    func catalogServiceReadConversation() async throws {
        let manager = HarnessRuntimeSession(container: try makeContainer())
        let catalog = await manager.conversationDomainServices.catalog
        try await manager.createConversation(with: makeModel(), userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)

        let fetched = await catalog.getConversation(id: conversationID)
        #expect(fetched?.id == conversationID)
    }

    @Test("control-plane service updates metadata")
    func controlPlaneServiceUpdatesMetadata() async throws {
        let manager = HarnessRuntimeSession(container: try makeContainer())
        let catalog = await manager.conversationDomainServices.catalog
        let controlPlane = await manager.conversationDomainServices.controlPlane
        try await manager.createConversation(with: makeModel(), userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)

        try await controlPlane.updateConversationMetadata(
            conversationID: conversationID,
            topic: "Updated Topic",
            description: "Updated Description",
            metadata: nil,
            interactionMode: nil,
            modeProfileID: nil,
            interactionModeChangeInitiator: nil,
            interactionModeChangeReason: nil,
            skipControlPlaneRevisionBump: false
        )

        let updated = await catalog.getConversation(id: conversationID)
        #expect(updated?.topic == "Updated Topic")
        #expect(updated?.description == "Updated Description")
    }

    @Test("lifecycle service soft-delete removes API-visible conversation")
    func lifecycleServiceSoftDelete() async throws {
        let manager = HarnessRuntimeSession(container: try makeContainer())
        let catalog = await manager.conversationDomainServices.catalog
        let lifecycle = await manager.conversationDomainServices.lifecycle
        try await manager.createConversation(with: makeModel(), userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)

        try await lifecycle.deleteConversation(conversationID: conversationID, hard: false)
        let deleted = await catalog.getConversation(id: conversationID)
        #expect(deleted == nil)
    }

    @Test("runs-replay service list applies standard limit bounds")
    func runsReplayServiceListRuns() async throws {
        let manager = HarnessRuntimeSession(container: try makeContainer())
        let runsReplay = await manager.conversationDomainServices.runsReplay
        try await manager.createConversation(with: makeModel(), userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)

        let response = await runsReplay.listConversationRuns(
            conversationID: conversationID,
            filter: ConversationRunListFilter(limit: 500)
        )
        #expect(response.runs.isEmpty)
    }

    private func makeLocalHarnessSession(label: String) throws -> (
        manager: HarnessRuntimeSession,
        root: URL
    ) {
        let fixture = try HarnessConversationTestFixtures.makeLocalPersistenceStack(label: label)
        let manager = HarnessRuntimeSession(
            container: fixture.stack.modelContainer,
            harnessSessionPersistenceOverride: fixture.local
        )
        return (manager, fixture.root)
    }

    @Test("lifecycle branchConversation creates child conversation and selects it")
    func lifecycleBranchConversation() async throws {
        let fixture = try makeLocalHarnessSession(label: "domain-branch")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let catalog = await manager.conversationDomainServices.catalog
        let lifecycle = await manager.conversationDomainServices.lifecycle
        let model = makeModel()
        try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)
        let userMessage = Message(id: UUID(), role: .user, content: "branch me", timestamp: Date(), toolCalls: [])
        await manager.testing_applyOrchestratorMessages([userMessage])

        let childID = try await lifecycle.branchConversation(
            conversationID: conversationID,
            userMessageID: userMessage.id,
            selectionBehavior: .adoptChild
        )

        #expect(childID != conversationID)
        #expect(await manager.currentConversationID == childID)
        #expect(await catalog.getConversation(id: childID) != nil)
    }

    @Test("lifecycle persistSplitSelectingNewThread selects new thread")
    func lifecyclePersistSplitSelectingNewThread() async throws {
        let fixture = try makeLocalHarnessSession(label: "domain-split")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let catalog = await manager.conversationDomainServices.catalog
        let lifecycle = await manager.conversationDomainServices.lifecycle
        let model = makeModel()
        try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)
        let userMessage = Message(id: UUID(), role: .user, content: "split me", timestamp: Date(), toolCalls: [])
        await manager.testing_applyOrchestratorMessages([userMessage])

        let (newID, _) = try await lifecycle.persistSplitSelectingNewThread(
            sourceConversationID: conversationID,
            atUserMessageID: userMessage.id,
            adoptSelection: true
        )

        #expect(newID != conversationID)
        #expect(await manager.currentConversationID == newID)
        #expect(await catalog.getConversation(id: newID) != nil)
    }

    @Test("control-plane patchConversation applies routing tool policy")
    func controlPlaneRoutingToolPolicyPatch() async throws {
        let manager = HarnessRuntimeSession(container: try makeContainer())
        let catalog = await manager.conversationDomainServices.catalog
        let controlPlane = await manager.conversationDomainServices.controlPlane
        try await manager.createConversation(with: makeModel(), userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)
        let conversation = try #require(await catalog.getConversation(id: conversationID))

        try await controlPlane.patchConversation(
            conversationID: conversationID,
            patch: ConversationPatch(
                expectedRevision: conversation.controlPlaneRevision,
                routingToolPolicy: .denylist(tools: ["alpha"], skills: [])
            )
        )

        let updated = try #require(await catalog.getConversation(id: conversationID))
        guard case let .denylist(tools, skills) = updated.routingPrefs?.explicitToolPolicy else {
            Issue.record("Expected denylist routing policy")
            return
        }
        #expect(Set(tools) == Set(["alpha"]))
        #expect(skills.isEmpty)
    }

    @Test("archive lifecycle transition physically prunes superseded checkpoint rows")
    func archiveLifecycleTransitionPhysicallyPrunesSupersededCheckpoints() async throws {
        let fixture = try HarnessConversationTestFixtures.makeInMemoryHarnessRuntimeHost()
        let host = fixture.host
        let catalog = await host.conversationDomainServices.catalog
        let controlPlane = await host.conversationDomainServices.controlPlane
        let model = makeModel()
        try await host.createConversation(with: model, userSystemPrompt: "sys")
        let conversationID = try #require(await host.currentConversationID)
        let harness = fixture.stack.conversationManager.harnessSessionPersistence

        let coveredMessageID = UUID()
        let compacted = Message(id: UUID(), role: .assistant, content: "compact", timestamp: Date(), toolCalls: [])
        let config = ContextCompactionConfiguration(
            enabled: true,
            ollamaServerURL: URL(string: "http://localhost:11434")!,
            model: "m",
            fallbackContextLimitTokens: 131_072,
            charactersPerToken: 4,
            maxCompactedMiddleMessages: 15
        )
        try fixture.stack.persistContextCompactionCheckpoint(
            conversationID: conversationID,
            rawMiddleMessageIDs: [coveredMessageID],
            compactedMiddleMessages: [compacted],
            kind: .summarized,
            config: config
        )

        let before = try harness.readTranscriptEntries(conversationID: conversationID, request: .full)
        let checkpointBefore = before.filter {
            guard $0.type == .derivedJournal,
                  let env = try? SessionTranscriptJournalEnvelopeCodec.decode($0.payloadJSON)
            else { return false }
            return env.kind == ConversationEventKind.contextCompactionCheckpoint.rawValue
        }
        #expect(checkpointBefore.count >= 1)

        let conversation = try #require(await catalog.getConversation(id: conversationID))
        try await controlPlane.patchConversation(
            conversationID: conversationID,
            patch: ConversationPatch(expectedRevision: conversation.controlPlaneRevision, lifecycle: .archived)
        )

        let after = try harness.readTranscriptEntries(conversationID: conversationID, request: .full)
        let checkpointAfter = after.filter {
            guard $0.type == .derivedJournal,
                  let env = try? SessionTranscriptJournalEnvelopeCodec.decode($0.payloadJSON)
            else { return false }
            return env.kind == ConversationEventKind.contextCompactionCheckpoint.rawValue
        }
        #expect(checkpointAfter.isEmpty)

        let events = fixture.stack.conversationManager.loadConversationEventsWithFrontier(conversationID: conversationID).0
        #expect(events.contains { $0.kind == ConversationEventKind.checkpointInvalidated.rawValue })
    }

    @Test("global tool registry is a superset of plan-mode conversation effective tools")
    func globalToolsSupersetOfPlanConversationTools() async throws {
        let fixture = try HarnessConversationTestFixtures.makeInMemoryHarnessRuntimeHost()
        let host = fixture.host
        let policy = await host.conversationToolModePolicyRuntimeService
        let model = makeModel()
        try await host.createConversation(with: model, userSystemPrompt: "sys", interactionMode: .plan)
        let conversationID = try #require(await host.currentConversationID)

        let global = try await policy.listAvailableToolsForAPI()
        let scoped = try await policy.listAvailableToolsForAPI(conversationID: conversationID)
        let globalNames = Set(global.map(\.name))
        let scopedNames = Set(scoped.map(\.name))
        #expect(scopedNames.isSubset(of: globalNames))
        #expect(scopedNames.contains("finish"))
        #expect(globalNames.contains("finish"))
    }
}
