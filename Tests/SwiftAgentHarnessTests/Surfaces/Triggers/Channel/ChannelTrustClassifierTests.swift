import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ChannelTrustClassifier")
struct ChannelTrustClassifierTests {
    @Test("primary user DM is user-direct")
    func primaryUser() {
        let config = ChannelListenerConfig(primaryUser: "U1", auth: ChannelAuthConfig(dmAllowFrom: ["U1"]))
        let event = dmEvent(senderId: "U1")
        let trust = ChannelTrustClassifier.classify(event: event, config: config, effectiveWasMentioned: true)
        #expect(trust == .userDirect)
    }

    @Test("authorized sender is known-party")
    func knownParty() {
        let config = ChannelListenerConfig(primaryUser: "U1", auth: ChannelAuthConfig(dmAllowFrom: ["U2"]))
        let event = dmEvent(senderId: "U2")
        let trust = ChannelTrustClassifier.classify(event: event, config: config, effectiveWasMentioned: true)
        #expect(trust == .knownParty)
    }

    @Test("wildcard group mention is unknown-party")
    func wildcardGroup() {
        let config = ChannelListenerConfig(auth: ChannelAuthConfig(groupAllowFrom: ["*"]))
        var event = dmEvent(senderId: "U9")
        event.isDirect = false
        event.isGroup = true
        let trust = ChannelTrustClassifier.classify(event: event, config: config, effectiveWasMentioned: true)
        #expect(trust == .unknownParty)
    }

    private func dmEvent(senderId: String) -> ChannelMessageEvent {
        ChannelMessageEvent(
            channel: .slack,
            platformMessageId: "m1",
            senderId: senderId,
            chatId: "D1",
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
