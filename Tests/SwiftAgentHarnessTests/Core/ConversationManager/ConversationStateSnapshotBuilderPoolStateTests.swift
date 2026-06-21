import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// Minimal ``APILayerConversationManaging`` stub with one in-memory conversation row, used to drive
/// the ``ConversationStateSnapshotBuilder`` directly without standing up SwiftData.
private final class SnapshotConversationStub: APILayerConversationManaging, Sendable {
    let conversation: ModelConversation
    init(conversation: ModelConversation) { self.conversation = conversation }
    func apiListConversationInfo() async -> [ModelConversation] { [conversation] }
    func apiListConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] { [] }
    func apiGetConversation(id: UUID) async -> ModelConversation? {
        conversation.id == id ? conversation : nil
    }
    func apiListCurrentMessages() async -> [Message] { [] }
    func apiListCurrentMessagesThrowing() async throws -> [Message] { [] }
    func apiGenerateFullSystemPrompt(withUserSystemPrompt userSystemPrompt: String?) async throws -> String {
        userSystemPrompt ?? ""
    }
    func apiSelectConversation(conversationID: UUID) async throws {}
    func apiCreateConversation(with selectedModel: Model, userSystemPrompt: String, topic: String?, description: String?, metadata: JSON?, interactionMode: InteractionMode) async throws {}
    func apiUpdateConversationMetadata(conversationID: UUID, topic: String?, description: String?, metadata: JSON?, interactionMode: InteractionMode?) async throws {}
    func apiUpdateConversationModelAndUserPrompt(conversationID: UUID, model: Model?, userSystemPrompt: String?) async throws {}
    func apiListAvailableTools() async throws -> [AvailableToolInfo] { [] }
    func apiListAvailableSkills() async throws -> [AvailableSkillInfo] { [] }
    func apiListSlashCommands() async throws -> [SlashCommandAutocompleteEntry] { [] }
    func apiUpdateConversationToolOverrides(conversationID: UUID, routingPolicyTools: [String]) async throws {}
    func apiUpdateConversationSkillOverrides(conversationID: UUID, routingPolicySkills: [String]) async throws {}
    func apiUpdateConversationThinkingConfig(conversationID: UUID, thinkingConfig: ThinkingConfig?) async throws {}
    func apiCopyConversation(from sourceConversationID: UUID, to model: Model, systemPrompt: String) async throws {}
    func apiDeleteConversation(conversationID: UUID, hard: Bool) async throws {
        let _ = hard
    }

    func apiListConversations(query: ConversationListQuery) async -> PagedConversationsResponse {
        let _ = query
        return PagedConversationsResponse(items: [], totalCount: 0, nextOffset: nil)
    }

    func apiSearchConversations(query: ConversationSearchRequest) async -> ConversationSearchResponse {
        let _ = query
        return ConversationSearchResponse(hits: [], totalHitCount: 0, warning: nil, nextOffset: nil)
    }

    func apiPatchConversation(conversationID: UUID, patch: ConversationPatch) async throws {
        let _ = (conversationID, patch)
    }

    func apiApplyConversationRESTPatch(conversationID: UUID, patch: ConversationPatch, resolvedModel: Model?) async throws -> UInt64 {
        let _ = (conversationID, patch, resolvedModel)
        return 0
    }

    func apiBranchConversation(conversationID: UUID, userMessageID: UUID) async throws -> UUID {
        let _ = (conversationID, userMessageID)
        return conversation.id
    }

    func apiSpawnSubAgent(parentConversationID: UUID, request: SubAgentSpawnRequest, modelOverride: Model?) async throws -> UUID {
        let _ = (parentConversationID, request, modelOverride)
        return UUID()
    }

    func apiInvalidateConversationCheckpoints(conversationID: UUID, kinds: [String]) async throws {
        let _ = (conversationID, kinds)
    }

    func apiGetLatestCheckpoint(conversationID: UUID, kind: String?) async -> LatestCheckpointResponse? {
        let _ = (conversationID, kind)
        return nil
    }

    func apiSnapshotOrchestrationState(conversationID: UUID) async -> ConversationOrchestrationState? {
        _ = conversationID
        return nil
    }
    func apiReadPlanMarkdown(conversationID: UUID) async throws -> String { "" }

    func apiLatestTranscriptSequence(conversationID: UUID) async -> Int? {
        _ = conversationID
        return 0
    }

    func apiReadTranscriptEntries(conversationID: UUID, request: SessionTranscriptReadRequest) async throws -> [SessionTranscriptEntry] {
        _ = conversationID
        _ = request
        return []
    }

    var currentConversationID: UUID? { get async { nil } }
}

@Suite("ConversationStateSnapshotBuilder pool state merge")
struct ConversationStateSnapshotBuilderPoolStateTests {
    private static func makeModel() -> Model {
        Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "test-model",
            serverURL: URL(string: "http://localhost:1")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    @Test("Snapshot omits poolModelState when no provider is supplied")
    func snapshotWithoutProvider() async throws {
        let model = Self.makeModel()
        let convo = ModelConversation(model: model)
        let stub = SnapshotConversationStub(conversation: convo)
        let payload = await ConversationStateSnapshotBuilder.build(
            conversationID: convo.id,
            conversation: stub,
            runtime: nil
        )
        #expect(payload.exists == true)
        #expect(payload.poolModelState == nil)
    }

    @Test("Snapshot includes poolModelState when provider returns one")
    func snapshotWithProvider() async throws {
        let model = Self.makeModel()
        let convo = ModelConversation(model: model)
        let stub = SnapshotConversationStub(conversation: convo)
        let pool = ModelStatePayload(
            phase: .streaming,
            thinking: true,
            callId: UUID(),
            updatedAt: Date(timeIntervalSince1970: 0),
            inFlightCount: 1
        )
        let payload = await ConversationStateSnapshotBuilder.build(
            conversationID: convo.id,
            conversation: stub,
            runtime: nil,
            poolStateProvider: { mid in
                #expect(mid == model.id)
                return pool
            }
        )
        #expect(payload.poolModelState == pool)
    }

    @Test("Snapshot omits poolModelState when provider returns nil (never-seen model)")
    func snapshotWithProviderReturningNil() async throws {
        let model = Self.makeModel()
        let convo = ModelConversation(model: model)
        let stub = SnapshotConversationStub(conversation: convo)
        let payload = await ConversationStateSnapshotBuilder.build(
            conversationID: convo.id,
            conversation: stub,
            runtime: nil,
            poolStateProvider: { _ in nil }
        )
        #expect(payload.poolModelState == nil)
    }

    @Test("Deleted snapshot has no poolModelState even with provider")
    func deletedSnapshotIgnoresProvider() async throws {
        let stub = SnapshotConversationStub(conversation: ModelConversation(model: Self.makeModel()))
        let payload = await ConversationStateSnapshotBuilder.build(
            conversationID: UUID(), // unknown id → deleted path
            conversation: stub,
            runtime: nil,
            poolStateProvider: { _ in
                ModelStatePayload(phase: .done, thinking: false)
            }
        )
        #expect(payload.exists == false)
        #expect(payload.poolModelState == nil)
    }
}
