import EasyJSON
import Foundation
import Logging
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("schedule_create relative delay")
struct ScheduleCreateRelativeDelayTests {
    @Test("delayMs fills an at timestamp without inventing ISO locally")
    func delayMsFillsAt() async throws {
        let before = Date()
        let task = try await createTask(arguments: [
            "scheduleKind": .string("at"),
            "delayMs": .integer(300_000),
            "payloadKind": .string("agentTurn"),
            "payloadText": .string("follow up"),
            "recurring": .boolean(false),
        ])
        let after = Date()
        let at = try #require(task.schedule.at)
        let fireAt = try #require(ISO8601DateFormatter().date(from: at))
        #expect(task.schedule.kind == .at)
        #expect(fireAt.timeIntervalSince(before) >= 300 - 2)
        #expect(fireAt.timeIntervalSince(after) <= 300 + 2)
    }

    @Test("inSeconds fills an at timestamp")
    func inSecondsFillsAt() async throws {
        let before = Date()
        let task = try await createTask(arguments: [
            "scheduleKind": .string("at"),
            "inSeconds": .integer(120),
            "payloadKind": .string("agentTurn"),
            "payloadText": .string("follow up"),
            "recurring": .boolean(false),
        ])
        let after = Date()
        let at = try #require(task.schedule.at)
        let fireAt = try #require(ISO8601DateFormatter().date(from: at))
        #expect(fireAt.timeIntervalSince(before) >= 120 - 2)
        #expect(fireAt.timeIntervalSince(after) <= 120 + 2)
    }

    @Test("explicit at wins over delayMs")
    func explicitAtWins() async throws {
        let task = try await createTask(arguments: [
            "scheduleKind": .string("at"),
            "at": .string("2030-01-01T00:00:00Z"),
            "delayMs": .integer(1_000),
            "payloadKind": .string("agentTurn"),
            "payloadText": .string("follow up"),
            "recurring": .boolean(false),
        ])
        #expect(task.schedule.at == "2030-01-01T00:00:00Z")
    }

    @Test("delayMs wins over inSeconds")
    func delayMsWinsOverInSeconds() async throws {
        let before = Date()
        let task = try await createTask(arguments: [
            "scheduleKind": .string("at"),
            "delayMs": .integer(60_000),
            "inSeconds": .integer(10),
            "payloadKind": .string("agentTurn"),
            "payloadText": .string("follow up"),
            "recurring": .boolean(false),
        ])
        let after = Date()
        let at = try #require(task.schedule.at)
        let fireAt = try #require(ISO8601DateFormatter().date(from: at))
        #expect(fireAt.timeIntervalSince(before) >= 60 - 2)
        #expect(fireAt.timeIntervalSince(after) <= 60 + 2)
    }

    @Test("/schedule create --in maps onto inSeconds")
    func slashInMapsToInSeconds() throws {
        let mapped = TriggerToolArgumentBridge.scheduleCall(from: .object([
            "commandName": .string("schedule"),
            "args": .string("create --in 300 remind me"),
        ]))
        let call = try #require(mapped)
        #expect(call.toolName == ToolControlPlaneClassification.TriggerTools.scheduleCreate)
        #expect(stringField(call.arguments, "scheduleKind") == "at")
        #expect(numberField(call.arguments, "inSeconds") == 300)
        #expect(stringField(call.arguments, "payloadText") == "remind me")
        #expect(boolField(call.arguments, "recurring") == false)
    }

    private func stringField(_ json: JSON, _ key: String) -> String? {
        guard case .object(let dict) = json, case .string(let value) = dict[key] else { return nil }
        return value
    }

    private func numberField(_ json: JSON, _ key: String) -> Double? {
        guard case .object(let dict) = json, let value = dict[key] else { return nil }
        switch value {
        case .double(let double): return double
        case .integer(let integer): return Double(integer)
        default: return nil
        }
    }

    private func boolField(_ json: JSON, _ key: String) -> Bool? {
        guard case .object(let dict) = json, case .boolean(let value) = dict[key] else { return nil }
        return value
    }

    private func createTask(arguments: [String: JSON]) async throws -> ScheduledTask {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "schedule-delay-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let conv = makeConversation()
        let catalog = DelayStubCatalog(conversations: [conv.id: conv])
        let store = ScheduledTaskStore(fileURL: tmp.appendingPathComponent("tasks.json"))
        let sessionStore = SessionScopedScheduledTaskStore()
        let scheduler = TriggerSchedulerService(
            store: store,
            sessionStore: sessionStore,
            dispatch: makeDispatch(),
            lockURL: tmp.appendingPathComponent("lock.json"),
            logger: Logger(label: "test")
        )
        let provider = ScheduleToolProvider(
            dataService: ScheduledTaskToolDataService(
                scheduler: scheduler,
                registration: TriggerRegistrationTestSupport.service(store: store, sessionStore: sessionStore),
                catalog: catalog
            )
        )
        let result = try await ConversationScope.withCurrent(conv.conversationScope()) {
            try await provider.executeTool(
                ToolCall(name: "schedule_create", arguments: .object(arguments), id: "call-delay")
            )
        }
        #expect(result.success)
        let tasks = try await scheduler.listTasks()
        return try #require(tasks.first)
    }

    private func makeConversation() -> ModelConversation {
        let now = Date()
        return ModelConversation(
            id: UUID(),
            model: Model(
                id: UUID(),
                protocol: .openAIAPI,
                modelName: "delay-test",
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
            ownerAccountID: nil,
            lineageKind: .root,
            origin: .user
        )
    }

    private func makeDispatch() -> TriggerDispatchService {
        let policy = TriggerActivationPolicy(
            idempotency: TriggerIdempotencyGate(dedupe: DelayDedupe()),
            rateLimit: TriggerRateLimitGate(maxPerWindow: 100),
            initiatorBurst: TriggerInitiatorBurstGate(maxPerWindow: 100),
            auditLog: TriggerAuditLog(logger: Logger(label: "test"))
        )
        return TriggerDispatchService(
            activationPolicy: policy,
            sessionRouter: TriggerSessionRouter(sessionIndex: TriggerSessionIndex(createConversation: { _ in UUID() })),
            promptBuilder: TriggerPromptBuilder(),
            runtime: DelayNoopRuntime()
        )
    }
}

private final class DelayStubCatalog: ConversationCatalogServicing, @unchecked Sendable {
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

private struct DelayNoopRuntime: TriggerRuntimeDispatching {
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

private struct DelayDedupe: TriggerDedupeChecking {
    func dedupePeek(key: String) async throws -> Bool { false }
    func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool { true }
}
