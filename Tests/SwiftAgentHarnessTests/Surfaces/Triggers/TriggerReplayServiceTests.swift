import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("TriggerReplayService")
struct TriggerReplayServiceTests {
    final class CaptureRuntime: TriggerRuntimeDispatching, @unchecked Sendable {
        var lastText: String?
        var lastTriggerID: String?
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
    ) async throws {
            lastText = text
        }
    }

    actor BlockingDedupe: TriggerDedupeChecking {
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

    @Test("replayFile ingests trigger from saved event file")
    func replayFile() async throws {
        let dir = try makeTempDir()
        let event = dir.appendingPathComponent("replay.json")
        try JSONEncoder().encode(FileEventPayload(type: .immediate, text: "replay me")).write(to: event)
        let trust = FileEventTrustSidecar(trust: .knownParty, source: "manual")
        try JSONEncoder().encode(trust).write(to: FileEventQueueLayout.trustSidecarURL(for: event))
        let runtime = CaptureRuntime()
        let dispatch = makeDispatch(runtime: runtime)
        let replay = TriggerReplayService(dispatch: dispatch, eventsDirectory: dir)
        let result = try await replay.replayFile(at: event)
        #expect(result.decision == .admitted)
        #expect(runtime.lastText?.contains("replay me") == true)
    }

    @Test("fresh replay ID bypasses dedupe for same source trigger")
    func freshIDBypassesDedupe() async throws {
        let runtime = CaptureRuntime()
        let dedupe = BlockingDedupe()
        let dispatch = makeDispatch(runtime: runtime, dedupe: dedupe)
        let replay = TriggerReplayService(dispatch: dispatch)
        let trigger = HarnessTrigger(
            id: "same-id",
            source: .webhook,
            payload: "x",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty
        )
        let first = try await replay.replay(trigger, freshID: false)
        let second = try await replay.replay(trigger, freshID: true)
        #expect(first.decision == .admitted)
        #expect(second.decision == .admitted)
    }

    @Test("replaySnapshot decodes HarnessTrigger JSON")
    func replaySnapshot() async throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("snap.json")
        let trigger = HarnessTrigger(
            id: "snap-1",
            source: .cron,
            payload: "cron body",
            initiator: TriggerInitiator(kind: .system),
            trust: .system
        )
        try JSONEncoder().encode(trigger).write(to: url)
        let runtime = CaptureRuntime()
        let replay = TriggerReplayService(dispatch: makeDispatch(runtime: runtime))
        let result = try await replay.replaySnapshot(at: url)
        #expect(result.decision == .admitted)
        #expect(runtime.lastText?.contains("cron body") == true)
    }

    @Test("dryRunPreview wraps unknown-party payload")
    func dryRunPreviewEnvelope() {
        let trigger = HarnessTrigger(
            id: "u1",
            source: .webhook,
            payload: "hostile",
            initiator: TriggerInitiator(kind: .external),
            trust: .unknownParty
        )
        let preview = TriggerReplayService(dispatch: makeDispatch(runtime: CaptureRuntime())).dryRunPreview(trigger: trigger)
        #expect(preview.prompt.userMessageBody.contains("EXTERNAL_UNTRUSTED_CONTENT"))
        #expect(preview.prompt.systemReminder?.contains("not actively present") == true)
    }

    @Test("fresh replay preserves workflow ids and links parent")
    func freshReplayLineage() {
        let trigger = HarnessTrigger(
            id: "original-id",
            source: .webhook,
            payload: "x",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty,
            correlation: .root(triggerID: "original-id")
        )
        let replayed = TriggerReplayService.freshReplayID(trigger)
        #expect(replayed.id.hasPrefix("replay:"))
        #expect(replayed.correlation?.rootId == "original-id")
        #expect(replayed.correlation?.correlationId == "original-id")
        #expect(replayed.correlation?.parentTriggerId == "original-id")
        #expect(replayed.correlation?.followUpKind == "replay")
    }

    private func makeDispatch(runtime: CaptureRuntime, dedupe: (any TriggerDedupeChecking)? = nil) -> TriggerDispatchService {
        let policy = TriggerActivationPolicy(
            idempotency: TriggerIdempotencyGate(dedupe: dedupe ?? ReplayDedupe()),
            rateLimit: TriggerRateLimitGate(maxPerWindow: 100),
            costCeiling: TriggerCostCeilingGate(maxPerWindow: 100),
            auditLog: TriggerAuditLog(logger: Logger(label: "test"))
        )
        let router = TriggerSessionRouter(sessionIndex: TriggerSessionIndex(createConversation: { _ in UUID() }))
        return TriggerDispatchService(
            activationPolicy: policy,
            sessionRouter: router,
            promptBuilder: TriggerPromptBuilder(),
            runtime: runtime
        )
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trigger-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

actor ReplayDedupe: TriggerDedupeChecking {
    func dedupePeek(key: String) async throws -> Bool { false }
    func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool { true }
}
