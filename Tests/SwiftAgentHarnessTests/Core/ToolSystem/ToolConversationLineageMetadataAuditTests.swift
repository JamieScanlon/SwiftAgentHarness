import EasyJSON
import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// Regression coverage for the DEF-126/133 lineage metadata shortcut audit:
/// model tools cannot set `subAgentRootConversationID`; REST/client patches cannot forge lineage roots.
@Suite("ToolConversationLineageMetadataAudit")
struct ToolConversationLineageMetadataAuditTests {
    @Test("lineage shortcut ignored for non-subAgent conversations even with forged metadata")
    func lineageShortcutRequiresSubAgentKind() {
        let forgedRoot = UUID()
        let conversation = ModelConversation(
            id: UUID(),
            model: HarnessConversationTestFixtures.makeTestModel(),
            messages: [],
            createdAt: Date(),
            updatedAt: Date(),
            metadata: .object([
                "subAgentRootConversationID": .string(forgedRoot.uuidString.lowercased()),
            ]),
            lineageKind: .root,
            origin: .user
        )
        let root = ToolConversationAccessPolicy.lineageRoot(for: conversation) { _ in nil }
        #expect(root == conversation.id)
        #expect(root != forgedRoot)
    }

    @Test("sub-agent lineage shortcut still honors harness-stamped root metadata")
    func subAgentLineageShortcutHonored() {
        let rootID = UUID()
        let subAgentID = UUID()
        let subAgent = ModelConversation(
            id: subAgentID,
            model: HarnessConversationTestFixtures.makeTestModel(),
            messages: [],
            createdAt: Date(),
            updatedAt: Date(),
            metadata: .object([
                "subAgentRootConversationID": .string(rootID.uuidString.lowercased()),
                "subAgentDepth": .integer(1),
            ]),
            parentConversationID: rootID,
            lineageKind: .subAgent,
            origin: .system
        )
        let resolved = ToolConversationAccessPolicy.lineageRoot(for: subAgent) { _ in nil }
        #expect(resolved == rootID)
    }

    @Test("REST-style metadata update cannot forge lineage root on root conversation")
    func restPatchCannotForgeLineageRoot() throws {
        let container = try HarnessTestModelContainer.makeInMemory()
        let manager = ConversationManager(container: container)
        HarnessConversationTestFixtures.attachSharedInMemoryHarness(to: manager, container: container)
        let model = HarnessConversationTestFixtures.makeTestModel()
        let owner = UUID()
        let attacker = try manager.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: "attacker",
            ownerAccountID: owner
        )
        let foreignRoot = try manager.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: "foreign",
            ownerAccountID: owner
        )

        let forged: JSON = .object([
            "subAgentRootConversationID": .string(foreignRoot.id.uuidString.lowercased()),
        ])
        _ = try manager.updateConversationMetadata(
            conversationID: attacker.id,
            topic: nil,
            description: nil,
            metadata: forged
        )
        let updated = try #require(manager.conversations.first { $0.id == attacker.id })
        guard case .object(let object) = updated.metadata else {
            Issue.record("Expected metadata object after patch")
            return
        }
        #expect(object["subAgentRootConversationID"] == nil)
    }

    @Test("forged root metadata on root conversation denies cross-lineage tool access")
    func forgedRootMetadataDeniedForToolAccess() async {
        let owner = UUID()
        let foreignRootID = UUID()
        let attackerID = UUID()
        let forgedMetadata: JSON = .object([
            "subAgentRootConversationID": .string(foreignRootID.uuidString.lowercased()),
        ])
        let foreignRoot = LineageAuditTestSupport.makeConversation(
            id: foreignRootID,
            ownerAccountID: owner
        )
        let attacker = LineageAuditTestSupport.makeConversation(
            id: attackerID,
            ownerAccountID: owner,
            metadata: forgedMetadata,
            lineageKind: .root
        )
        let catalog = LineageAuditStubCatalog(conversations: [
            foreignRootID: foreignRoot,
            attackerID: attacker,
        ])
        let service = LineageAuditTestSupport.makeService(catalog: catalog)
        let scope = attacker.conversationScope()

        let denied = await ConversationScope.withCurrent(scope) {
            await service.getConversation(id: foreignRootID)
        }
        #expect(denied == nil)
    }

    @Test("harness metadata write path preserves sub-agent root on spawn update")
    func harnessMetadataWritePreservesSubAgentRoot() throws {
        let container = try HarnessTestModelContainer.makeInMemory()
        let manager = ConversationManager(container: container)
        HarnessConversationTestFixtures.attachSharedInMemoryHarness(to: manager, container: container)
        let model = HarnessConversationTestFixtures.makeTestModel()
        let root = try manager.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: "root",
            ownerAccountID: UUID()
        )
        let child = try manager.createIsolatedSubAgent(
            parentConversationID: root.id,
            selectedModel: model,
            userSystemPrompt: "child sys",
            topic: "child",
            metadata: nil,
            interactionMode: .chat,
            modeProfileID: "subagent-minimal"
        )
        let harnessMetadata: JSON = .object([
            "subAgentRootConversationID": .string(root.id.uuidString.lowercased()),
            "subAgentDepth": .integer(1),
            "subAgentLifecycleID": .string("spawn-test"),
        ])
        _ = try manager.updateConversationMetadata(
            conversationID: child.id,
            topic: nil,
            description: nil,
            metadata: harnessMetadata,
            allowHarnessMetadataKeys: true
        )
        let updated = try #require(manager.conversations.first { $0.id == child.id })
        guard case .object(let object) = updated.metadata else {
            Issue.record("Expected harness metadata")
            return
        }
        #expect(object["subAgentRootConversationID"]?.literalValue as? String == root.id.uuidString.lowercased())
        #expect(object["subAgentDepth"]?.literalValue as? Int == 1)
    }
}

