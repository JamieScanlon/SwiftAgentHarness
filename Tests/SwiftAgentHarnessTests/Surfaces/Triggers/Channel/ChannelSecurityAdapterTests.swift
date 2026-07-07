import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("DefaultChannelSecurityAdapter")
struct ChannelSecurityAdapterTests {
    @Test("isAllowed matches ChannelAllowlistPolicy for deny and allow cases")
    func isAllowedParity() {
        let config = ChannelListenerConfig(auth: ChannelAuthConfig(dmAllowFrom: ["U1"]))
        let adapter = DefaultChannelSecurityAdapter(config: config)
        let denied = sampleEvent(senderId: "U9")
        let allowed = sampleEvent(senderId: "U1")
        #expect(adapter.isAllowed(event: denied, config: config) == ChannelAllowlistPolicy.isAllowed(event: denied, config: config))
        #expect(adapter.isAllowed(event: allowed, config: config) == ChannelAllowlistPolicy.isAllowed(event: allowed, config: config))
        #expect(adapter.isAllowed(event: denied, config: config) == false)
        #expect(adapter.isAllowed(event: allowed, config: config) == true)
    }

    private func sampleEvent(senderId: String) -> ChannelMessageEvent {
        ChannelMessageEvent(
            channel: .slack,
            platformMessageId: "m1",
            senderId: senderId,
            chatId: "C1",
            receivedAt: 1,
            type: .text,
            text: "hi",
            attachments: [],
            isReplyToBot: false,
            hasMention: false,
            mentionsBot: false,
            isDirect: true,
            isGroup: false,
            chatTypeRaw: "dm",
            internalEvent: false
        )
    }
}
