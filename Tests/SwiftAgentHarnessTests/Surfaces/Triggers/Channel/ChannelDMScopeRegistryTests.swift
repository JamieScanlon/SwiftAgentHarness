import Foundation
import Logging
import os
import Testing
@testable import SwiftAgentHarness

@Suite("ChannelDMScopeRegistry")
struct ChannelDMScopeRegistryTests {
    @Test("dmScope=main emits a startup warning")
    func mainScopeWarns() throws {
        let box = LogCaptureBox()
        _ = makeRegistry(dmScope: .main, box: box)
        #expect(box.warnings.contains { $0.contains("channel_dm_scope_main") })
    }

    @Test("per-channel-peer default does not warn")
    func defaultScopeQuiet() throws {
        let box = LogCaptureBox()
        _ = makeRegistry(dmScope: .perChannelPeer, box: box)
        #expect(box.warnings.contains { $0.contains("channel_dm_scope_main") } == false)
    }

    private func makeRegistry(dmScope: ChannelDMScope, box: LogCaptureBox) -> ChannelListenerRegistry {
        let logger = Logging.Logger(label: "dm-scope-test") { _ in LogCaptureHandler(box: box) }
        let channelsFile = ChannelsFile(channels: [
            "slack": ChannelListenerConfig(enabled: true, transport: .mock, dmScope: dmScope)
        ])
        return ChannelListenerRegistry(
            dataDirectory: FileManager.default.temporaryDirectory,
            ingress: makeIngress(),
            dedupe: ChannelTestDedupe(),
            logger: logger,
            enabled: false,
            channelsFile: channelsFile
        )
    }

    private func makeIngress() -> ChannelIngressAdapter {
        let policy = TriggerActivationPolicy(
            idempotency: TriggerIdempotencyGate(dedupe: ChannelTestDedupe()),
            rateLimit: TriggerRateLimitGate(),
            costCeiling: TriggerCostCeilingGate(),
            auditLog: TriggerAuditLog(logger: Logging.Logger(label: "test"))
        )
        let router = TriggerSessionRouter(sessionIndex: TriggerSessionIndex(createConversation: { _ in UUID() }))
        let dispatch = TriggerDispatchService(
            activationPolicy: policy,
            sessionRouter: router,
            promptBuilder: TriggerPromptBuilder(),
            runtime: DMScopeNoopRuntime()
        )
        return ChannelIngressAdapter(dispatch: dispatch)
    }
}

final class LogCaptureBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [String]())
    func append(_ message: String) { lock.withLock { $0.append(message) } }
    var warnings: [String] { lock.withLock { $0 } }
}

struct LogCaptureHandler: LogHandler {
    let box: LogCaptureBox
    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .trace

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        metadata: Logging.Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        if level >= Logging.Logger.Level.warning {
            box.append(message.description)
        }
    }
}

struct DMScopeNoopRuntime: TriggerRuntimeDispatching {
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