// MARK: - Stubs

private enum LineageAuditTestSupport {
    static func makeModel() -> Model {
        HarnessConversationTestFixtures.makeTestModel()
    }

    static func makeConversation(
        id: UUID = UUID(),
        ownerAccountID: UUID? = nil,
        metadata: JSON? = nil,
        lineageKind: ConversationLineageKind = .root
    ) -> ModelConversation {
        let now = Date()
        return ModelConversation(
            id: id,
            model: makeModel(),
            messages: [],
            createdAt: now,
            updatedAt: now,
            topic: "topic",
            description: nil,
            interactionMode: .chat,
            metadata: metadata,
            ownerAccountID: ownerAccountID,
            lineageKind: lineageKind,
            origin: .user
        )
    }

    static func makeService(catalog: LineageAuditStubCatalog) -> ConversationToolDataService {
        ConversationToolDataService(
            catalog: catalog,
            controlPlane: LineageAuditStubControlPlane(),
            agentRuntime: LineageAuditStubAgentRuntime(),
            selection: LineageAuditStubSelection()
        )
    }
}

private final class LineageAuditStubCatalog: ConversationCatalogServicing, @unchecked Sendable {
    var conversations: [UUID: ModelConversation]

    init(conversations: [UUID: ModelConversation]) {
        self.conversations = conversations
    }

    func listConversationInfo() async -> [ModelConversation] { Array(conversations.values) }

    func listConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] {
        conversations.values
            .filter {
                ConversationCatalogVisibility.matchesFilter(
                    lineage: $0.lineageKind,
                    origin: $0.origin,
                    filter: visibility
                )
            }
            .map { conv in
                ConversationMetadata(
                    id: conv.id.uuidString,
                    modelName: conv.modelName,
                    topic: conv.topic,
                    description: conv.description,
                    messageCount: conv.messages.count,
                    createdAt: ISO8601DateFormatter().string(from: conv.createdAt),
                    updatedAt: ISO8601DateFormatter().string(from: conv.updatedAt),
                    ownerAccountID: conv.ownerAccountID,
                    parentConversationID: conv.parentConversationID,
                    lineageKind: conv.lineageKind,
                    origin: conv.origin
                )
            }
    }

    func getConversation(id: UUID) async -> ModelConversation? { conversations[id] }
    func getConversationWithDerived(id: UUID) async -> ConversationReadWithDerivedResponse? { nil }
    func projectConversation(conversationID: UUID, request: ConversationProjectRequest) async throws -> ConversationProjectResponse {
        throw ConversationServiceError.conversationNotFound
    }
    func listConversations(query: ConversationListQuery) async -> PagedConversationsResponse {
        PagedConversationsResponse(items: [], totalCount: 0, nextOffset: nil)
    }
    func searchConversations(query: ConversationSearchRequest) async -> ConversationSearchResponse {
        ConversationSearchResponse(hits: [], totalHitCount: 0)
    }
    func listMessagesThrowing(conversationID: UUID) async throws -> [Message] { [] }
    func latestTranscriptSequence(conversationID: UUID) async -> Int? { nil }
    func readTranscriptEntries(conversationID: UUID, request: SessionTranscriptReadRequest) async throws -> [SessionTranscriptEntry] { [] }
    func conversationEventsBackfill(conversationID: UUID, since: Int?) async throws -> ConversationEventsBackfillResponse {
        throw ConversationServiceError.conversationNotFound
    }
    func registryOwnerAccountID() async -> UUID? { nil }
}

