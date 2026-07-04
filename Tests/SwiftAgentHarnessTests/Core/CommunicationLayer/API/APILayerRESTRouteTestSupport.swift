import Foundation
import SwiftData
import SwiftAgentKit
import Testing
import Vapor
import VaporTesting
@testable import SwiftAgentHarness

final class APILayerRESTStubModelProvider: APILayerModelManaging, Sendable {
    let models: [Model]
    let error: Error?

    init(models: [Model] = [], error: Error? = nil) {
        self.models = models
        self.error = error
    }

    func getAvailableModels() async -> [Model] {
        if error != nil {
            return []
        }
        return models
    }
}

enum APILayerRESTRouteTestSupport {
    static func makeContainer() throws -> ModelContainer {
        try HarnessTestModelContainer.makeInMemory()
    }

    static func makeTestModel(id: UUID = UUID()) -> Model {
        Model(
            id: id,
            protocol: .openAIAPI,
            modelName: "test-model",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    static func makeChatManager(container: ModelContainer) -> HarnessRuntimeSession {
        HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
    }

    static let strictTenancyAuthSettings = APIAccessTokenAuthenticationSettings(hs256Secret: "rest-coverage-test-secret")

    static func configureStrictTenancyAuth(on api: APILayer) async {
        await api.setTenancyPolicySettings(TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: true))
        await api.setAPIAccessTokenAuthenticationSettings(strictTenancyAuthSettings)
    }

    static func bearerAuthorization(ownerAccountID: UUID) async throws -> String {
        try await HarnessAPIAccessTokenFactory.authorizationHeaderValue(
            ownerAccountID: ownerAccountID,
            settings: strictTenancyAuthSettings
        )
    }
}
final class ModePatchConflictConversationStub: APILayerConversationManaging, Sendable {
    private let baseConversation: ModelConversation
    private let activeRunID: UUID

    init(conversation: ModelConversation, activeRunID: UUID) {
        self.baseConversation = conversation
        self.activeRunID = activeRunID
    }

    func apiListConversationInfo() async -> [ModelConversation] {
        [baseConversation]
    }

    func apiListConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] {
        []
    }

    func apiUpdateConversationModelAndUserPrompt(conversationID: UUID, model: Model?, userSystemPrompt: String?) async throws {
        _ = (conversationID, model, userSystemPrompt)
        throw APILayerConversationAPIError.unsupported
    }

    func apiUpdateConversationToolOverrides(conversationID: UUID, routingPolicyTools: [String]) async throws {
        _ = (conversationID, routingPolicyTools)
        throw APILayerConversationAPIError.unsupported
    }

    func apiUpdateConversationSkillOverrides(conversationID: UUID, routingPolicySkills: [String]) async throws {
        _ = (conversationID, routingPolicySkills)
        throw APILayerConversationAPIError.unsupported
    }

    func apiUpdateConversationThinkingConfig(conversationID: UUID, thinkingConfig: ThinkingConfig?) async throws {
        _ = (conversationID, thinkingConfig)
        throw APILayerConversationAPIError.unsupported
    }

    func apiReadPlanMarkdown(conversationID: UUID) async throws -> String {
        _ = conversationID
        throw APILayerConversationAPIError.unsupported
    }

    func apiDeleteConversation(conversationID: UUID, hard: Bool) async throws {
        _ = (conversationID, hard)
        throw APILayerConversationAPIError.unsupported
    }

    func apiGetConversation(id: UUID) async -> ModelConversation? {
        guard id == baseConversation.id else { return nil }
        return baseConversation
    }

    func apiApplyConversationRESTPatch(conversationID: UUID, patch: ConversationPatch, resolvedModel: Model?) async throws -> UInt64 {
        _ = patch
        _ = resolvedModel
        throw ConversationServiceError.conversationModeChangeRunInProgress(
            conversationID: conversationID,
            activeRunID: activeRunID
        )
    }
}

final class ModelPromptPatchConflictConversationStub: APILayerConversationManaging, Sendable {
    private let baseConversation: ModelConversation
    private let activeRunID: UUID

