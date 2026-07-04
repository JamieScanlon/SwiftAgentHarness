import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ScheduleCreateApprovalPolicy")
struct ScheduleCreateApprovalPolicyTests {
    @Test("same-conversation agentTurn does not require approval")
    func sameConversationNoApproval() async {
        let owner = UUID()
        let conv = makeConversation(ownerAccountID: owner)
        let catalog = ApprovalStubCatalog(conversations: [conv.id: conv])
        let args: JSON = .object([
            "payloadKind": .string("agentTurn"),
            "conversationID": .string(conv.id.uuidString),
        ])
        let requires = await ScheduleCreateApprovalPolicy.requiresApproval(
            arguments: args,
            callerConversationID: conv.id,
            parentLookup: { id in await catalog.getConversation(id: id) },
            tenancyPolicy: .disabled
        )
        #expect(requires == false)
    }

    @Test("sibling-conversation agentTurn requires approval")
    func siblingConversationRequiresApproval() async {
        let owner = UUID()
        let root = makeConversation(ownerAccountID: owner)
        let branch = makeConversation(
            ownerAccountID: owner,
            parentConversationID: root.id,
            lineageKind: .branch
        )
        let catalog = ApprovalStubCatalog(conversations: [root.id: root, branch.id: branch])
        let args: JSON = .object([
            "payloadKind": .string("agentTurn"),
            "conversationID": .string(branch.id.uuidString),
        ])
        let requires = await ScheduleCreateApprovalPolicy.requiresApproval(
            arguments: args,
            callerConversationID: root.id,
            parentLookup: { id in await catalog.getConversation(id: id) },
            tenancyPolicy: .disabled
        )
        #expect(requires == true)
    }

    @Test("cross-lineage agentTurn does not require approval path")
    func crossLineageNotApprovalPath() async {
        let owner = UUID()
        let rootA = makeConversation(ownerAccountID: owner)
        let rootB = makeConversation(ownerAccountID: owner)
        let catalog = ApprovalStubCatalog(conversations: [rootA.id: rootA, rootB.id: rootB])
        let args: JSON = .object([
            "payloadKind": .string("agentTurn"),
            "conversationID": .string(rootB.id.uuidString),
        ])
        let requires = await ScheduleCreateApprovalPolicy.requiresApproval(
            arguments: args,
            callerConversationID: rootA.id,
            parentLookup: { id in await catalog.getConversation(id: id) },
            tenancyPolicy: .disabled
        )
        #expect(requires == false)
    }

    @Test("systemEvent does not require approval")
    func systemEventNoApproval() async {
        let owner = UUID()
        let root = makeConversation(ownerAccountID: owner)
        let branch = makeConversation(
            ownerAccountID: owner,
            parentConversationID: root.id,
            lineageKind: .branch
        )
        let catalog = ApprovalStubCatalog(conversations: [root.id: root, branch.id: branch])
        let args: JSON = .object([
            "payloadKind": .string("systemEvent"),
            "conversationID": .string(branch.id.uuidString),
        ])
        let requires = await ScheduleCreateApprovalPolicy.requiresApproval(
            arguments: args,
            callerConversationID: root.id,
            parentLookup: { id in await catalog.getConversation(id: id) },
            tenancyPolicy: .disabled
        )
        #expect(requires == false)
    }

    private func makeConversation(
        id: UUID = UUID(),
        ownerAccountID: UUID,
        parentConversationID: UUID? = nil,
        lineageKind: ConversationLineageKind = .root
    ) -> ModelConversation {
        let now = Date()
        return ModelConversation(
            id: id,
            model: Model(
                id: UUID(),
                protocol: .openAIAPI,
                modelName: "approval-test",
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
            parentConversationID: parentConversationID,
            ownerAccountID: ownerAccountID,
            lineageKind: lineageKind,
            origin: .user
        )
    }
}

private final class ApprovalStubCatalog: ConversationCatalogServicing, @unchecked Sendable {
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
