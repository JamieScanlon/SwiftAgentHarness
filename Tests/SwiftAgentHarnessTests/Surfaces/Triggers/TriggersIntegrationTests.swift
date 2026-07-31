import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("TriggersIntegration")
struct TriggersIntegrationTests {
    final class CaptureRuntime: TriggerRuntimeDispatching, @unchecked Sendable {
        var conversationIDs: [UUID] = []
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
    ) async throws {
            conversationIDs.append(conversationID)
        }
    }

    actor LocalDedupe: TriggerDedupeChecking {
        private var keys: Set<String> = []
        func dedupePeek(key: String) async throws -> Bool {
            keys.contains(key)
        }
        func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool {
            if keys.contains(key) { return false }
            keys.insert(key)
            return true
        }
    }

    @Test("scheduler fire now reaches runtime dispatch")
    func schedulerFireNow() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("triggers-int-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let runtime = CaptureRuntime()
        let dispatch = makeDispatch(runtime: runtime)
        let store = ScheduledTaskStore(fileURL: tmp.appendingPathComponent("tasks.json"))
        let scheduler = TriggerSchedulerService(
            store: store,
            dispatch: dispatch,
            lockURL: tmp.appendingPathComponent("lock.json"),
            logger: Logger(label: "test")
        )
        let task = try TriggerRegistrationTestSupport.service(store: store).registerSchedule(
            ScheduleRegistrationSpec(
                schedule: ScheduledTaskSchedule(kind: .at, at: "2030-01-01T00:00:00Z"),
                payloadKind: .agentTurn,
                payloadText: "integration cron prompt",
                recurring: false
            ),
            authority: .localFileDrop()
        )
        let result = try await scheduler.fireNow(id: task.id)
        #expect(result.decision == .admitted)
        #expect(runtime.conversationIDs.count == 1)
    }

    @Test("webhook template renders and validates")
    func webhookTemplate() async throws {
        let rendered = WebhookPromptTemplate.render(
            template: "PR: {pull_request.title}",
            payload: ["pull_request": ["title": "Fix bug"]]
        )
        #expect(rendered == "PR: Fix bug")
    }

    private func makeDispatch(runtime: CaptureRuntime) -> TriggerDispatchService {
        let audit = TriggerAuditLog(logger: Logger(label: "test"))
        let policy = TriggerActivationPolicy(
            idempotency: TriggerIdempotencyGate(dedupe: LocalDedupe()),
            rateLimit: TriggerRateLimitGate(maxPerWindow: 100),
            costCeiling: TriggerCostCeilingGate(maxPerWindow: 100),
            auditLog: audit
        )
        let conversationID = UUID()
        let router = TriggerSessionRouter(
            sessionIndex: TriggerSessionIndex(createConversation: { _ in conversationID })
        )
        return TriggerDispatchService(
            activationPolicy: policy,
            sessionRouter: router,
            promptBuilder: TriggerPromptBuilder(),
            runtime: runtime
        )
    }
}