    init(conversation: ModelConversation, activeRunID: UUID) {
        self.baseConversation = conversation
        self.activeRunID = activeRunID
    }

    func apiListConversationInfo() async -> [ModelConversation] {
        [baseConversation]
    }

    func apiListConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] {
        []
    }

    func apiUpdateConversationModelAndUserPrompt(conversationID: UUID, model: Model?, userSystemPrompt: String?) async throws {
        _ = (conversationID, model, userSystemPrompt)
        throw APILayerConversationAPIError.unsupported
    }

    func apiUpdateConversationToolOverrides(conversationID: UUID, routingPolicyTools: [String]) async throws {
        _ = (conversationID, routingPolicyTools)
        throw APILayerConversationAPIError.unsupported
    }

    func apiUpdateConversationSkillOverrides(conversationID: UUID, routingPolicySkills: [String]) async throws {
        _ = (conversationID, routingPolicySkills)
        throw APILayerConversationAPIError.unsupported
    }

    func apiUpdateConversationThinkingConfig(conversationID: UUID, thinkingConfig: ThinkingConfig?) async throws {
        _ = (conversationID, thinkingConfig)
        throw APILayerConversationAPIError.unsupported
    }

    func apiReadPlanMarkdown(conversationID: UUID) async throws -> String {
        _ = conversationID
        throw APILayerConversationAPIError.unsupported
    }

    func apiDeleteConversation(conversationID: UUID, hard: Bool) async throws {
        _ = (conversationID, hard)
        throw APILayerConversationAPIError.unsupported
    }

    func apiGetConversation(id: UUID) async -> ModelConversation? {
        guard id == baseConversation.id else { return nil }
        return baseConversation
    }

    func apiApplyConversationRESTPatch(conversationID: UUID, patch: ConversationPatch, resolvedModel: Model?) async throws -> UInt64 {
        _ = patch
        _ = resolvedModel
        throw ConversationServiceError.conversationModelOrPromptChangeRunInProgress(
            conversationID: conversationID,
            activeRunID: activeRunID
        )
    }
}

final class ModePatchConflictRuntimeStub: APILayerChatRuntimeManaging, Sendable {
    func apiMessageStream(for conversationID: UUID?) async throws -> AsyncStream<[Message]> {
        _ = conversationID
        throw APILayerConversationAPIError.unsupported
    }

    func apiSendMessageAndStreamResponse(
        conversationID: UUID,
        _ text: String,
        images: [Message.Image],
        enableTools: Bool,
        enableAgents: Bool,
        expectedPreviousTailHarnessMessageID: UUID?,
        inputTrustRaw: String?,
        systemReminder: String?,
        originSurface: String?,
        originSenderID: String?
    ) async throws -> ChatStreamResponse {
        _ = (
            conversationID,
            text,
            images,
            enableTools,
            enableAgents,
            expectedPreviousTailHarnessMessageID,
            inputTrustRaw,
            systemReminder,
            originSurface,
            originSenderID
        )
        throw APILayerConversationAPIError.unsupported
    }

    func apiCancelMessageStream() async {}

    func apiSetOrchestrationStateOutOfBandPush(id: UUID, _ push: @escaping @Sendable (ConversationOrchestrationState) async -> Void) async {
        _ = (id, push)
    }

    func apiClearOrchestrationStateOutOfBandPush(id: UUID) async {
        _ = id
    }

    func apiCancelRun(conversationID: UUID, runID: UUID) async throws {
        _ = (conversationID, runID)
        throw APILayerConversationAPIError.unsupported
    }

    func apiListConversationRuns(conversationID: UUID, filter: ConversationRunListFilter) async -> ConversationRunListResponse {
        _ = (conversationID, filter)
        return ConversationRunListResponse(runs: [])
    }

    func apiGetConversationRun(conversationID: UUID, runID: UUID, includeProjectionDetail: Bool) async -> ConversationRunInfo? {
        _ = (conversationID, runID, includeProjectionDetail)
        return nil
    }
}
