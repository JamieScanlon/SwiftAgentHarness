import Foundation
import SwiftAgentKit

/// Minimal catalog seam for trigger wiring when the full ``ConversationCatalogServicing`` type is module-internal.
public struct ScheduleToolCatalogPort: Sendable {
    var getConversation: @Sendable (UUID) async -> ModelConversation?
    var registryOwnerAccountID: @Sendable () async -> UUID?

    public init(
        getConversation: @escaping @Sendable (UUID) async -> ModelConversation?,
        registryOwnerAccountID: @escaping @Sendable () async -> UUID? = { nil }
    ) {
        self.getConversation = getConversation
        self.registryOwnerAccountID = registryOwnerAccountID
    }

    init(catalog: any ConversationCatalogServicing) {
        self.getConversation = { id in await catalog.getConversation(id: id) }
        self.registryOwnerAccountID = { await catalog.registryOwnerAccountID() }
    }
}

private struct ScheduleToolCatalogAdapter: ConversationCatalogServicing, Sendable {
    let port: ScheduleToolCatalogPort

    func listConversationInfo() async -> [ModelConversation] { [] }
    func listConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] { [] }
    func getConversation(id: UUID) async -> ModelConversation? { await port.getConversation(id) }
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
    func registryOwnerAccountID() async -> UUID? { await port.registryOwnerAccountID() }
}

extension ScheduledTaskToolDataService {
    init(
        scheduler: TriggerSchedulerService,
        registration: TriggerRegistrationService,
        catalogPort: ScheduleToolCatalogPort,
        tenancyPolicy: TenancyPolicySettings = .disabled
    ) {
        self.init(
            scheduler: scheduler,
            registration: registration,
            catalog: ScheduleToolCatalogAdapter(port: catalogPort),
            tenancyPolicy: tenancyPolicy
        )
    }
}

extension TriggerThreadedTargetValidator {
    static func validate(
        conversationID: UUID,
        trigger: HarnessTrigger,
        catalogPort: ScheduleToolCatalogPort,
        tenancyPolicy: TenancyPolicySettings
    ) async -> Bool {
        await validate(
            conversationID: conversationID,
            trigger: trigger,
            catalog: ScheduleToolCatalogAdapter(port: catalogPort),
            tenancyPolicy: tenancyPolicy
        )
    }
}
