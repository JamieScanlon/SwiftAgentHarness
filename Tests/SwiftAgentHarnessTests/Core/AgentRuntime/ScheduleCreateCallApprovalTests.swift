import EasyJSON
import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator
import Testing
@testable import SwiftAgentHarness

@Suite("ScheduleCreate call approval dispatch")
struct ScheduleCreateCallApprovalTests {
    @Test("cross-conversation agentTurn schedule_create requires approval at dispatch")
    func crossConversationRequiresApproval() async {
        let owner = UUID()
        let root = makeConversation(ownerAccountID: owner)
        let branch = makeConversation(
            ownerAccountID: owner,
            parentConversationID: root.id,
            lineageKind: .branch
        )
        let catalog = CallApprovalStubCatalog(conversations: [root.id: root, branch.id: branch])
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "schedule_create", description: "create", parameters: [], type: .function),
            source: .local
        )
        let snapshot = RuntimeToolTurnPolicySnapshot(
            availabilitySnapshots: [
                RuntimeToolAvailabilitySnapshot(entry: entry, decision: .allowedDefault),
            ],
            effectiveEntries: [entry],
            dispatchContract: .conservativeDefault
        )
        let call = ToolCallRequest(
            id: "call-approval-1",
            name: "schedule_create",
            arguments: .object([
                "payloadKind": .string("agentTurn"),
                "conversationID": .string(branch.id.uuidString),
            ])
        )
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        let outcome = await AgentLoopToolDispatch.dispatch(
            call: call,
            conversationID: root.id,
            runID: nil,
            orchestrator: orchestrator,
            snapshot: snapshot,
            configuration: AgentRuntimeTurnConfiguration(enableTools: true, enableAgents: true),
            conversation: root,
            gateway: DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore()),
            parentLookup: { id in await catalog.getConversation(id: id) }
        )
        guard case .approvalRequired(let toolName, _) = outcome else {
            Issue.record("Expected approvalRequired, got \(outcome)")
            return
        }
        #expect(toolName == "schedule_create")
    }

    @Test("binding-specific preApprovedCallBindings bypasses cross-conversation approval gate")
    func bindingPreApprovedBypassesApproval() async {
        let owner = UUID()
        let root = makeConversation(ownerAccountID: owner)
        let branch = makeConversation(
            ownerAccountID: owner,
            parentConversationID: root.id,
            lineageKind: .branch
        )
        let catalog = CallApprovalStubCatalog(conversations: [root.id: root, branch.id: branch])
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "schedule_create", description: "create", parameters: [], type: .function),
            source: .local
        )
        let snapshot = RuntimeToolTurnPolicySnapshot(
            availabilitySnapshots: [
                RuntimeToolAvailabilitySnapshot(entry: entry, decision: .allowedDefault),
            ],
            effectiveEntries: [entry],
            dispatchContract: .conservativeDefault
        )
        let call = ToolCallRequest(
            id: "call-approval-2",
            name: "schedule_create",
            arguments: .object([
                "payloadKind": .string("agentTurn"),
                "conversationID": .string(branch.id.uuidString),
            ])
        )
        let binding = ToolCallApprovalBinding.from(call: call)
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        let outcome = await AgentLoopToolDispatch.dispatch(
            call: call,
            conversationID: root.id,
            runID: nil,
            orchestrator: orchestrator,
            snapshot: snapshot,
            configuration: AgentRuntimeTurnConfiguration(
                enableTools: true,
                enableAgents: true,
                preApprovedCallBindings: [binding]
            ),
            conversation: root,
            gateway: DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore()),
            parentLookup: { id in await catalog.getConversation(id: id) }
        )
        if case .approvalRequired = outcome {
            Issue.record("Expected dispatch to proceed past approval gate")
        }
    }

    @Test("name-only preApprovedToolNames no longer bypasses cross-conversation schedule_create gate")
    func nameOnlyPreApprovalDoesNotBypass() async {
        let owner = UUID()
        let root = makeConversation(ownerAccountID: owner)
        let branch = makeConversation(
            ownerAccountID: owner,
            parentConversationID: root.id,
            lineageKind: .branch
        )
        let catalog = CallApprovalStubCatalog(conversations: [root.id: root, branch.id: branch])
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "schedule_create", description: "create", parameters: [], type: .function),
            source: .local
        )
        let snapshot = RuntimeToolTurnPolicySnapshot(
            availabilitySnapshots: [
                RuntimeToolAvailabilitySnapshot(entry: entry, decision: .allowedDefault),
            ],
            effectiveEntries: [entry],
            dispatchContract: .conservativeDefault
        )
        let call = ToolCallRequest(
            id: "call-approval-3",
            name: "schedule_create",
            arguments: .object([
                "payloadKind": .string("agentTurn"),
                "conversationID": .string(branch.id.uuidString),
            ])
        )
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        let outcome = await AgentLoopToolDispatch.dispatch(
            call: call,
            conversationID: root.id,
            runID: nil,
            orchestrator: orchestrator,
            snapshot: snapshot,
            configuration: AgentRuntimeTurnConfiguration(
                enableTools: true,
                enableAgents: true,
                preApprovedToolNames: ["schedule_create"]
            ),
            conversation: root,
            gateway: DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore()),
            parentLookup: { id in await catalog.getConversation(id: id) }
        )
        guard case .approvalRequired(let toolName, _) = outcome else {
            Issue.record("Expected approvalRequired, got \(outcome)")
            return
        }
        #expect(toolName == "schedule_create")
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
                modelName: "dispatch-approval-test",
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

private final class CallApprovalStubCatalog: ConversationCatalogServicing, @unchecked Sendable {
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
