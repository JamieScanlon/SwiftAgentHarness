import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ChannelTriggerBuilder")
struct ChannelTriggerBuilderTests {
    @Test("builds structured channel trigger")
    func buildTrigger() throws {
        let config = ChannelListenerConfig(primaryUser: "U1")
        let event = ChannelMessageEvent(
            channel: .slack,
            platformMessageId: "m1",
            senderId: "U1",
            chatId: "C1",
            threadId: "T1",
            receivedAt: 100,
            type: .text,
            text: "hello",
            attachments: [],
            isReplyToBot: false,
            hasMention: true,
            mentionsBot: true,
            isDirect: false,
            isGroup: true,
            chatTypeRaw: "group",
            internalEvent: false
        )
        let trigger = try ChannelTriggerBuilder.build(
            event: event,
            config: config,
            trust: .knownParty,
            effectiveWasMentioned: true,
            burst: nil
        )
        #expect(trigger.source == .channel)
        #expect(trigger.id == "slack:m1")
        #expect(trigger.payloadFormat == .structured)
        #expect(trigger.sourceMetadata["threadId"] == "T1")
        let decoded = try JSONDecoder().decode(ChannelTriggerPayload.self, from: Data(trigger.payload.utf8))
        #expect(decoded.text == "hello")
    }
}
