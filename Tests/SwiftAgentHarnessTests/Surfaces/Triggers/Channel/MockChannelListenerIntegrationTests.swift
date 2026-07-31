import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("MockChannelListenerIntegration")
struct MockChannelListenerIntegrationTests {
    final class CaptureRuntime: TriggerRuntimeDispatching, @unchecked Sendable {
        var texts: [String] = []
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
            texts.append(text)
        }
    }

    @Test("inject event reaches dispatch once")
    func injectDispatch() async throws {
        let dir = try tempDir()
        let runtime = CaptureRuntime()
        let dispatch = makeDispatch(runtime: runtime)
        let ingress = ChannelIngressAdapter(dispatch: dispatch)
        var config = ChannelListenerConfig(
            enabled: true,
            platformIdentity: "mock-bot",
            primaryUser: "U1",
            auth: ChannelAuthConfig(dmAllowFrom: ["U1"]),
            mention: ChannelMentionConfig(requireInGroups: false),
            debounce: ChannelDebounceConfig(textMs: 0)
        )
        config.enabled = true
        let bundle = try ChannelPluginFactory.build(channel: .slack, config: config, logger: Logger(label: "test"))
        let service = ChannelListenerService(
            channel: .slack,
            bundle: bundle,
            dataDirectory: dir,
            mediaRoot: dir.appendingPathComponent("media", isDirectory: true),
            ingress: ingress,
            dedupe: InMemoryTriggerDedupe(),
            logger: Logger(label: "test")
        )
        await service.start()
        let listener = await service.listenerInstance() as! MockChannelListener
        listener.injectRawEvent(
            MockChannelRawEvent(
                channel: .slack,
                platformMessageId: "m1",
                senderId: "U1",
                chatId: "C1",
                text: "from mock",
                type: .command,
                isDirect: true,
                isGroup: false,
                mentionsBot: false,
                isReplyToBot: false,
                internalEvent: false
            )
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        await service.stop()
        #expect(runtime.texts.count == 1)
        #expect(runtime.texts[0].contains("from mock"))
    }

    @Test("output router sends via plugin outbound")
    func outputRouter() async throws {
        let config = ChannelListenerConfig(platformIdentity: "mock")
        let logger = Logger(label: "test")
        let bundle = try ChannelPluginFactory.build(channel: .slack, config: config, logger: logger)
        let listener = bundle.listener as! MockChannelListener
        let plugin = bundle.plugin
        let router = TriggerOutputRouter()
        let trigger = HarnessTrigger(
            id: "slack:m1",
            source: .channel,
            sourceMetadata: ["chatId": "C1", "threadId": "T1", "platformMessageId": "m1"],
            payload: "hi",
            initiator: TriggerInitiator(kind: .external, id: "U1"),
            trust: .knownParty
        )
        let result = await router.routeResponse(trigger: trigger, responseText: "pong", plugin: plugin)
        if case .sent = result {
            #expect(Bool(true))
        } else {
            #expect(Bool(false))
        }
        #expect(listener.sentMessages.count == 1)
        #expect(listener.sentMessages[0].text == "pong")
    }

    private func makeDispatch(runtime: CaptureRuntime) -> TriggerDispatchService {
        let policy = TriggerActivationPolicy(
            idempotency: TriggerIdempotencyGate(dedupe: ChannelTestDedupe()),
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

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("channel-int-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

actor ChannelTestDedupe: TriggerDedupeChecking {
    func dedupePeek(key: String) async throws -> Bool { false }
    func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool { true }
}
