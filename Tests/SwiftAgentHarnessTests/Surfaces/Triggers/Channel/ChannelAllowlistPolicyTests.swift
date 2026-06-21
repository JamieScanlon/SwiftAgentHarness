import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ChannelAllowlistPolicy")
struct ChannelAllowlistPolicyTests {
    @Test("empty allowlist denies")
    func emptyDeny() {
        let config = ChannelListenerConfig(auth: ChannelAuthConfig(dmAllowFrom: [], groupAllowFrom: []))
        let event = sampleEvent(isDirect: true, senderId: "U1")
        #expect(ChannelAllowlistPolicy.isAllowed(event: event, config: config) == false)
    }

    @Test("wildcard allows")
    func wildcard() {
        let config = ChannelListenerConfig(auth: ChannelAuthConfig(dmAllowFrom: ["*"]))
        let event = sampleEvent(isDirect: true, senderId: "U9")
        #expect(ChannelAllowlistPolicy.isAllowed(event: event, config: config) == true)
    }

    @Test("internal bypasses auth")
    func internalBypass() {
        let config = ChannelListenerConfig(auth: ChannelAuthConfig(dmAllowFrom: []))
        var event = sampleEvent(isDirect: true, senderId: "U9")
        event.internalEvent = true
        #expect(ChannelAllowlistPolicy.isAllowed(event: event, config: config) == true)
    }

    @Test("group uses group allowlist")
    func groupAllowlist() {
        let config = ChannelListenerConfig(auth: ChannelAuthConfig(dmAllowFrom: ["U1"], groupAllowFrom: ["U2"]))
        #expect(ChannelAllowlistPolicy.isAllowed(event: sampleEvent(isDirect: false, senderId: "U2", isGroup: true), config: config) == true)
        #expect(ChannelAllowlistPolicy.isAllowed(event: sampleEvent(isDirect: false, senderId: "U1", isGroup: true), config: config) == false)
    }

    private func sampleEvent(isDirect: Bool, senderId: String, isGroup: Bool = false) -> ChannelMessageEvent {
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
            isDirect: isDirect,
            isGroup: isGroup,
            chatTypeRaw: isDirect ? "dm" : "group",
            internalEvent: false
        )
    }
}
