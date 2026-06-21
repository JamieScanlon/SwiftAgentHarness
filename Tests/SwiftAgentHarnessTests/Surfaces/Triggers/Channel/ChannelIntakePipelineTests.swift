import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("ChannelIntakePipeline")
struct ChannelIntakePipelineTests {
    @Test("drops duplicate and unauthorized events")
    func drops() async {
        let emitted = CounterBox()
        let pipeline = await makePipeline(allowFrom: ["U1"], onEmit: { _ in await emitted.increment() })
        let allowed = sample(senderId: "U1", id: "a")
        let denied = sample(senderId: "U9", id: "b")
        await pipeline.process(event: allowed)
        await pipeline.process(event: allowed)
        await pipeline.process(event: denied)
        let counters = await pipeline.counters
        #expect(counters.dedupDropped == 1)
        #expect(counters.authDenied == 1)
        #expect(await emitted.value == 1)
    }

    private func makePipeline(allowFrom: [String], onEmit: @escaping @Sendable (HarnessTrigger) async -> Void) async -> ChannelIntakePipeline {
        let config = ChannelListenerConfig(
            primaryUser: "U1",
            auth: ChannelAuthConfig(dmAllowFrom: allowFrom),
            mention: ChannelMentionConfig(requireInGroups: false),
            debounce: ChannelDebounceConfig(textMs: 0)
        )
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("channel-pipe-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ChannelIntakePipeline(
            channel: .slack,
            config: config,
            mediaRoot: dir,
            logger: Logger(label: "test"),
            emitTrigger: onEmit
        )
    }

    private func sample(senderId: String, id: String) -> ChannelMessageEvent {
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
}

actor CounterBox {
    private(set) var value = 0
    func increment() { value += 1 }
}
