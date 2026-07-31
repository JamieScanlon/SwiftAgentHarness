import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("Run lane trigger admission integration")
struct RunLaneTriggerAdmissionIntegrationTests {
    final class LaneAdmissionRuntime: TriggerRuntimeDispatching, @unchecked Sendable {
        let coordinator: RuntimeLaneCoordinator
        private var dispatchOrdinal = 0
        private(set) var admittedRunIDs: [UUID] = []
        private(set) var lastAdmissionError: RuntimeLaneAdmissionError?

        init(coordinator: RuntimeLaneCoordinator) {
            self.coordinator = coordinator
        }

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
            dispatchOrdinal += 1
            let runID = UUID()
            let origin = RunLaneResolver.runLaneOrigin(originSurface: originSurface)
            let context = RunLaneResolver.resolve(
                RunLaneOriginContext(
                    sessionKey: "trigger:\(dispatchOrdinal)",
                    runID: runID,
                    origin: origin
                )
            )
            if let admission = await coordinator.tryAcquire(context) {
                lastAdmissionError = admission
                throw admission
            }
            admittedRunIDs.append(runID)
        }

        func tryAcquireInteractive(conversationID: UUID) async -> RuntimeLaneAdmissionError? {
            let runID = UUID()
            let context = RunLaneResolver.resolve(
                RunLaneOriginContext(
                    sessionKey: "interactive:\(conversationID.uuidString.lowercased())",
                    runID: runID,
                    origin: .interactive
                )
            )
            return await coordinator.tryAcquire(context)
        }
    }

    actor LocalDedupe: TriggerDedupeChecking {
        private var keys: Set<String> = []
        func dedupePeek(key: String) async throws -> Bool { keys.contains(key) }
        func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool {
            if keys.contains(key) { return false }
            keys.insert(key)
            return true
        }
    }

    private func makeDispatch(runtime: LaneAdmissionRuntime, conversationID: UUID) -> TriggerDispatchService {
        let audit = TriggerAuditLog(logger: Logger(label: "test"))
        let policy = TriggerActivationPolicy(
            idempotency: TriggerIdempotencyGate(dedupe: LocalDedupe()),
            rateLimit: TriggerRateLimitGate(maxPerWindow: 100),
            costCeiling: TriggerCostCeilingGate(maxPerWindow: 100),
            auditLog: audit
        )
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

    private func cronTrigger(id: String) -> HarnessTrigger {
        HarnessTrigger(
            id: id,
            source: .cron,
            sourceMetadata: [:],
            receivedAt: 1,
            payload: "cron tick",
            payloadFormat: .text,
            initiator: TriggerInitiator(kind: .system),
            trust: .system,
            enableTools: true,
            enableAgents: true
        )
    }

    @Test("cron trigger ingest fills cron lane while interactive send still acquires main lane")
    func cronTriggerFillsCronLaneInteractiveUsesMain() async throws {
        let coordinator = RuntimeLaneCoordinator(
            configuration: RuntimeLaneConfiguration(
                sessionMaxConcurrentRuns: 1,
                globalMainLaneLimit: 1,
                globalSubagentLaneLimit: 8,
                globalCronLaneLimit: 1,
                maxChildrenPerAgent: 5
            )
        )
        let runtime = LaneAdmissionRuntime(coordinator: coordinator)
        let conversationID = UUID()
        let dispatch = makeDispatch(runtime: runtime, conversationID: conversationID)

        let first = try await dispatch.ingest(cronTrigger(id: "cron-1"))
        #expect(first.decision == .admitted)
        #expect(runtime.admittedRunIDs.count == 1)

        await #expect(throws: RuntimeLaneAdmissionError.self) {
            _ = try await dispatch.ingest(cronTrigger(id: "cron-2"))
        }
        #expect(runtime.lastAdmissionError == .globalCronLaneAtCapacity(limit: 1))
        #expect(runtime.admittedRunIDs.count == 1)

        let interactiveAdmission = await runtime.tryAcquireInteractive(conversationID: UUID())
        #expect(interactiveAdmission == nil)
    }
}
