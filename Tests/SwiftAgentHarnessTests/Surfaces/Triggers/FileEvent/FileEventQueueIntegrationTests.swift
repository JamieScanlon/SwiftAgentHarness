import CryptoKit
import Foundation
import Logging
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("FileEventQueueIntegration")
struct FileEventQueueIntegrationTests {
    actor CaptureRuntime: TriggerRuntimeDispatching {
        private(set) var texts: [String] = []

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
            texts.append(text)
        }
    }

    @Test("file drop reaches dispatch once")
    func fileDropDispatch() async throws {
        let dir = try makeTempDir()
        let runtime = CaptureRuntime()
        let bundle = makeBundle(eventsDir: dir, runtime: runtime)
        await bundle.fileEventQueue.start()
        let event = dir.appendingPathComponent("drop.json")
        try JSONEncoder().encode(FileEventPayload(type: .immediate, text: "from file")).write(to: event)
        guard try await waitUntil(timeoutNanoseconds: 10_000_000_000, condition: { await runtime.texts.count == 1 }) else {
            Issue.record("timed out waiting for file-event dispatch")
            return
        }
        await bundle.fileEventQueue.stop()
        let texts = await runtime.texts
        #expect(texts.count == 1)
        #expect(texts[0].contains("from file"))
    }

    @Test("webhook queue-only writes without dispatch")
    func webhookQueueOnly() async throws {
        let dir = try makeTempDir()
        let runtime = CaptureRuntime()
        let bundle = makeBundle(eventsDir: dir, runtime: runtime)
        let route = WebhookRoute(name: "test", secret: "s", promptTemplate: "hi {name}", trust: .knownParty)
        let store = WebhookRouteStore(staticRoutes: [route], dynamicStore: WebhookDynamicRouteStore(fileURL: dir.appendingPathComponent("subs.json")))
        let idempotency = TriggerIdempotencyGate(dedupe: AlwaysPassIdempotency())
        let channelRegistry = ChannelListenerRegistry.load(
            dataDirectory: dir,
            ingress: ChannelIngressAdapter(dispatch: bundle.dispatch),
            dedupe: ReplayHarnessDedupe(),
            logger: Logger(label: "test"),
            enabled: false,
            configURL: nil
        )
        let adapter = WebhookIngressAdapter(
            validationGate: WebhookValidationGate(
                routeStore: store,
                idempotency: idempotency,
                rateLimit: TriggerRateLimitGate(maxPerWindow: 100)
            ),
            dispatch: bundle.dispatch,
            directDelivery: WebhookDirectDelivery(channelRegistry: channelRegistry),
            idempotency: idempotency,
            eventsDirectory: dir
        )
        let body = try JSONSerialization.data(withJSONObject: ["name": "world"])
        let sig = hmacHex(data: body, secret: "s")
        let result = try await adapter.ingest(
            WebhookIngressRequest(routeName: "test", body: body, headers: ["X-Webhook-Signature": sig], deliveryID: "delivery-1")
        )
        #expect(result.decision == TriggerActivationDecision.admitted)
        #expect(await runtime.texts.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("delivery-1.json").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("delivery-1.trust").path))
    }

    private func makeBundle(eventsDir: URL, runtime: CaptureRuntime) -> TriggersRuntimeBundle {
        let dataDir = eventsDir.appendingPathComponent(".swiftAgentHarness", isDirectory: true)
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let dispatch = makeDispatch(runtime: runtime)
        let taskStore = ScheduledTaskStore(fileURL: dataDir.appendingPathComponent("tasks.json"))
        let sessionStore = SessionScopedScheduledTaskStore()
        let registration = TriggerRegistrationTestSupport.service(store: taskStore, sessionStore: sessionStore)
        let scheduler = TriggerSchedulerService(
            store: taskStore,
            sessionStore: sessionStore,
            dispatch: dispatch,
            lockURL: dataDir.appendingPathComponent("lock"),
            logger: Logger(label: "test")
        )
        let idempotency = TriggerIdempotencyGate(dedupe: AlwaysPassIdempotency())
        let channelRegistry = ChannelListenerRegistry.load(
            dataDirectory: dataDir,
            ingress: ChannelIngressAdapter(dispatch: dispatch),
            dedupe: ReplayHarnessDedupe(),
            logger: Logger(label: "test"),
            enabled: false,
            configURL: nil
        )
        let directDelivery = WebhookDirectDelivery(channelRegistry: channelRegistry)
        let webhookAdapter = WebhookIngressAdapter(
            validationGate: WebhookValidationGate(
                routeStore: WebhookRouteStore(staticRoutes: [], dynamicStore: WebhookDynamicRouteStore(fileURL: dataDir.appendingPathComponent("subs.json"))),
                idempotency: idempotency,
                rateLimit: TriggerRateLimitGate(maxPerWindow: 100)
            ),
            dispatch: dispatch,
            directDelivery: directDelivery,
            idempotency: idempotency,
            eventsDirectory: eventsDir
        )
        let fileEventQueue = FileEventQueueService(
            eventsDirectory: eventsDir,
            dispatch: dispatch,
            registration: registration,
            logger: Logger(label: "test"),
            debounceMilliseconds: 10,
            watcherRetryDelayMilliseconds: 100
        )
        let auditLog = TriggerAuditLog(logger: Logger(label: "test"))
        let outputRouter = TriggerSymmetricOutputRouter(
            channelRegistry: channelRegistry,
            auditLog: auditLog,
            logger: Logger(label: "test")
        )
        let runRegistry = TriggerDelegatedRunRegistry()
        let channelSessionLifecycleCoordinator = ChannelSessionLifecycleCoordinator()
        let handoff = TriggerDelegatedCompletionHandoff(
            runRegistry: runRegistry,
            outputRouter: outputRouter,
            resolveParentConversation: { _ in nil },
            lastAssistantText: { _ in nil }
        )
        return TriggersRuntimeBundle(
            dispatch: dispatch,
            registration: registration,
            scheduler: scheduler,
            webhookAdapter: webhookAdapter,
            webhookRouteStore: WebhookRouteStore(
                staticRoutes: [],
                dynamicStore: WebhookDynamicRouteStore(fileURL: dataDir.appendingPathComponent("subs.json"))
            ),
            scheduleTools: ScheduleToolProvider(
                dataService: ScheduledTaskToolDataService(
                    scheduler: scheduler,
                    registration: registration,
                    catalog: FileEventStubCatalog()
                )
            ),
            webhookTools: WebhookToolProvider(
                dataService: ScheduledTaskToolDataService(
                    scheduler: scheduler,
                    registration: registration,
                    catalog: FileEventStubCatalog()
                )
            ),
            fileEventQueue: fileEventQueue,
            replay: TriggerReplayService(dispatch: dispatch, eventsDirectory: eventsDir),
            channelRegistry: channelRegistry,
            channelSessionLifecycleCoordinator: channelSessionLifecycleCoordinator,
            outputRouter: outputRouter,
            delegatedCompletionHandoff: handoff,
            runRegistry: runRegistry
        )
    }

    private func makeDispatch(runtime: CaptureRuntime) -> TriggerDispatchService {
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

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("file-event-int-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 3_000_000_000,
        pollNanoseconds: UInt64 = 25_000_000,
        condition: @escaping () async -> Bool
    ) async throws -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() { return true }
            try await Task.sleep(nanoseconds: pollNanoseconds)
        }
        return false
    }

    private func hmacHex(data: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

actor AlwaysPassIdempotency: TriggerDedupeChecking {
    func dedupePeek(key: String) async throws -> Bool { false }
    func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool { true }
}

private final class FileEventStubCatalog: ConversationCatalogServicing, @unchecked Sendable {
    func listConversationInfo() async -> [ModelConversation] { [] }
    func listConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] { [] }
    func getConversation(id: UUID) async -> ModelConversation? { nil }
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