private final class LineageAuditStubSelection: ConversationSelectionAccessing, @unchecked Sendable {
    func currentConversationID() async -> UUID? { nil }
    func currentConversation() async -> ModelConversation? { nil }
    func projectedMessages(for conversation: ModelConversation) async -> [Message] { conversation.messages }
    func configurationApplyingTrustPolicy(_ configuration: HarnessRuntimeSession.Configuration) async -> HarnessRuntimeSession.Configuration {
        configuration
    }
    func transformedTurns(messages: [Message], interactionMode: InteractionMode, previousTurns: [ConversationTurn]) async -> [ConversationTurn] { [] }
    func setCurrentMessagesProjection(for conversation: ModelConversation) async {}
    func touchCurrentMessagesIfSelected(conversationID: UUID, conversation: ModelConversation) async {}
    func setCurrentMessagesIfSelected(conversationID: UUID, messages: [Message]) async {}
    func selectConversation(conversationID: UUID) async throws {}
    func reselectAfterDelete(deletedConversationID: UUID) async throws {}
    func wireMessageStream(continuation: AsyncStream<[Message]>.Continuation, initial: [Message]) async {}
    func cancelMessageStreamBridge() async {}
    func runtimeSessionLaneKey(conversationID: UUID) async -> String { conversationID.uuidString }
    func runtimeSessionError(
        for admissionError: RuntimeLaneAdmissionError,
        conversationID: UUID,
        fallbackRunID: UUID,
        activeRuntimeRunIDOverride: UUID?
    ) async -> ConversationServiceError { .conversationNotFound }
    func shouldMirrorSelectionToGlobalChatState() async -> Bool { true }
    func invokeTestingPreRunStateSendHook(for conversation: ModelConversation) async {}
    func persistResourceBudgetHintFromContextTokens(conversationID: UUID) async {}
}

private final class LineageAuditStubControlPlane: ConversationControlPlaneServicing, @unchecked Sendable {
    func patchConversation(conversationID: UUID, patch: ConversationPatch) async throws {}
    func applyConversationRESTPatch(conversationID: UUID, patch: ConversationPatch, resolvedModel: Model?) async throws -> UInt64 { 0 }
    func composeModelReferenceForRouting(conversationID: UUID?, interactionMode: InteractionMode?, clientReference: ModelReference) async -> ModelReference {
        clientReference
    }
    func generateFullSystemPrompt(conversationID: UUID?, userSystemPrompt: String?) async throws -> String { userSystemPrompt ?? "" }
    func createConversation(
        with selectedModel: Model,
        userSystemPrompt: String,
        topic: String?,
        description: String?,
        metadata: JSON?,
        interactionMode: InteractionMode,
        modeProfileID: String?,
        cwd: String?,
        lineageKind: ConversationLineageKind,
        origin: ConversationOrigin
    ) async throws -> UUID { UUID() }
    func updateConversationMetadata(
        conversationID: UUID,
        topic: String?,
        description: String?,
        metadata: JSON?,
        interactionMode: InteractionMode?,
        modeProfileID: String?,
        interactionModeChangeInitiator: String?,
        interactionModeChangeReason: String?,
        skipControlPlaneRevisionBump: Bool
    ) async throws {}
    func updateConversationModelAndUserPrompt(conversationID: UUID, model: Model?, userSystemPrompt: String?) async throws {}
    func updateConversationThinkingConfig(conversationID: UUID, thinkingConfig: ThinkingConfig?) async throws {}
    func flushPendingModeTransition(conversationID: UUID, runID: UUID, terminalCategory: ConversationRunTerminalCategory?) async {}
    func scheduleOrApplyToolModeTransition(
        conversationID: UUID,
        targetMode: InteractionMode,
        modeProfileID: String,
        reason: String
    ) async throws -> ModeTransitionApplyResult { .applied }
}

private struct LineageAuditStubAgentRuntime: AgentRuntimeStreamingServicing {
    func serviceRuntimeMessageStream(for conversationID: UUID?) async throws -> AsyncStream<[Message]> {
        AsyncStream { $0.finish() }
    }
    func serviceRuntimeSendMessageAndStreamResponse(
        _ text: String,
        images: [Message.Image],
        conversationID: UUID,
        configuration: AgentRuntimeTurnConfiguration
    ) async throws -> ChatStreamResponse {
        throw ConversationServiceError.conversationNotFound
    }
    func serviceRuntimeRevertToUserMessageAndStreamResponse(
        conversationID: UUID,
        messageID: UUID,
        configuration: AgentRuntimeTurnConfiguration
    ) async throws -> ChatStreamResponse {
        throw ConversationServiceError.conversationNotFound
    }
    func serviceRuntimeSplitConversationAtUserMessage(
        conversationID: UUID,
        messageID: UUID,
        configuration: AgentRuntimeTurnConfiguration
    ) async throws -> ChatStreamResponse {
        throw ConversationServiceError.conversationNotFound
    }
    func cancelMessageStreamForAPI() async {}
    func setOrchestrationStateOutOfBandPush(
        id: UUID,
        push: @escaping @Sendable (ConversationOrchestrationState) async -> Void
    ) async {}
    func clearOrchestrationStateOutOfBandPush(id: UUID) async {}
    func requestTurnLoopStop(conversationID: UUID) async {}
}
