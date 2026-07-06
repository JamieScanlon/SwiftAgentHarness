import EasyJSON
import Foundation
import Logging
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private enum ScheduledTaskTenancyTestSupport {
    static func makeModel() -> Model {
        Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "schedule-tenancy-model",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    static func makeConversation(
        id: UUID = UUID(),
        ownerAccountID: UUID? = nil,
        parentConversationID: UUID? = nil,
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
            metadata: nil,
            parentConversationID: parentConversationID,
            ownerAccountID: ownerAccountID,
            lineageKind: lineageKind,
            origin: origin
        )
    }

    static func makeScheduler(tmp: URL) -> TriggerSchedulerService {
        let store = ScheduledTaskStore(fileURL: tmp.appendingPathComponent("tasks.json"))
        let dispatch = TriggerDispatchService(
            activationPolicy: TriggerActivationPolicy(
                idempotency: TriggerIdempotencyGate(dedupe: ScheduleTenancyDedupe()),
                rateLimit: TriggerRateLimitGate(maxPerWindow: 100),
                costCeiling: TriggerCostCeilingGate(maxPerWindow: 100),
                auditLog: TriggerAuditLog(logger: Logger(label: "test"))
            ),
            sessionRouter: TriggerSessionRouter(sessionIndex: TriggerSessionIndex(createConversation: { _ in UUID() })),
            promptBuilder: TriggerPromptBuilder(),
            runtime: ScheduleTenancyCaptureRuntime()
        )
        return TriggerSchedulerService(
            store: store,
            dispatch: dispatch,
            lockURL: tmp.appendingPathComponent("lock.json"),
            logger: Logger(label: "test")
        )
    }

    static func makeService(
        scheduler: TriggerSchedulerService,
        catalog: ScheduleTenancyStubCatalog
    ) -> ScheduledTaskToolDataService {
        ScheduledTaskToolDataService(scheduler: scheduler, catalog: catalog)
    }

    static func stampedTask(
        id: String = UUID().uuidString,
        ownerAccountID: UUID,
        createdByConversationID: UUID,
        conversationID: String? = nil
    ) -> ScheduledTask {
        ScheduledTask(
            id: id,
            schedule: ScheduledTaskSchedule(kind: .at, at: "2030-01-01T00:00:00Z"),
            payloadKind: .agentTurn,
            payloadText: "follow up",
            recurring: false,
            conversationID: conversationID,
            ownerAccountID: ownerAccountID,
            createdByConversationID: createdByConversationID
        )
    }
}

