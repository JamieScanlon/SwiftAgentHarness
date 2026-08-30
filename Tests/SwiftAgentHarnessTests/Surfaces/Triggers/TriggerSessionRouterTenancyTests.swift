import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("TriggerSessionRouter tenancy")
struct TriggerSessionRouterTenancyTests {
    @Test("cron threaded route allows matching owner stamp")
    func matchingOwnerAllowed() async throws {
        let owner = UUID()
        let targetID = UUID()
        let catalog = RouterTenancyStubCatalog(conversations: [
            targetID: makeConversation(id: targetID, ownerAccountID: owner),
        ])
        let router = makeRouter(catalog: catalog)
        let trigger = HarnessTrigger(
            id: "cron-1",
            source: .cron,
            sourceMetadata: [
                "conversationID": targetID.uuidString,
                "ownerAccountID": owner.uuidString,
                "cronJobId": "job-1",
            ],
            payload: "ping",
            initiator: TriggerInitiator(kind: .user),
            trust: .userDeferred,
            routingMode: .threaded
        )
        let route = try await router.route(trigger)
        #expect(route.conversationID == targetID)
    }

    @Test("cron threaded route rejects mismatched owner stamp")
    func mismatchedOwnerRejected() async throws {
        let ownerA = UUID()
        let ownerB = UUID()
        let targetID = UUID()
        let catalog = RouterTenancyStubCatalog(conversations: [
            targetID: makeConversation(id: targetID, ownerAccountID: ownerB),
        ])
        let router = makeRouter(catalog: catalog)
        let trigger = HarnessTrigger(
            id: "cron-2",
            source: .cron,
            sourceMetadata: [
                "conversationID": targetID.uuidString,
                "ownerAccountID": ownerA.uuidString,
                "cronJobId": "job-2",
            ],
            payload: "ping",
            initiator: TriggerInitiator(kind: .user),
            trust: .userDeferred,
            routingMode: .threaded
        )
        let route = try await router.route(trigger)
        #expect(route.conversationID == nil)
    }

    @Test("cron threaded route rejects legacy tasks without owner stamp")
    func legacyCronRejected() async throws {
        let targetID = UUID()
        let catalog = RouterTenancyStubCatalog(conversations: [
            targetID: makeConversation(id: targetID, ownerAccountID: UUID()),
        ])
        let router = makeRouter(catalog: catalog)
        let trigger = HarnessTrigger(
            id: "cron-3",
            source: .cron,
            sourceMetadata: [
                "conversationID": targetID.uuidString,
                "cronJobId": "job-3",
            ],
            payload: "ping",
            initiator: TriggerInitiator(kind: .user),
            trust: .userDeferred,
            routingMode: .threaded
        )
        let route = try await router.route(trigger)
        #expect(route.conversationID == nil)
    }

    @Test("unstamped cron into an unowned conversation is allowed when tenancy is disabled")
    func unstampedCronUnownedAllowedWhenTenancyDisabled() async throws {
        let targetID = UUID()
        let catalog = RouterTenancyStubCatalog(conversations: [
            targetID: makeConversation(id: targetID, ownerAccountID: nil),
        ])
        let router = makeRouter(catalog: catalog, tenancyPolicy: .disabled)
        let trigger = HarnessTrigger(
            id: "cron-4",
            source: .cron,
            sourceMetadata: [
                "conversationID": targetID.uuidString,
                "cronJobId": "job-4",
            ],
            payload: "ping",
            initiator: TriggerInitiator(kind: .user),
            trust: .userDeferred,
            routingMode: .threaded
        )
        let route = try await router.route(trigger)
        #expect(route.conversationID == targetID)
    }

    @Test("unstamped cron into an unowned conversation is rejected when tenancy is required")
    func unstampedCronRejectedWhenTenancyRequired() async throws {
        let targetID = UUID()
        let catalog = RouterTenancyStubCatalog(conversations: [
            targetID: makeConversation(id: targetID, ownerAccountID: nil),
        ])
        let router = makeRouter(
            catalog: catalog,
            tenancyPolicy: TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: true)
        )
        let trigger = HarnessTrigger(
            id: "cron-5",
            source: .cron,
            sourceMetadata: [
                "conversationID": targetID.uuidString,
                "cronJobId": "job-5",
            ],
            payload: "ping",
            initiator: TriggerInitiator(kind: .user),
            trust: .userDeferred,
            routingMode: .threaded
        )
        let route = try await router.route(trigger)
        #expect(route.conversationID == nil)
    }

    @Test("unstamped cron into a missing conversation is rejected")
    func unstampedCronMissingConversationRejected() async throws {
        let targetID = UUID()
        let catalog = RouterTenancyStubCatalog(conversations: [:])
        let router = makeRouter(catalog: catalog)
        let trigger = HarnessTrigger(
            id: "cron-6",
            source: .cron,
            sourceMetadata: [
                "conversationID": targetID.uuidString,
                "cronJobId": "job-6",
            ],
            payload: "ping",
            initiator: TriggerInitiator(kind: .user),
            trust: .userDeferred,
            routingMode: .threaded
        )
        let route = try await router.route(trigger)
        #expect(route.conversationID == nil)
    }

    private func makeRouter(
        catalog: RouterTenancyStubCatalog,
        tenancyPolicy: TenancyPolicySettings = .disabled
    ) -> TriggerSessionRouter {
        TriggerSessionRouter(
            sessionIndex: TriggerSessionIndex(createConversation: { _ in UUID() }),
            threadedTargetValidator: { conversationID, trigger in
                await TriggerThreadedTargetValidator.validate(
                    conversationID: conversationID,
                    trigger: trigger,
                    catalog: catalog,
                    tenancyPolicy: tenancyPolicy
                )
            }
        )
    }

    private func makeConversation(id: UUID, ownerAccountID: UUID?) -> ModelConversation {
        let now = Date()
        return ModelConversation(
            id: id,
            model: Model(
                id: UUID(),
                protocol: .openAIAPI,
                modelName: "router-tenancy",
                serverURL: URL(string: "http://localhost:1234")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            createdAt: now,
            updatedAt: now,
            topic: "topic",
            description: nil,
            interactionMode: .chat,
            metadata: nil,
            parentConversationID: nil,
            ownerAccountID: ownerAccountID,
            lineageKind: .root,
            origin: .user
        )
    }
}

private final class RouterTenancyStubCatalog: ConversationCatalogServicing, @unchecked Sendable {
    let conversations: [UUID: ModelConversation]

    init(conversations: [UUID: ModelConversation]) {
        self.conversations = conversations
    }

    func listConversationInfo() async -> [ModelConversation] { Array(conversations.values) }
    func listConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] { [] }
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
