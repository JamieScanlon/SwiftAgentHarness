import Foundation
import Logging
import os
import Testing
@testable import SwiftAgentHarness

@Suite("ChannelPluginFactory build")
struct ChannelPluginFactoryBuildTests {
    @Test("mock transport returns plugin listener and working parser")
    func mockBuild() throws {
        let config = ChannelListenerConfig(enabled: true, transport: .mock, platformIdentity: "mock-bot")
        let logger = Logger(label: "test")
        let bundle = try ChannelPluginFactory.build(channel: .slack, config: config, logger: logger)
        #expect(bundle.plugin.id == .slack)
        #expect(bundle.listener.id == .slack)
        let raw = ChannelTransportRawEvent(
            channel: .slack,
            platformMessageId: "m1",
            senderId: "U1",
            chatId: "C1",
            text: "hello",
            type: .command,
            isDirect: true,
            isGroup: false,
            mentionsBot: false,
            isReplyToBot: false,
            internalEvent: false
        )
        let event = bundle.parseRawEvent(raw)
        #expect(event?.text == "hello")
    }

    @Test("discord transport throws notImplemented")
    func discordNotImplemented() {
        let config = ChannelListenerConfig(enabled: true, transport: .discord, platformIdentity: "discord-bot")
        let logger = Logger(label: "test")
        #expect(throws: ChannelTransportBuildError.notImplemented(.discord)) {
            try ChannelPluginFactory.build(channel: .discord, config: config, logger: logger)
        }
    }

    @Test("registry skips unimplemented transport and registers mock")
    func registrySkipsUnimplemented() async throws {
        let box = LogCaptureBox()
        let logger = Logging.Logger(label: "factory-test") { _ in LogCaptureHandler(box: box) }
        let channelsFile = ChannelsFile(channels: [
            "discord": ChannelListenerConfig(enabled: true, transport: .discord, platformIdentity: "discord-bot"),
            "slack": ChannelListenerConfig(enabled: true, transport: .mock, platformIdentity: "mock-bot"),
        ])
        let registry = ChannelListenerRegistry(
            dataDirectory: FileManager.default.temporaryDirectory,
            ingress: makeFactoryTestIngress(),
            dedupe: ChannelTestDedupe(),
            logger: logger,
            enabled: false,
            channelsFile: channelsFile
        )
        #expect(await registry.plugin(for: .slack) != nil)
        #expect(await registry.plugin(for: .discord) == nil)
        #expect(box.warnings.contains { $0.contains("channel_transport_not_implemented") && $0.contains("discord") })
    }

    private func makeFactoryTestIngress() -> ChannelIngressAdapter {
        let policy = TriggerActivationPolicy(
            idempotency: TriggerIdempotencyGate(dedupe: ChannelTestDedupe()),
            rateLimit: TriggerRateLimitGate(),
            initiatorBurst: TriggerInitiatorBurstGate(),
            auditLog: TriggerAuditLog(logger: Logging.Logger(label: "test"))
        )
        let router = TriggerSessionRouter(sessionIndex: TriggerSessionIndex(createConversation: { _ in UUID() }))
        let dispatch = TriggerDispatchService(
            activationPolicy: policy,
            sessionRouter: router,
            promptBuilder: TriggerPromptBuilder(),
            runtime: FactoryTestNoopRuntime()
        )
        return ChannelIngressAdapter(dispatch: dispatch)
    }
}

private struct FactoryTestNoopRuntime: TriggerRuntimeDispatching {
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
