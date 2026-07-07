import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private enum ConversationToolDataServiceTenancyTestSupport {
    static func makeModel() -> Model {
        Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "tenancy-test-model",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    static func makeConversation(
        id: UUID = UUID(),
        ownerAccountID: UUID? = nil,
        parentConversationID: UUID? = nil,
        metadata: JSON? = nil,
        lineageKind: ConversationLineageKind = .root,
        origin: ConversationOrigin = .user,
        interactionMode: InteractionMode = .chat
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
            interactionMode: interactionMode,
            metadata: metadata,
            parentConversationID: parentConversationID,
            ownerAccountID: ownerAccountID,
            lineageKind: lineageKind,
            origin: origin
        )
    }

    static func makeService(
        catalog: TenancyStubCatalog,
        selection: TenancyStubSelection = TenancyStubSelection(),
        controlPlane: TenancyStubControlPlane = TenancyStubControlPlane()
    ) -> ConversationToolDataService {
        ConversationToolDataService(
            catalog: catalog,
            controlPlane: controlPlane,
            agentRuntime: TenancyStubAgentRuntime(),
            selection: selection
        )
    }
}

@Suite("ConversationToolDataService tenancy")
struct ConversationToolDataServiceTenancyTests {
    @Test("list_conversations returns only same-owner same-lineage rows")
    func listFiltersByOwnerAndLineage() async {
        let ownerA = UUID()
        let ownerB = UUID()
        let rootA = ConversationToolDataServiceTenancyTestSupport.makeConversation(ownerAccountID: ownerA)
        let branchA = ConversationToolDataServiceTenancyTestSupport.makeConversation(
            ownerAccountID: ownerA,
            parentConversationID: rootA.id,
            lineageKind: .branch
        )
        let unrelatedA = ConversationToolDataServiceTenancyTestSupport.makeConversation(ownerAccountID: ownerA)
        let rootB = ConversationToolDataServiceTenancyTestSupport.makeConversation(ownerAccountID: ownerB)
        let catalog = TenancyStubCatalog(conversations: [
            rootA.id: rootA,
            branchA.id: branchA,
            unrelatedA.id: unrelatedA,
            rootB.id: rootB,
        ])
        let service = ConversationToolDataServiceTenancyTestSupport.makeService(catalog: catalog)
        let scope = rootA.conversationScope()

        let listed = await ConversationScope.withCurrent(scope) {
            await service.listConversationMetadata(visibility: .primaryOnly)
        }
        let ids = Set(listed.map(\.id))
        #expect(ids.contains(rootA.id.uuidString))
        #expect(ids.contains(branchA.id.uuidString))
        #expect(!ids.contains(unrelatedA.id.uuidString))
        #expect(!ids.contains(rootB.id.uuidString))
    }

    @Test("get_conversation denies cross-owner access")
    func getDeniesCrossOwner() async {
        let ownerA = UUID()
        let ownerB = UUID()
        let convA = ConversationToolDataServiceTenancyTestSupport.makeConversation(ownerAccountID: ownerA)
        let convB = ConversationToolDataServiceTenancyTestSupport.makeConversation(ownerAccountID: ownerB)
        let catalog = TenancyStubCatalog(conversations: [convA.id: convA, convB.id: convB])
        let service = ConversationToolDataServiceTenancyTestSupport.makeService(catalog: catalog)
        let scope = convA.conversationScope()

        let allowed = await ConversationScope.withCurrent(scope) {
            await service.getConversation(id: convA.id)
        }
        let denied = await ConversationScope.withCurrent(scope) {
            await service.getConversation(id: convB.id)
        }
        #expect(allowed?.id == convA.id)
        #expect(denied == nil)
    }

    @Test("get_conversation denies cross-lineage same-owner access")
    func getDeniesCrossLineage() async {
        let owner = UUID()
        let root = ConversationToolDataServiceTenancyTestSupport.makeConversation(ownerAccountID: owner)
        let otherRoot = ConversationToolDataServiceTenancyTestSupport.makeConversation(ownerAccountID: owner)
        let catalog = TenancyStubCatalog(conversations: [root.id: root, otherRoot.id: otherRoot])
        let service = ConversationToolDataServiceTenancyTestSupport.makeService(catalog: catalog)
        let scope = root.conversationScope()

        let denied = await ConversationScope.withCurrent(scope) {
            await service.getConversation(id: otherRoot.id)
        }
        #expect(denied == nil)
    }

