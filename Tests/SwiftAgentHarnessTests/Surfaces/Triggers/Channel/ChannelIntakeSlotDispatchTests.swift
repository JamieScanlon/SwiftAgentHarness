import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

private struct DenyAllChannelSecurityAdapter: ChannelSecurityAdapting {
    func isAllowed(event: ChannelMessageEvent, config: ChannelListenerConfig) -> Bool { false }

    func makeMentionGate(config: ChannelMentionConfig) -> ChannelMentionGate {
        ChannelMentionGate(config: config)
    }

    func classifyTrust(
        event: ChannelMessageEvent,
        config: ChannelListenerConfig,
        effectiveWasMentioned: Bool
    ) -> CommEnvelopeOriginTrust {
        .unknownParty
    }

    func redactLogIdentifier(_ value: String) -> String { "***" }
}

private struct CustomSessionGrammarAdapter: ChannelSessionGrammarAdapting {
    func resolveDedupSessionKey(event: ChannelMessageEvent, config: ChannelListenerConfig) -> String {
        "custom-dedup-key"
    }

    func resolveSessionConversation(raw: ChannelSessionRawIdentity) -> ChannelSessionConversationResolution {
        ChannelSessionConversationResolution(
            baseConversationKey: "custom-session-key",
            threadId: raw.threadId,
            parentFallbackCandidates: ["custom-parent"]
        )
    }
}

@Suite("ChannelIntakeSlotDispatch")
struct ChannelIntakeSlotDispatchTests {
    @Test("custom security slot denies inbound events")
    func customSecurityDenies() async {
        let emitted = SlotDispatchCounterBox()
        let config = ChannelListenerConfig(
            primaryUser: "U1",
            auth: ChannelAuthConfig(dmAllowFrom: ["U1"]),
            mention: ChannelMentionConfig(requireInGroups: false),
            debounce: ChannelDebounceConfig(textMs: 0)
        )
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("channel-slot-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pipeline = ChannelIntakePipeline(
            channel: .slack,
            config: config,
            security: DenyAllChannelSecurityAdapter(),
            sessionGrammar: ChannelSessionGrammar(),
            mediaRoot: dir,
            dedup: ChannelMessageDedup(dedupe: InMemoryTriggerDedupe(), ttlSeconds: config.dedupe.ttlSeconds),
            logger: Logger(label: "test"),
            emitTrigger: { _ in await emitted.increment() }
        )
        await pipeline.process(event: sampleEvent(senderId: "U1", id: "allowed-by-default"))
        let counters = await pipeline.counters
        #expect(counters.authDenied == 1)
        #expect(counters.emitted == 0)
        #expect(await emitted.value == 0)
    }

    @Test("custom session grammar slot stamps trigger metadata")
    func customSessionGrammarStampsMetadata() async throws {
        let capture = TriggerCaptureBox()
        let config = ChannelListenerConfig(
            primaryUser: "U1",
            auth: ChannelAuthConfig(dmAllowFrom: ["U1"]),
            mention: ChannelMentionConfig(requireInGroups: false),
            debounce: ChannelDebounceConfig(textMs: 0)
        )
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("channel-slot-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pipeline = ChannelIntakePipeline(
            channel: .slack,
            config: config,
            security: DefaultChannelSecurityAdapter(config: config),
            sessionGrammar: CustomSessionGrammarAdapter(),
            mediaRoot: dir,
            dedup: ChannelMessageDedup(dedupe: InMemoryTriggerDedupe(), ttlSeconds: config.dedupe.ttlSeconds),
            logger: Logger(label: "test"),
            emitTrigger: { trigger in await capture.store(trigger) }
        )
        await pipeline.process(event: sampleEvent(senderId: "U1", id: "grammar-1"))
        let trigger = try #require(await capture.trigger)
        #expect(trigger.sourceMetadata["sessionKeyOverride"] == "custom-session-key")
        #expect(trigger.sourceMetadata["parentFallbackCandidates"] == "custom-parent")
    }

    @Test("registry-built listener service routes through plugin slots")
    func registryBuiltServiceUsesPluginSlots() async throws {
        let dir = try tempDir()
        let snapshotStore = TriggerSnapshotStore(dataDirectory: dir)
        let ingress = makeIngress(snapshotStore: snapshotStore)
        let config = ChannelListenerConfig(
            enabled: true,
            transport: .mock,
            platformIdentity: "mock-bot",
            primaryUser: "U1",
            auth: ChannelAuthConfig(dmAllowFrom: ["U1"]),
            mention: ChannelMentionConfig(requireInGroups: false),
            debounce: ChannelDebounceConfig(textMs: 0)
        )
        let registry = ChannelListenerRegistry(
            dataDirectory: dir,
            ingress: ingress,
            dedupe: SlotDispatchDedupe(),
            logger: Logger(label: "test"),
            enabled: true,
            channelsFile: ChannelsFile(channels: ["slack": config])
        )
        await registry.start()
        let listener = try #require(await registry.listener(for: .slack) as? MockChannelListener)
        listener.injectRawEvent(
            MockChannelRawEvent(
                channel: .slack,
                platformMessageId: "registry-m1",
                senderId: "U1",
                chatId: "C1",
                text: "registry path",
                type: .command,
                isDirect: true,
                isGroup: false,
                mentionsBot: false,
                isReplyToBot: false,
                internalEvent: false
            )
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        await registry.stop()
        let trigger = try snapshotStore.load(triggerID: "slack:registry-m1")
        #expect(trigger.payload.contains("registry path"))
        #expect(trigger.sourceMetadata["sessionKeyOverride"] != nil)
    }

    private func sampleEvent(senderId: String, id: String) -> ChannelMessageEvent {
        ChannelMessageEvent(
            channel: .slack,
            platformMessageId: id,
            senderId: senderId,
            chatId: "C1",
            receivedAt: Int64(Date().timeIntervalSince1970 * 1000),
            type: .command,
            text: "hi",
            attachments: [],
            isReplyToBot: false,
            hasMention: true,
            mentionsBot: true,
            isDirect: true,
            isGroup: false,
            chatTypeRaw: "dm",
            internalEvent: false
        )
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("channel-slot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeIngress(snapshotStore: TriggerSnapshotStore) -> ChannelIngressAdapter {
        let policy = TriggerActivationPolicy(
            idempotency: TriggerIdempotencyGate(dedupe: SlotDispatchDedupe()),
            rateLimit: TriggerRateLimitGate(maxPerWindow: 100),
            initiatorBurst: TriggerInitiatorBurstGate(maxPerWindow: 100),
            auditLog: TriggerAuditLog(logger: Logger(label: "test"))
        )
        let router = TriggerSessionRouter(sessionIndex: TriggerSessionIndex(createConversation: { _ in UUID() }))
        let dispatch = TriggerDispatchService(
            activationPolicy: policy,
            sessionRouter: router,
            promptBuilder: TriggerPromptBuilder(),
            runtime: SlotDispatchNoopRuntime(),
            snapshotStore: snapshotStore
        )
        return ChannelIngressAdapter(dispatch: dispatch)
    }
}

private actor TriggerCaptureBox {
    private(set) var trigger: HarnessTrigger?

    func store(_ trigger: HarnessTrigger) {
        self.trigger = trigger
    }
}

private struct SlotDispatchNoopRuntime: TriggerRuntimeDispatching {
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

private actor SlotDispatchCounterBox {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor SlotDispatchDedupe: TriggerDedupeChecking {
    func dedupePeek(key: String) async throws -> Bool { false }
    func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool { true }
}
