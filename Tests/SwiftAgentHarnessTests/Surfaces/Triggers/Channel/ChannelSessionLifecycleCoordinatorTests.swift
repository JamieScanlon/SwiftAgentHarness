import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("ChannelSessionLifecycleCoordinator")
struct ChannelSessionLifecycleCoordinatorTests {
    @Test("drainSession cancels registered streaming tasks for one conversation")
    func drainSessionCancelsStreamingTask() async {
        let coordinator = ChannelSessionLifecycleCoordinator()
        let drained = UUID()
        let peer = UUID()
        let drainedTracker = TaskCancellationTracker()
        let peerTracker = TaskCancellationTracker()
        let drainedTask = Task {
            try? await Task.sleep(for: .seconds(60))
            await drainedTracker.record(Task.isCancelled)
        }
        let peerTask = Task {
            try? await Task.sleep(for: .seconds(60))
            await peerTracker.record(Task.isCancelled)
        }
        await coordinator.registerStreaming(
            conversationID: drained,
            channel: .slack,
            driveTask: drainedTask,
            typingKeepalive: nil
        )
        await coordinator.registerStreaming(
            conversationID: peer,
            channel: .slack,
            driveTask: peerTask,
            typingKeepalive: nil
        )

        await coordinator.drainSession(conversationID: drained)
        _ = await drainedTask.value
        #expect(await drainedTracker.wasCancelled == true)

        #expect(peerTask.isCancelled == false)
        peerTask.cancel()
        _ = await peerTask.value
        #expect(await peerTracker.wasCancelled == true)
    }

    @Test("drainSession returns bound burst keys")
    func drainSessionReturnsBurstKeys() async {
        let coordinator = ChannelSessionLifecycleCoordinator()
        let conversationID = UUID()
        await coordinator.bindBurstKeys(
            conversationID: conversationID,
            channel: .slack,
            burstKeys: ["C1", "C1:T1"]
        )
        let result = await coordinator.drainSession(conversationID: conversationID)
        #expect(result.burstKeys == ["C1", "C1:T1"])
        #expect(result.channel == .slack)
    }

    @Test("pending debounce tasks merge when burst keys bind")
    func pendingDebounceMergesOnBind() async {
        let coordinator = ChannelSessionLifecycleCoordinator()
        let conversationID = UUID()
        let tracker = TaskCancellationTracker()
        let debounceTask = Task {
            try? await Task.sleep(for: .seconds(60))
            await tracker.record(Task.isCancelled)
        }
        await coordinator.registerDebounce(burstKey: "C1", task: debounceTask)
        await coordinator.bindBurstKeys(
            conversationID: conversationID,
            channel: .slack,
            burstKeys: ["C1"]
        )
        await coordinator.drainSession(conversationID: conversationID)
        _ = await debounceTask.value
        #expect(await tracker.wasCancelled == true)
    }

    @Test("drainSession cancels in-flight debounce for bound conversation only")
    func debounceDrainIsolated() async throws {
        let coordinator = ChannelSessionLifecycleCoordinator()
        let conversationA = UUID()
        let conversationB = UUID()
        let emitted = DebounceEmitTracker()
        let pipeline = await makeDebouncePipeline(coordinator: coordinator, onEmit: { trigger in
            await emitted.record(chatId: trigger.sourceMetadata["chatId"] ?? "")
        })
        await coordinator.bindBurstKeys(
            conversationID: conversationA,
            channel: .slack,
            burstKeys: ["C1"]
        )
        await coordinator.bindBurstKeys(
            conversationID: conversationB,
            channel: .slack,
            burstKeys: ["C2"]
        )

        await pipeline.process(event: debounceEvent(chatId: "C1", id: "a1", text: "one"))
        await pipeline.process(event: debounceEvent(chatId: "C2", id: "b1", text: "two"))
        _ = await coordinator.drainSession(conversationID: conversationA)

        try await Task.sleep(for: .milliseconds(300))
        let chatIds = await emitted.chatIds
        #expect(chatIds == ["C2"])
    }
}

private func makeDebouncePipeline(
    coordinator: ChannelSessionLifecycleCoordinator,
    onEmit: @escaping @Sendable (HarnessTrigger) async -> Void
) async -> ChannelIntakePipeline {
    let config = ChannelListenerConfig(
        primaryUser: "U1",
        auth: ChannelAuthConfig(dmAllowFrom: ["U1"]),
        mention: ChannelMentionConfig(requireInGroups: false),
        debounce: ChannelDebounceConfig(textMs: 200)
    )
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("channel-lifecycle-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return ChannelIntakePipeline(
        channel: .slack,
        config: config,
        security: DefaultChannelSecurityAdapter(config: config),
        sessionGrammar: ChannelSessionGrammar(),
        mediaRoot: dir,
        dedup: ChannelMessageDedup(dedupe: InMemoryTriggerDedupe(), ttlSeconds: config.dedupe.ttlSeconds),
        lifecycleCoordinator: coordinator,
        logger: Logger(label: "test"),
        emitTrigger: onEmit
    )
}

private func debounceEvent(chatId: String, id: String, text: String) -> ChannelMessageEvent {
    ChannelMessageEvent(
        channel: .slack,
        platformMessageId: id,
        senderId: "U1",
        chatId: chatId,
        receivedAt: Int64(Date().timeIntervalSince1970 * 1000),
        type: .text,
        text: text,
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

private actor TaskCancellationTracker {
    private(set) var wasCancelled: Bool?

    func record(_ cancelled: Bool) {
        wasCancelled = cancelled
    }
}

private actor DebounceEmitTracker {
    private(set) var chatIds: [String] = []

    func record(chatId: String) {
        chatIds.append(chatId)
    }
}
