import Foundation
import os
import Testing
@testable import SwiftAgentHarness

@Suite("ChannelMentionGate")
struct ChannelMentionGateTests {
    @Test("group requires mention by default")
    func groupRequiresMention() async {
        let gate = ChannelMentionGate(config: ChannelMentionConfig())
        let event = groupEvent(mentionsBot: false)
        let result = await gate.evaluate(event: event)
        #expect(result.shouldSkip == true)
    }

    @Test("reply to bot counts as mention")
    func replyToBot() async {
        let gate = ChannelMentionGate(config: ChannelMentionConfig())
        var event = groupEvent(mentionsBot: false)
        event.isReplyToBot = true
        let result = await gate.evaluate(event: event)
        #expect(result.effectiveWasMentioned == true)
        #expect(result.shouldSkip == false)
    }

    @Test("thread persistence after mention")
    func threadPersistence() async {
        let gate = ChannelMentionGate(config: ChannelMentionConfig())
        var mentioned = groupEvent(mentionsBot: true)
        mentioned.threadId = "T1"
        _ = await gate.evaluate(event: mentioned)
        var followUp = groupEvent(mentionsBot: false)
        followUp.threadId = "T1"
        let result = await gate.evaluate(event: followUp)
        #expect(result.effectiveWasMentioned == true)
    }

    @Test("lru eviction drops oldest thread mention state")
    func lruEviction() async {
        var config = ChannelMentionConfig()
        config.mentionedThreadMaxEntries = 2
        let gate = ChannelMentionGate(config: config)
        for thread in ["T1", "T2"] {
            var event = groupEvent(mentionsBot: true)
            event.threadId = thread
            _ = await gate.evaluate(event: event)
        }
        var evict = groupEvent(mentionsBot: true)
        evict.threadId = "T3"
        _ = await gate.evaluate(event: evict)
        var followUp = groupEvent(mentionsBot: false)
        followUp.threadId = "T1"
        let result = await gate.evaluate(event: followUp)
        #expect(result.shouldSkip == true)
    }

    @Test("ttl expiry drops thread mention state")
    func ttlExpiry() async {
        let start = Date(timeIntervalSince1970: 1_000)
        let now = OSAllocatedUnfairLock(initialState: start)
        var config = ChannelMentionConfig()
        config.mentionedThreadTTLSeconds = 60
        let gate = ChannelMentionGate(config: config, now: { now.withLock { $0 } })
        var mentioned = groupEvent(mentionsBot: true)
        mentioned.threadId = "T1"
        _ = await gate.evaluate(event: mentioned)
        now.withLock { $0 = start.addingTimeInterval(61) }
        var followUp = groupEvent(mentionsBot: false)
        followUp.threadId = "T1"
        let result = await gate.evaluate(event: followUp)
        #expect(result.shouldSkip == true)
    }

    private func groupEvent(mentionsBot: Bool) -> ChannelMessageEvent {
        ChannelMessageEvent(
            channel: .slack,
            platformMessageId: "m1",
            senderId: "U1",
            chatId: "C1",
            receivedAt: 1,
            type: .text,
            text: "hi",
            attachments: [],
            isReplyToBot: false,
            hasMention: mentionsBot,
            mentionsBot: mentionsBot,
            isDirect: false,
            isGroup: true,
            chatTypeRaw: "group",
            internalEvent: false
        )
    }
}