@Suite("ScheduledTaskToolDataService tenancy")
struct ScheduledTaskToolDataServiceTenancyTests {
    @Test("list returns only same-owner same-lineage tasks")
    func listFiltersByOwnerAndLineage() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sched-tenancy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let ownerA = UUID()
        let ownerB = UUID()
        let rootA = ScheduledTaskTenancyTestSupport.makeConversation(ownerAccountID: ownerA)
        let branchA = ScheduledTaskTenancyTestSupport.makeConversation(
            ownerAccountID: ownerA,
            parentConversationID: rootA.id,
            lineageKind: .branch
        )
        let unrelatedA = ScheduledTaskTenancyTestSupport.makeConversation(ownerAccountID: ownerA)
        let rootB = ScheduledTaskTenancyTestSupport.makeConversation(ownerAccountID: ownerB)
        let catalog = ScheduleTenancyStubCatalog(conversations: [
            rootA.id: rootA,
            branchA.id: branchA,
            unrelatedA.id: unrelatedA,
            rootB.id: rootB,
        ])
        let scheduler = ScheduledTaskTenancyTestSupport.makeScheduler(tmp: tmp)
        _ = try await scheduler.createTask(ScheduledTaskTenancyTestSupport.stampedTask(
            id: "task-root-a",
            ownerAccountID: ownerA,
            createdByConversationID: rootA.id
        ))
        _ = try await scheduler.createTask(ScheduledTaskTenancyTestSupport.stampedTask(
            id: "task-branch-a",
            ownerAccountID: ownerA,
            createdByConversationID: branchA.id
        ))
        _ = try await scheduler.createTask(ScheduledTaskTenancyTestSupport.stampedTask(
            id: "task-unrelated-a",
            ownerAccountID: ownerA,
            createdByConversationID: unrelatedA.id
        ))
        _ = try await scheduler.createTask(ScheduledTaskTenancyTestSupport.stampedTask(
            id: "task-root-b",
            ownerAccountID: ownerB,
            createdByConversationID: rootB.id
        ))
        _ = try await scheduler.createTask(ScheduledTask(
            id: "legacy-unstamped",
            schedule: ScheduledTaskSchedule(kind: .at, at: "2030-01-01T00:00:00Z"),
            payloadKind: .agentTurn,
            payloadText: "legacy",
            recurring: false
        ))
        let service = ScheduledTaskTenancyTestSupport.makeService(scheduler: scheduler, catalog: catalog)
        let scope = rootA.conversationScope()
        let listed = try await ConversationScope.withCurrent(scope) {
            try await service.listAccessibleTasks()
        }
        let ids = Set(listed.map(\.id))
        #expect(ids.contains("task-root-a"))
        #expect(ids.contains("task-branch-a"))
        #expect(!ids.contains("task-unrelated-a"))
        #expect(!ids.contains("task-root-b"))
        #expect(!ids.contains("legacy-unstamped"))
    }

    @Test("delete and fire_now deny foreign tasks")
    func mutateDeniesForeignTasks() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sched-mut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let ownerA = UUID()
        let ownerB = UUID()
        let convA = ScheduledTaskTenancyTestSupport.makeConversation(ownerAccountID: ownerA)
        let convB = ScheduledTaskTenancyTestSupport.makeConversation(ownerAccountID: ownerB)
        let catalog = ScheduleTenancyStubCatalog(conversations: [convA.id: convA, convB.id: convB])
        let scheduler = ScheduledTaskTenancyTestSupport.makeScheduler(tmp: tmp)
        _ = try await scheduler.createTask(ScheduledTaskTenancyTestSupport.stampedTask(
            id: "foreign-task",
            ownerAccountID: ownerB,
            createdByConversationID: convB.id
        ))
        let service = ScheduledTaskTenancyTestSupport.makeService(scheduler: scheduler, catalog: catalog)
        let scope = convA.conversationScope()
        let deleted = try await ConversationScope.withCurrent(scope) {
            try await service.deleteTask(id: "foreign-task")
        }
        #expect(deleted == false)
        await #expect(throws: ScheduledTaskAccessError.notFound) {
            try await ConversationScope.withCurrent(scope) {
                _ = try await service.fireNow(id: "foreign-task")
            }
        }
    }

    @Test("create rejects cross-owner target conversation")
    func createRejectsCrossOwnerTarget() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sched-create-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let ownerA = UUID()
        let ownerB = UUID()
        let convA = ScheduledTaskTenancyTestSupport.makeConversation(ownerAccountID: ownerA)
        let convB = ScheduledTaskTenancyTestSupport.makeConversation(ownerAccountID: ownerB)
        let catalog = ScheduleTenancyStubCatalog(conversations: [convA.id: convA, convB.id: convB])
        let scheduler = ScheduledTaskTenancyTestSupport.makeScheduler(tmp: tmp)
        let service = ScheduledTaskTenancyTestSupport.makeService(scheduler: scheduler, catalog: catalog)
        let task = ScheduledTask(
            schedule: ScheduledTaskSchedule(kind: .at, at: "2030-01-01T00:00:00Z"),
            payloadKind: .agentTurn,
            payloadText: "inject",
            recurring: false,
            conversationID: convB.id.uuidString
        )
        let scope = convA.conversationScope()
        await #expect(throws: ScheduledTaskAccessError.notFound) {
            try await ConversationScope.withCurrent(scope) {
                _ = try await service.createTask(task)
            }
        }
    }

    @Test("create defaults conversationID to caller and stamps origin")
    func createDefaultsToCaller() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sched-default-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let owner = UUID()
        let conv = ScheduledTaskTenancyTestSupport.makeConversation(ownerAccountID: owner)
        let catalog = ScheduleTenancyStubCatalog(conversations: [conv.id: conv])
        let scheduler = ScheduledTaskTenancyTestSupport.makeScheduler(tmp: tmp)
        let service = ScheduledTaskTenancyTestSupport.makeService(scheduler: scheduler, catalog: catalog)
        let task = ScheduledTask(
            schedule: ScheduledTaskSchedule(kind: .at, at: "2030-01-01T00:00:00Z"),
            payloadKind: .agentTurn,
            payloadText: "local",
            recurring: false
        )
        let scope = conv.conversationScope()
        let saved = try await ConversationScope.withCurrent(scope) {
            try await service.createTask(task)
        }
        #expect(saved.conversationID == conv.id.uuidString)
        #expect(saved.createdByConversationID == conv.id)
        #expect(saved.ownerAccountID == owner)
    }
}

private final class ScheduleTenancyStubCatalog: ConversationCatalogServicing, @unchecked Sendable {
    var conversations: [UUID: ModelConversation]

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

private final class ScheduleTenancyCaptureRuntime: TriggerRuntimeDispatching, @unchecked Sendable {
    func dispatchTriggerMessage(
        conversationID: UUID,
        text: String,
        systemReminder: String?,
        inputTrustRaw: String?,
        resolvedInputTrustClass: TrustPolicyClass?,
        enableTools: Bool,
        enableAgents: Bool,
        originSurface: String?,
        originSenderID: String?
    ) async throws {}
}

private struct ScheduleTenancyDedupe: TriggerDedupeChecking {
    func dedupePeek(key: String) async throws -> Bool { false }
    func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool { true }
}