    @Test("switch_conversation denies cross-owner target")
    func switchDeniesCrossOwner() async {
        let ownerA = UUID()
        let ownerB = UUID()
        let convA = ConversationToolDataServiceTenancyTestSupport.makeConversation(ownerAccountID: ownerA)
        let convB = ConversationToolDataServiceTenancyTestSupport.makeConversation(ownerAccountID: ownerB)
        let catalog = TenancyStubCatalog(conversations: [convA.id: convA, convB.id: convB])
        let selection = TenancyStubSelection()
        let service = ConversationToolDataServiceTenancyTestSupport.makeService(catalog: catalog, selection: selection)
        let scope = convA.conversationScope()

        do {
            try await ConversationScope.withCurrent(scope) {
                try await service.switchConversation(id: convB.id, message: nil)
            }
            Issue.record("Expected switchConversation to throw conversationNotFound")
        } catch ConversationServiceError.conversationNotFound {
            #expect(selection.selectedIDs.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("mode transition denies cross-owner target")
    func modeTransitionDeniesCrossOwner() async {
        let ownerA = UUID()
        let ownerB = UUID()
        let convA = ConversationToolDataServiceTenancyTestSupport.makeConversation(
            ownerAccountID: ownerA,
            interactionMode: .chat
        )
        let convB = ConversationToolDataServiceTenancyTestSupport.makeConversation(
            ownerAccountID: ownerB,
            interactionMode: .chat
        )
        let catalog = TenancyStubCatalog(conversations: [convA.id: convA, convB.id: convB])
        let controlPlane = TenancyStubControlPlane()
        let service = ConversationToolDataServiceTenancyTestSupport.makeService(
            catalog: catalog,
            controlPlane: controlPlane
        )
        let scope = convA.conversationScope()

        do {
            try await ConversationScope.withCurrent(scope) {
                _ = try await service.transitionConversationMode(
                    conversationID: convB.id,
                    targetMode: .plan,
                    initiatedBy: "tool",
                    reason: ModeTransitionToolProvider.enterPlanModeToolName
                )
            }
            Issue.record("Expected transitionConversationMode to throw conversationNotFound")
        } catch ConversationServiceError.conversationNotFound {
            #expect(controlPlane.transitions.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("AgentPlanToolProvider get_plan denied for cross-owner conversation")
    func planToolDeniesCrossOwner() async throws {
        let ownerA = UUID()
        let ownerB = UUID()
        let convA = ConversationToolDataServiceTenancyTestSupport.makeConversation(ownerAccountID: ownerA)
        let convB = ConversationToolDataServiceTenancyTestSupport.makeConversation(ownerAccountID: ownerB)
        let catalog = TenancyStubCatalog(conversations: [convA.id: convA, convB.id: convB])
        let service = ConversationToolDataServiceTenancyTestSupport.makeService(catalog: catalog)
        let provider = AgentPlanToolProvider(dataProvider: service)
        let scope = convA.conversationScope()

        let result = try await ConversationScope.withCurrent(scope) {
            try await provider.executeTool(
                ToolCall(
                    name: AgentPlanToolProvider.getPlanToolName,
                    arguments: .object(["conversation_id": .string(convB.id.uuidString)]),
                    id: "plan-1"
                )
            )
        }
        #expect(result.success == false)
        #expect(result.error?.contains("Conversation not found") == true)
    }

    @Test("nil owner scope preserves legacy passthrough")
    func nilOwnerScopePassthrough() async {
        let convA = ConversationToolDataServiceTenancyTestSupport.makeConversation(ownerAccountID: nil)
        let convB = ConversationToolDataServiceTenancyTestSupport.makeConversation(ownerAccountID: nil)
        let catalog = TenancyStubCatalog(conversations: [convA.id: convA, convB.id: convB])
        let service = ConversationToolDataServiceTenancyTestSupport.makeService(catalog: catalog)

        let listed = await service.listConversationMetadata(visibility: .primaryOnly)
        #expect(listed.count == 2)
        let fetched = await service.getConversation(id: convB.id)
        #expect(fetched?.id == convB.id)
    }

    @Test("sub-agent can access parent lineage tree conversations")
    func subAgentAccessesLineageTree() async {
        let owner = UUID()
        let rootID = UUID()
        let root = ConversationToolDataServiceTenancyTestSupport.makeConversation(id: rootID, ownerAccountID: owner)
        let subAgentID = UUID()
        let metadata: JSON = .object([
            "subAgentRootConversationID": .string(rootID.uuidString.lowercased()),
            "subAgentDepth": .integer(1),
        ])
        let subAgent = ConversationToolDataServiceTenancyTestSupport.makeConversation(
            id: subAgentID,
            ownerAccountID: owner,
            parentConversationID: rootID,
            metadata: metadata,
            lineageKind: .subAgent,
            origin: .system
        )
        let catalog = TenancyStubCatalog(conversations: [rootID: root, subAgentID: subAgent])
        let service = ConversationToolDataServiceTenancyTestSupport.makeService(catalog: catalog)
        let scope = subAgent.conversationScope()

        let fetched = await ConversationScope.withCurrent(scope) {
            await service.getConversation(id: rootID)
        }
        #expect(fetched?.id == rootID)
    }
}

// MARK: - Stubs

private final class TenancyStubCatalog: ConversationCatalogServicing, @unchecked Sendable {
    var conversations: [UUID: ModelConversation]

    init(conversations: [UUID: ModelConversation]) {
        self.conversations = conversations
    }

    func listConversationInfo() async -> [ModelConversation] {
        Array(conversations.values)
    }

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

    func getConversation(id: UUID) async -> ModelConversation? {
        conversations[id]
    }

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

private final class TenancyStubSelection: ConversationSelectionAccessing, @unchecked Sendable {
    var selectedIDs: [UUID] = []

    func currentConversationID() async -> UUID? { nil }
    func currentConversation() async -> ModelConversation? { nil }
    func projectedMessages(for conversation: ModelConversation) async -> [Message] { conversation.messages }
    func configurationApplyingTrustPolicy(_ configuration: HarnessRuntimeSession.Configuration) async -> HarnessRuntimeSession.Configuration {
        configuration
    }
    func transformedTurns(
        messages: [Message],
        interactionMode: InteractionMode,
        previousTurns: [ConversationTurn]
    ) async -> [ConversationTurn] { [] }
    func setCurrentMessagesProjection(for conversation: ModelConversation) async {}
    func touchCurrentMessagesIfSelected(conversationID: UUID, conversation: ModelConversation) async {}
    func setCurrentMessagesIfSelected(conversationID: UUID, messages: [Message]) async {}
    func selectConversation(conversationID: UUID) async throws {
        selectedIDs.append(conversationID)
    }
    func reselectAfterDelete(deletedConversationID: UUID) async throws {}
    func wireMessageStream(continuation: AsyncStream<[Message]>.Continuation, initial: [Message]) async {}
    func cancelMessageStreamBridge() async {}
    func runtimeSessionLaneKey(conversationID: UUID) async -> String { conversationID.uuidString }
    func runtimeSessionError(
        for admissionError: RuntimeLaneAdmissionError,
        conversationID: UUID,
        fallbackRunID: UUID,
        activeRuntimeRunIDOverride: UUID?
    ) async -> ConversationServiceError {
        .conversationNotFound
    }
    func shouldMirrorSelectionToGlobalChatState() async -> Bool { true }
    func invokeTestingPreRunStateSendHook(for conversation: ModelConversation) async {}
    func persistResourceBudgetHintFromContextTokens(conversationID: UUID) async {}
}

private final class TenancyStubControlPlane: ConversationControlPlaneServicing, @unchecked Sendable {
    struct Transition: Sendable {
        let conversationID: UUID
        let mode: InteractionMode
    }

    var transitions: [Transition] = []

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
    func flushPendingModeTransition(
        conversationID: UUID,
        runID: UUID,
        terminalCategory: ConversationRunTerminalCategory?
    ) async {}
    func scheduleOrApplyToolModeTransition(
        conversationID: UUID,
        targetMode: InteractionMode,
        modeProfileID: String,
        reason: String
    ) async throws -> ModeTransitionApplyResult {
        transitions.append(.init(conversationID: conversationID, mode: targetMode))
        return .applied
    }
}

private struct TenancyStubAgentRuntime: AgentRuntimeStreamingServicing {
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
