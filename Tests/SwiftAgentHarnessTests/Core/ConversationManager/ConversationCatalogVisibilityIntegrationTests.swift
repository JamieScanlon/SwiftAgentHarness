import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("Conversation catalog visibility integration")
struct ConversationCatalogVisibilityIntegrationTests {

    @Test("sub-agent conversations are excluded from primary metadata list")
    func subAgentHiddenFromMetadataList() throws {
        let fixture = try HarnessConversationTestFixtures.makeInMemoryHarnessRuntimeHost()
        let manager = fixture.stack.conversationManager
        let model = HarnessConversationTestFixtures.makeTestModel(name: "visibility-model")
        let parent = try manager.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: "parent"
        )
        let subAgent = try manager.createIsolatedSubAgent(
            parentConversationID: parent.id,
            selectedModel: model,
            userSystemPrompt: "worker",
            topic: "worker",
            description: nil,
            metadata: nil,
            interactionMode: .agent,
            modeProfileID: nil
        )
        #expect(subAgent.lineageKind == .subAgent)

        let visible = manager.listConversationMetadata(visibility: .primaryOnly)
        let ids = Set(visible.map(\.id))
        #expect(ids.contains(parent.id.uuidString))
        #expect(!ids.contains(subAgent.id.uuidString))

        let allIncludingHidden = manager.listConversationMetadata(visibility: .allIncludingHidden)
        #expect(allIncludingHidden.contains { $0.id == subAgent.id.uuidString })
    }

    @Test("trigger host conversations appear in automations catalog only")
    func triggerHostAutomationsCatalog() throws {
        let fixture = try HarnessConversationTestFixtures.makeInMemoryHarnessRuntimeHost()
        let manager = fixture.stack.conversationManager
        let model = HarnessConversationTestFixtures.makeTestModel(name: "trigger-host-model")
        let host = try manager.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: "cron:isolated:job-1",
            lineageKind: .root,
            origin: .system
        )
        let trigger = HarnessTrigger(
            id: "t-host",
            source: .cron,
            sourceMetadata: ["cronJobId": "job-1"],
            payload: "",
            initiator: TriggerInitiator(kind: .system),
            trust: .system,
            routingMode: .isolated
        )
        try manager.stampTriggerHostConversation(
            conversationID: host.id,
            trigger: trigger,
            sessionKey: "cron:isolated:job-1"
        )

        let primary = manager.listConversationMetadata(visibility: .primaryOnly)
        #expect(!primary.contains { $0.id == host.id.uuidString })

        let automations = manager.listConversationMetadata(visibility: .automationsOnly)
        #expect(automations.contains { $0.id == host.id.uuidString })
        #expect(automations.first { $0.id == host.id.uuidString }?.catalogSection == .automations)
    }

    @Test("trigger host born with system lineage is not visible in primary catalog before stamp")
    func triggerHostBornSystemRootBeforeStamp() throws {
        let fixture = try HarnessConversationTestFixtures.makeInMemoryHarnessRuntimeHost()
        let manager = fixture.stack.conversationManager
        let model = HarnessConversationTestFixtures.makeTestModel(name: "trigger-born-model")
        let host = try manager.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: "cron:isolated:job-born",
            metadata: TriggerHostConversationMetadata.minimalHostMetadata(sessionKey: "cron:isolated:job-born"),
            modeProfileID: "trigger-host",
            lineageKind: .root,
            origin: .system
        )

        let primary = manager.listConversationMetadata(visibility: .primaryOnly)
        #expect(!primary.contains { $0.id == host.id.uuidString })

        let automations = manager.listConversationMetadata(visibility: .automationsOnly)
        #expect(automations.contains { $0.id == host.id.uuidString })
    }

    @Test("repeat trigger host stamp is a no-op when host is fully configured")
    func repeatTriggerHostStampSkipsRedundantPatch() throws {
        let fixture = try HarnessConversationTestFixtures.makeInMemoryHarnessRuntimeHost()
        let manager = fixture.stack.conversationManager
        let model = HarnessConversationTestFixtures.makeTestModel(name: "trigger-restamp-model")
        let host = try manager.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: "cron:delegated:job-restamp",
            lineageKind: .root,
            origin: .system
        )
        let trigger = HarnessTrigger(
            id: "t-restamp",
            source: .cron,
            sourceMetadata: ["cronJobId": "job-restamp"],
            payload: "",
            initiator: TriggerInitiator(kind: .system),
            trust: .system,
            routingMode: .delegated
        )
        let sessionKey = "cron:delegated:job-restamp"
        try manager.stampTriggerHostConversation(
            conversationID: host.id,
            trigger: trigger,
            sessionKey: sessionKey
        )
        let revisionAfterFirstStamp = try #require(manager.modelConversation(id: host.id)?.controlPlaneRevision)

        try manager.stampTriggerHostConversation(
            conversationID: host.id,
            trigger: trigger,
            sessionKey: sessionKey
        )
        let revisionAfterSecondStamp = try #require(manager.modelConversation(id: host.id)?.controlPlaneRevision)
        #expect(revisionAfterSecondStamp == revisionAfterFirstStamp)
    }

    @Test("sub-agent scope hides switch_conversation from available tools")
    func subAgentHidesSwitchConversationTool() async {
        let provider = StubConversationsDataProvider()
        let toolProvider = ConversationsToolProvider(dataProvider: provider)
        let childID = UUID()
        let scope = ConversationScope(
            selfID: childID,
            parentID: UUID(),
            rootID: UUID(),
            lineageKind: .subAgent,
            origin: .system,
            depth: 1
        )
        let tools = await ConversationScope.withCurrent(scope) {
            await toolProvider.availableTools()
        }
        let names = Set(tools.map(\.name))
        #expect(names.contains(ConversationsToolProvider.listConversationsToolName))
        #expect(names.contains(ConversationsToolProvider.getConversationToolName))
        #expect(!names.contains(ConversationsToolProvider.switchConversationToolName))
    }

    @Test("nested ConversationScope resolves child ID over parent selection")
    func nestedScopePrefersInnerSelfID() async {
        let parentID = UUID()
        let childID = UUID()
        let rootID = parentID
        let parentScope = ConversationScope(
            selfID: parentID,
            parentID: nil,
            rootID: rootID,
            lineageKind: .root,
            origin: .user
        )
        let childScope = ConversationScope(
            selfID: childID,
            parentID: parentID,
            rootID: rootID,
            lineageKind: .subAgent,
            origin: .system,
            depth: 1
        )
        await ConversationScope.withCurrent(parentScope) {
            await ConversationScope.withCurrent(childScope) {
                #expect(ConversationScope.resolvedConversationID(fallback: parentID) == childID)
            }
            #expect(ConversationScope.resolvedConversationID(fallback: parentID) == parentID)
        }
    }
}

private final class StubConversationsDataProvider: ConversationsDataProviding, @unchecked Sendable {
    func listConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] { [] }
    func getConversation(id: UUID) async -> ModelConversation? { nil }
    func switchConversation(id: UUID, message: String?) async throws -> String? { nil }
}
