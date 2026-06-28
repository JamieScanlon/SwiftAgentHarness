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
        let store = ScheduledTaskStore(fileURL: tmp.appendingPathComponent("tasks.json"))
        let dispatch = makeDispatch()
        let scheduler = TriggerSchedulerService(
            store: store,
            dispatch: dispatch,
            lockURL: tmp.appendingPathComponent("lock.json"),
            logger: Logger(label: "test")
        )
        let hostTrigger = HarnessTrigger(
            id: "webhook-delivery-1",
            source: .webhook,
            payload: "incoming",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty,
            correlation: .root(triggerID: "webhook-delivery-1")
        )
        let provider = ScheduleToolProvider(
            scheduler: scheduler,
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
        let result = try await provider.executeTool(toolCall)
        #expect(result.success == true)
        let tasks = try await scheduler.listTasks()
        #expect(tasks.count == 1)
        let correlation = try #require(tasks[0].correlation)
        #expect(correlation.rootId == "webhook-delivery-1")
        #expect(correlation.correlationId == "webhook-delivery-1")
        #expect(correlation.parentTriggerId == "webhook-delivery-1")
        #expect(correlation.followUpKind == "scheduled")
    }

    @Test("explicit correlation overrides host inherit")
    func explicitOverridesHost() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("schedule-corr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = ScheduledTaskStore(fileURL: tmp.appendingPathComponent("tasks.json"))
        let dispatch = makeDispatch()
        let scheduler = TriggerSchedulerService(
            store: store,
            dispatch: dispatch,
            lockURL: tmp.appendingPathComponent("lock.json"),
            logger: Logger(label: "test")
        )
        let hostTrigger = HarnessTrigger(
            id: "webhook-delivery-1",
            source: .webhook,
            payload: "incoming",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty,
            correlation: .root(triggerID: "webhook-delivery-1")
        )
        let provider = ScheduleToolProvider(
            scheduler: scheduler,
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
        _ = try await provider.executeTool(toolCall)
        let tasks = try await scheduler.listTasks()
        let correlation = try #require(tasks[0].correlation)
        #expect(correlation.rootId == "custom-root")
        #expect(correlation.parentTriggerId == "custom-parent")
        #expect(correlation.correlationId == "custom-workflow")
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

private final class ScheduleToolCaptureRuntime: TriggerRuntimeDispatching, @unchecked Sendable {
    func dispatchTriggerMessage(
        conversationID: UUID,
        text: String,
        systemReminder: String?,
        inputTrustRaw: String?,
        enableTools: Bool,
        enableAgents: Bool,
        originSurface: String?,
        originSenderID: String?
    ) async throws {}
}

private struct ScheduleToolDedupe: TriggerDedupeChecking {
    func dedupePeek(key: String) async throws -> Bool { false }
    func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool { true }
}
