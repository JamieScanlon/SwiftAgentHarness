import Foundation
import SwiftAgentKit

struct ConversationCatalogServiceImpl: ConversationCatalogServicing {
    let deps: ConversationRuntimeDependencies
    let selection: ConversationSelectionAccessing
    let skillActivation: SkillActivationService?
    let registryOwnerAccountScope: @Sendable () -> UUID?

    init(
        deps: ConversationRuntimeDependencies,
        selection: ConversationSelectionAccessing,
        skillActivation: SkillActivationService? = nil,
        registryOwnerAccountScope: @escaping @Sendable () -> UUID? = { nil }
    ) {
        self.deps = deps
        self.selection = selection
        self.skillActivation = skillActivation
        self.registryOwnerAccountScope = registryOwnerAccountScope
    }

    func listConversationInfo() async -> [ModelConversation] {
        await deps.persistenceDomain.listConversationInfo()
    }

    func listConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] {
        await deps.persistenceDomain.listConversationMetadata(visibility: visibility)
    }

    func getConversation(id: UUID) async -> ModelConversation? {
        guard var conversation = await deps.persistenceDomain.modelConversation(id: id) else {
            return nil
        }
        if conversation.lifecycle == .deleted {
            return nil
        }
        conversation.messages = await projectedMessages(for: conversation)
        return conversation
    }

    func getConversationWithDerived(id: UUID) async -> ConversationReadWithDerivedResponse? {
        guard let conversation = await getConversation(id: id) else {
            return nil
        }
        return await deps.persistenceDomain.readConversationWithDerived(
            conversationID: id,
            projectedConversation: conversation
        )
    }

    func projectConversation(conversationID: UUID, request: ConversationProjectRequest) async throws -> ConversationProjectResponse {
        guard let conversation = await deps.persistenceDomain.modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        var response = try await deps.persistenceDomain.projectConversation(conversationID: conversationID, request: request)
        guard SystemPromptAssemblyProjector.includeAssembledSystemPrompt(in: request) else {
            return response
        }
        let atEventID = SystemPromptAssemblyProjector.atEventID(
            in: request,
            defaultFrontier: response.metadata.frontierEventID
        )
        let baseMessages = await deps.persistenceDomain.transcriptBaseMessages(for: conversation)
        let (events, _) = await deps.persistenceDomain.loadConversationEventsWithFrontier(conversationID: conversationID)
        let frontierMessages = ConversationEventProjector.projectMessages(
            baseMessages: baseMessages,
            events: events,
            frontierEventID: atEventID
        )
        let projectionPolicy = await ContextEngineProjectionPolicyBuilder.buildProjectionPolicy(
            deps: deps,
            conversation: conversation,
            configuration: nil
        )
        guard let promptPolicy = projectionPolicy.systemPromptAssemblyPolicy else {
            return response
        }
        let assembled = try await SystemPromptAssemblyProjector.projectAssembledSystemPrompt(
            conversation: conversation,
            messages: frontierMessages,
            policy: promptPolicy,
            skillLoaderProvider: { [skillActivation] conversationID in
                guard let skillActivation else { return nil }
                return await skillActivation.skillLoader(for: conversationID)
            },
            memoryBlocksProvider: { [deps] conversationID in
                guard let defaultEngine = deps.contextEngine as? DefaultContextEngine,
                      let memoryService = defaultEngine.memoryService else {
                    return nil
                }
                return await memoryService.systemPromptBlocks(conversationID: conversationID)
            },
            memoryGenerationProvider: { [deps] conversationID in
                guard let defaultEngine = deps.contextEngine as? DefaultContextEngine,
                      let memoryService = defaultEngine.memoryService else {
                    return nil
                }
                return await memoryService.currentSnapshotGeneration(conversationID: conversationID)
            },
            logger: deps.logger
        )
        if let assembled {
            response.assembledSystemPrompt = assembled.text
            response.systemPromptReplaySpecDigest = assembled.replaySpecDigest
            response.sectionProvenance = assembled.sectionProvenance
        }
        return response
    }

    func listConversations(query: ConversationListQuery) async -> PagedConversationsResponse {
        await deps.persistenceDomain.listConversationSummaries(query: query)
    }

    func searchConversations(query: ConversationSearchRequest) async -> ConversationSearchResponse {
        await deps.persistenceDomain.searchConversations(request: query)
    }

    func listMessagesThrowing(conversationID: UUID) async throws -> [Message] {
        guard let conversation = await deps.persistenceDomain.modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        return await projectedMessages(for: conversation)
    }

    func latestTranscriptSequence(conversationID: UUID) async -> Int? {
        try? await deps.persistenceDomain.latestTranscriptSequence(conversationID: conversationID)
    }

    func readTranscriptEntries(conversationID: UUID, request: SessionTranscriptReadRequest) async throws -> [SessionTranscriptEntry] {
        try await deps.persistenceDomain.readTranscriptEntries(
            conversationID: conversationID,
            request: request
        )
    }

    func conversationEventsBackfill(conversationID: UUID, since: Int?) async throws -> ConversationEventsBackfillResponse {
        let topic = ConversationTopicFormat.topic(conversationID: conversationID)
        let entries = try await deps.persistenceDomain.readTranscriptEntries(
            conversationID: conversationID,
            request: .full
        )
        let latest = (try? await deps.persistenceDomain.latestTranscriptSequence(conversationID: conversationID))
            ?? entries.map(\.sequence).max() ?? 0
        let replay = ConversationEventsReplayRequest.totalOrderSince(since)
        let hydrated = ConversationEventsTranscriptReplayHydrator.persistedReplayLines(
            topic: topic,
            conversationID: conversationID,
            replay: replay,
            entries: entries,
            latestTranscriptSequence: latest
        )
        return ConversationEventsBackfillResponse(
            conversationID: conversationID,
            since: since,
            latestSeq: latest,
            lagging: hydrated.lagging,
            events: hydrated.lines
        )
    }

    func registryOwnerAccountID() async -> UUID? {
        APISessionContext.authenticatedOwnerAccountID ?? registryOwnerAccountScope()
    }

    private func projectedMessages(for conversation: ModelConversation) async -> [Message] {
        await selection.projectedMessages(for: conversation)
    }
}
