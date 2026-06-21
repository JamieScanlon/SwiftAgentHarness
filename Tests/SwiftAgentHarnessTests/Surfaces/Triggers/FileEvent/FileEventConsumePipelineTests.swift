import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("FileEventConsumePipeline")
struct FileEventConsumePipelineTests {
    final class CountingRuntime: TriggerRuntimeDispatching, @unchecked Sendable {
        var count = 0
        func dispatchTriggerMessage(
            conversationID: UUID,
            text: String,
            systemReminder: String?,
            inputTrustRaw: String?,
            enableTools: Bool,
            enableAgents: Bool,
        originSurface: String?,
        originSenderID: String?
    ) async throws {
            count += 1
        }
    }

    final class TrustCaptureRuntime: TriggerRuntimeDispatching, @unchecked Sendable {
        var lastTrust: String?
        func dispatchTriggerMessage(
            conversationID: UUID,
            text: String,
            systemReminder: String?,
            inputTrustRaw: String?,
            enableTools: Bool,
            enableAgents: Bool,
        originSurface: String?,
        originSenderID: String?
    ) async throws {
            lastTrust = inputTrustRaw
        }
    }

    @Test("immediate event is consumed and deleted")
    func immediateDelete() async throws {
        let dir = try makeTempDir()
        let event = dir.appendingPathComponent("now.json")
        try JSONEncoder().encode(FileEventPayload(type: .immediate, text: "go")).write(to: event)
        let runtime = CountingRuntime()
        let pipeline = makePipeline(dir: dir, runtime: runtime)
        await pipeline.consume(eventURL: event)
        #expect(runtime.count == 1)
        #expect(!FileManager.default.fileExists(atPath: event.path))
        let processingNames = try processingNames(dir)
        #expect(processingNames.isEmpty)
    }

    @Test("periodic source file is kept")
    func periodicKept() async throws {
        let dir = try makeTempDir()
        let event = dir.appendingPathComponent("cron.json")
        try JSONEncoder().encode(FileEventPayload(type: .periodic, text: "tick", schedule: "0 * * * *")).write(to: event)
        let runtime = CountingRuntime()
        let pipeline = makePipeline(dir: dir, runtime: runtime)
        await pipeline.consume(eventURL: event)
        #expect(runtime.count == 0)
        #expect(FileManager.default.fileExists(atPath: event.path))
    }

    @Test("staged trust sidecar resolves known-party and is cleaned up")
    func stagedTrustSidecar() async throws {
        let dir = try makeTempDir()
        let event = dir.appendingPathComponent("trusted.json")
        try JSONEncoder().encode(FileEventPayload(type: .immediate, text: "go")).write(to: event)
        let sidecar = FileEventTrustSidecar(trust: .knownParty, source: "webhook")
        try JSONEncoder().encode(sidecar).write(to: FileEventQueueLayout.trustSidecarURL(for: event))
        let runtime = TrustCaptureRuntime()
        let pipeline = makePipeline(dir: dir, runtime: runtime)
        await pipeline.consume(eventURL: event)
        #expect(runtime.lastTrust == CommEnvelopeOriginTrust.knownParty.rawValue)
        #expect(!FileManager.default.fileExists(atPath: event.path))
        #expect(!FileManager.default.fileExists(atPath: FileEventQueueLayout.trustSidecarURL(for: event).path))
        let processingNames = try processingNames(dir)
        #expect(processingNames.isEmpty)
    }

    private func makePipeline(dir: URL, runtime: some TriggerRuntimeDispatching) -> FileEventConsumePipeline {
        let dispatch = makeDispatch(runtime: runtime)
        return FileEventConsumePipeline(
            eventsDirectory: dir,
            parser: FileEventPayloadParser(logger: Logger(label: "test"), backoffMilliseconds: [1], sleep: { _ in }),
            ingress: FileEventIngressAdapter(),
            dispatch: dispatch,
            logger: Logger(label: "test")
        )
    }

    private func makeDispatch(runtime: some TriggerRuntimeDispatching) -> TriggerDispatchService {
        let policy = TriggerActivationPolicy(
            idempotency: TriggerIdempotencyGate(dedupe: AlwaysNewDedupe()),
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

    private func processingNames(_ dir: URL) throws -> [String] {
        let url = FileEventQueueLayout.processingDirectory(eventsDirectory: dir)
        return try FileManager.default.contentsOfDirectory(atPath: url.path)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("file-event-consume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

actor AlwaysNewDedupe: TriggerDedupeChecking {
    func dedupePeek(key: String) async throws -> Bool { false }
    func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool { true }
}
