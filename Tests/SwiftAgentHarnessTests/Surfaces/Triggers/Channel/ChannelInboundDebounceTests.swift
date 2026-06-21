import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ChannelInboundDebounce")
struct ChannelInboundDebounceTests {
    @Test("text messages debounce")
    func textDebounces() async {
        let debounce = ChannelInboundDebounce(debounceMs: 100)
        let event = textEvent(id: "1")
        #expect(await debounce.shouldDebounce(event: event))
    }

    @Test("commands skip debounce")
    func commandSkips() async {
        let debounce = ChannelInboundDebounce(debounceMs: 100)
        var event = textEvent(id: "1")
        event.type = .command
        #expect(await debounce.shouldDebounce(event: event) == false)
    }

    @Test("burst accumulates")
    func burstAccumulates() async {
        let debounce = ChannelInboundDebounce(debounceMs: 100)
        let mention = ChannelMentionGateResult(effectiveWasMentioned: true, shouldSkip: false, shouldBypassMention: false)
        _ = await debounce.append(event: textEvent(id: "1"), mentionResult: mention)
        _ = await debounce.append(event: textEvent(id: "2"), mentionResult: mention)
        #expect(await debounce.inflightCount() == 2)
        let burst = await debounce.takeBurst(key: "C1")
        #expect(burst?.events.count == 2)
    }

    private func textEvent(id: String) -> ChannelMessageEvent {
        ChannelMessageEvent(
            channel: .slack,
            platformMessageId: id,
            senderId: "U1",
            chatId: "C1",
            receivedAt: Int64(Date().timeIntervalSince1970 * 1000),
            type: .text,
            text: "part-\(id)",
            attachments: [],
            isReplyToBot: false,
            hasMention: true,
            mentionsBot: true,
            isDirect: false,
            isGroup: true,
            chatTypeRaw: "group",
            internalEvent: false
        )
    }
}
