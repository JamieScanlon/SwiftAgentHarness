import EasyJSON
import Foundation
import Logging
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ScheduleToolCorrelation")
struct ScheduleToolCorrelationTests {
    @Test("schedule_create inherits host trigger lineage")
    func inheritsHostLineage() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("schedule-corr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let owner = UUID()
        let conv = makeConversation(ownerAccountID: owner)
        let catalog = CorrelationStubCatalog(conversations: [conv.id: conv])
        let (dataService, scheduler) = makeDataService(tmp: tmp, catalog: catalog)
        let hostTrigger = HarnessTrigger(
            id: "webhook-delivery-1",
            source: .webhook,
            payload: "incoming",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty,
            correlation: .root(triggerID: "webhook-delivery-1")
        )
        let provider = ScheduleToolProvider(
            dataService: dataService,
            resolveHostTrigger: { hostTrigger }
        )
        let toolCall = ToolCall(
            name: "schedule_create",
            arguments: .object([
                "scheduleKind": .string("at"),
                "at": .string("2030-01-01T00:00:00Z"),
                "payloadKind": .string("agentTurn"),
                "payloadText": .string("follow up"),
                "recurring": .boolean(false),
            ]),
            id: "call-1"
        )
        let scope = conv.conversationScope()
        let result = try await ConversationScope.withCurrent(scope) {
            try await provider.executeTool(toolCall)
        }
        #expect(result.success == true)
        let tasks = try await scheduler.listTasks()
        #expect(tasks.count == 1)
        let correlation = try #require(tasks[0].correlation)
        #expect(correlation.rootId == "webhook-delivery-1")
        #expect(correlation.correlationId == "webhook-delivery-1")
        #expect(correlation.parentTriggerId == "webhook-delivery-1")
        #expect(correlation.followUpKind == "scheduled")
        #expect(tasks[0].createdByConversationID == conv.id)
        #expect(tasks[0].ownerAccountID == owner)
    }

    @Test("explicit correlation overrides host inherit")
    func explicitOverridesHost() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("schedule-corr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let owner = UUID()
        let conv = makeConversation(ownerAccountID: owner)
        let catalog = CorrelationStubCatalog(conversations: [conv.id: conv])
        let (dataService, scheduler) = makeDataService(tmp: tmp, catalog: catalog)
        let hostTrigger = HarnessTrigger(
            id: "webhook-delivery-1",
            source: .webhook,
            payload: "incoming",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty,
            correlation: .root(triggerID: "webhook-delivery-1")
        )
        let provider = ScheduleToolProvider(
            dataService: dataService,
            resolveHostTrigger: { hostTrigger }
        )
        let toolCall = ToolCall(
            name: "schedule_create",
            arguments: .object([
                "scheduleKind": .string("at"),
                "at": .string("2030-01-01T00:00:00Z"),
                "payloadKind": .string("agentTurn"),
                "payloadText": .string("follow up"),
                "recurring": .boolean(false),
                "rootId": .string("custom-root"),
                "parentTriggerId": .string("custom-parent"),
                "correlationId": .string("custom-workflow"),
            ]),
            id: "call-2"
        )
        let scope = conv.conversationScope()
        _ = try await ConversationScope.withCurrent(scope) {
            try await provider.executeTool(toolCall)
        }
        let tasks = try await scheduler.listTasks()
        let correlation = try #require(tasks[0].correlation)
        #expect(correlation.rootId == "custom-root")
        #expect(correlation.parentTriggerId == "custom-parent")
        #expect(correlation.correlationId == "custom-workflow")
    }

    private func makeConversation(ownerAccountID: UUID) -> ModelConversation {
        let now = Date()
        return ModelConversation(
            id: UUID(),
            model: Model(
                id: UUID(),
                protocol: .openAIAPI,
                modelName: "corr-test",
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

    private func makeDataService(
        tmp: URL,
        catalog: CorrelationStubCatalog
    ) -> (dataService: ScheduledTaskToolDataService, scheduler: TriggerSchedulerService) {
        let store = ScheduledTaskStore(fileURL: tmp.appendingPathComponent("tasks.json"))
        // Agent-authority creates default to `durable: false`, so scheduler and registration must
        // share one session store or the created task is invisible to `schedule_list`.
        let sessionStore = SessionScopedScheduledTaskStore()
        let scheduler = TriggerSchedulerService(
            store: store,
            sessionStore: sessionStore,
            dispatch: makeDispatch(),
            lockURL: tmp.appendingPathComponent("lock.json"),
            logger: Logger(label: "test")
        )
        let dataService = ScheduledTaskToolDataService(
            scheduler: scheduler,
            registration: TriggerRegistrationTestSupport.service(store: store, sessionStore: sessionStore),
            catalog: catalog
        )
        return (dataService, scheduler)
    }

    private func makeDispatch() -> TriggerDispatchService {
        let policy = TriggerActivationPolicy(
            idempotency: TriggerIdempotencyGate(dedupe: ScheduleToolDedupe()),
            rateLimit: TriggerRateLimitGate(maxPerWindow: 100),
            costCeiling: TriggerCostCeilingGate(maxPerWindow: 100),
            auditLog: TriggerAuditLog(logger: Logger(label: "test"))
        )
        return TriggerDispatchService(
            activationPolicy: policy,
            sessionRouter: TriggerSessionRouter(sessionIndex: TriggerSessionIndex(createConversation: { _ in UUID() })),
            promptBuilder: TriggerPromptBuilder(),
            runtime: ScheduleToolCaptureRuntime()
        )
    }
}

private final class CorrelationStubCatalog: ConversationCatalogServicing, @unchecked Sendable {
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

private final class ScheduleToolCaptureRuntime: TriggerRuntimeDispatching, @unchecked Sendable {
    func dispatchTriggerMessage(
        conversationID: UUID,
        text: String,
        systemReminder: String?,
        inputTrustRaw: String?,
        resolvedInputTrustClass: TrustPolicyClass?,
        enableTools: Bool,
        enableAgents: Bool,
        originSurface: String?,
        originSenderID: String?,
        originSenderIsOwner: Bool?
    ) async throws {}
}

private struct ScheduleToolDedupe: TriggerDedupeChecking {
    func dedupePeek(key: String) async throws -> Bool { false }
    func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool { true }
}
