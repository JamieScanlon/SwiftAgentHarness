import Foundation
import SwiftAgentHarness
import SwiftAgentKit
import Testing

@Suite("Conversation catalog visibility")
struct ConversationCatalogVisibilityTests {

    @Test("primary catalog includes user roots and branches only")
    func primaryCatalog() {
        #expect(ConversationCatalogVisibility.isPrimaryCatalog(lineage: .root, origin: .user))
        #expect(ConversationCatalogVisibility.isPrimaryCatalog(lineage: .branch, origin: .user))
        #expect(!ConversationCatalogVisibility.isPrimaryCatalog(lineage: .root, origin: .system))
        #expect(!ConversationCatalogVisibility.isPrimaryCatalog(lineage: .subAgent, origin: .system))
    }

    @Test("automations catalog includes system roots only")
    func automationsCatalog() {
        #expect(ConversationCatalogVisibility.isAutomationsCatalog(lineage: .root, origin: .system))
        #expect(!ConversationCatalogVisibility.isAutomationsCatalog(lineage: .branch, origin: .user))
        #expect(!ConversationCatalogVisibility.isAutomationsCatalog(lineage: .subAgent, origin: .system))
    }

    @Test("sub-agent lineage is hidden from catalog")
    func hiddenSubAgent() {
        #expect(ConversationCatalogVisibility.isHiddenFromCatalog(lineage: .subAgent))
        #expect(!ConversationCatalogVisibility.isHiddenFromCatalog(lineage: .root))
    }

    @Test("lineage inference classifies sub-agent metadata")
    func inferenceSubAgent() {
        let metadata = """
        {"subAgentDepth":1,"subAgentRootConversationID":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}
        """
        let inferred = ConversationLineageInference.infer(
            metadataJSON: metadata,
            interactionModeRaw: "agent",
            modeProfileID: nil,
            topic: "worker",
            parentConversationID: UUID(),
            forkAnchorEntryID: nil
        )
        #expect(inferred.lineage == .subAgent)
        #expect(inferred.origin == .system)
    }

    @Test("lineage inference classifies user branch")
    func inferenceBranch() {
        let inferred = ConversationLineageInference.infer(
            metadataJSON: nil,
            interactionModeRaw: "chat",
            modeProfileID: nil,
            topic: "fork",
            parentConversationID: UUID(),
            forkAnchorEntryID: "00000001"
        )
        #expect(inferred.lineage == .branch)
        #expect(inferred.origin == .user)
    }

    @Test("lineage inference classifies memory-extraction catalog rows as sub-agent")
    func inferenceMemoryExtraction() {
        let parentID = UUID()
        let byTopic = ConversationLineageInference.infer(
            metadataJSON: nil,
            interactionModeRaw: "agent",
            modeProfileID: "memory-extraction",
            topic: "memory-extraction",
            parentConversationID: parentID,
            forkAnchorEntryID: nil
        )
        #expect(byTopic.lineage == .subAgent)
        #expect(byTopic.origin == .system)

        let byProfileOnly = ConversationLineageInference.infer(
            metadataJSON: nil,
            interactionModeRaw: "agent",
            modeProfileID: "memory-extraction",
            topic: "worker",
            parentConversationID: parentID,
            forkAnchorEntryID: nil
        )
        #expect(byProfileOnly.lineage == .subAgent)
        #expect(byProfileOnly.origin == .system)
    }

    @Test("lineage inference classifies trigger-delegate rows as sub-agent not user branch")
    func inferenceTriggerDelegate() {
        let parentID = UUID()
        let byTopic = ConversationLineageInference.infer(
            metadataJSON: nil,
            interactionModeRaw: "agent",
            modeProfileID: "trigger-delegate",
            topic: "trigger-delegate",
            parentConversationID: parentID,
            forkAnchorEntryID: nil
        )
        #expect(byTopic.lineage == .subAgent)
        #expect(byTopic.origin == .system)

        let legacyTopicOnly = ConversationLineageInference.infer(
            metadataJSON: nil,
            interactionModeRaw: "agent",
            modeProfileID: nil,
            topic: "trigger-delegate",
            parentConversationID: parentID,
            forkAnchorEntryID: nil
        )
        #expect(legacyTopicOnly.lineage == .subAgent)
        #expect(legacyTopicOnly.origin == .system)
    }

    @Test("lineage inference classifies subagent-minimal machine spawn profile")
    func inferenceSubagentMinimalProfile() {
        let inferred = ConversationLineageInference.infer(
            metadataJSON: nil,
            interactionModeRaw: "agent",
            modeProfileID: "subagent-minimal",
            topic: "unspecified-role",
            parentConversationID: UUID(),
            forkAnchorEntryID: nil
        )
        #expect(inferred.lineage == .subAgent)
        #expect(inferred.origin == .system)
    }
}

@Suite("Conversation active memory policy")
struct ConversationActiveMemoryPolicyTests {
    private func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    @Test("primary root conversation allows blocking recall")
    func primaryRootAllowsRecall() {
        let conversation = ModelConversation(
            id: UUID(),
            model: makeModel(),
            systemPrompt: "sys",
            lineageKind: .root,
            origin: .user
        )
        #expect(ConversationActiveMemoryPolicy.shouldRunBlockingPreReplyRecall(for: conversation))
    }

    @Test("sub-agent lineage skips blocking recall")
    func subAgentLineageSkipsRecall() {
        let conversation = ModelConversation(
            id: UUID(),
            model: makeModel(),
            systemPrompt: "sys",
            topic: "memory-active-recall",
            modeProfileID: "memory-active-recall",
            parentConversationID: UUID(),
            lineageKind: .subAgent,
            origin: .system
        )
        #expect(!ConversationActiveMemoryPolicy.shouldRunBlockingPreReplyRecall(for: conversation))
    }

    @Test("memory-active-recall profile skips blocking recall")
    func memoryProfileSkipsRecall() {
        let conversation = ModelConversation(
            id: UUID(),
            model: makeModel(),
            systemPrompt: "sys",
            topic: "worker",
            modeProfileID: "memory-active-recall",
            parentConversationID: UUID(),
            lineageKind: .root,
            origin: .user
        )
        #expect(!ConversationActiveMemoryPolicy.shouldRunBlockingPreReplyRecall(for: conversation))
    }

    @Test("sub-agent scope skips blocking recall")
    func subAgentScopeSkipsRecall() {
        let scope = ConversationScope(
            selfID: UUID(),
            parentID: UUID(),
            rootID: UUID(),
            lineageKind: .subAgent,
            origin: .system,
            depth: 1
        )
        #expect(!ConversationActiveMemoryPolicy.shouldRunBlockingPreReplyRecall(scope: scope))
    }
}
