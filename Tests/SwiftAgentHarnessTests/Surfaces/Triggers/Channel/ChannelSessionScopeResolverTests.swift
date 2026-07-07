import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ChannelSessionScopeResolver")
struct ChannelSessionScopeResolverTests {
    @Test("main shares one session")
    func mainScope() {
        let config = ChannelListenerConfig(dmScope: .main)
        #expect(ChannelSessionScopeResolver.resolveSessionKey(event: event(senderId: "U1"), config: config) == "channel:main")
    }

    @Test("per-peer isolates by sender")
    func perPeer() {
        let config = ChannelListenerConfig(dmScope: .perPeer)
        #expect(ChannelSessionScopeResolver.resolveSessionKey(event: event(senderId: "U1"), config: config) == "channel:peer:U1")
    }

    @Test("per-channel-peer isolates by channel and sender")
    func perChannelPeer() {
        let config = ChannelListenerConfig(dmScope: .perChannelPeer)
        #expect(ChannelSessionScopeResolver.resolveSessionKey(event: event(senderId: "U1"), config: config) == "channel:slack:U1")
    }

    @Test("per-account-channel-peer includes platform identity")
    func perAccountChannelPeer() {
        let config = ChannelListenerConfig(platformIdentity: "bot-A", dmScope: .perAccountChannelPeer)
        #expect(ChannelSessionScopeResolver.resolveSessionKey(event: event(senderId: "U1"), config: config) == "channel:bot-A:slack:U1")
    }

    @Test("identityLinks substitute a canonical sender")
    func identityLinks() {
        let config = ChannelListenerConfig(dmScope: .perPeer, identityLinks: ["slack:U1": "person:alice"])
        #expect(ChannelSessionScopeResolver.resolveSessionKey(event: event(senderId: "U1"), config: config) == "channel:peer:person:alice")
    }

    @Test("thread id is appended as a suffix")
    func threadSuffix() {
        let config = ChannelListenerConfig(dmScope: .perChannelPeer)
        #expect(ChannelSessionScopeResolver.resolveSessionKey(event: event(senderId: "U1", threadId: "T9"), config: config) == "channel:slack:U1:T9")
    }

    @Test("default config is per-channel-peer")
    func defaultScope() {
        #expect(ChannelListenerConfig().dmScope == .perChannelPeer)
    }

    private func event(senderId: String, threadId: String? = nil) -> ChannelMessageEvent {
        ChannelMessageEvent(
            channel: .slack,
            platformMessageId: "m1",
            senderId: senderId,
            chatId: "C1",
            threadId: threadId,
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

@Suite("ChannelTriggerBuilderSessionKey")
struct ChannelTriggerBuilderSessionKeyTests {
    @Test("builder stamps sessionKeyOverride from dmScope")
    func stampsOverride() throws {
        let config = ChannelListenerConfig(platformIdentity: "bot-A", dmScope: .perAccountChannelPeer)
        let trigger = try ChannelTriggerBuilder.build(
            event: sampleEvent(),
            config: config,
            sessionGrammar: ChannelSessionGrammar(config: config),
            trust: .userDirect,
            effectiveWasMentioned: true,
            burst: nil
        )
        #expect(trigger.sourceMetadata["sessionKeyOverride"] == "channel:bot-A:slack:U1")
    }

    @Test("router honors sessionKeyOverride")
    func routerHonorsOverride() async throws {
        let index = TriggerSessionIndex(createConversation: { _ in UUID() })
        let router = TriggerSessionRouter(sessionIndex: index)
        let trigger = HarnessTrigger(
            id: "slack:m1",
            source: .channel,
            sourceMetadata: ["channel": "slack", "chatId": "C1", "sessionKeyOverride": "channel:peer:person:alice"],
            payload: "hi",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty,
            routingMode: .isolated
        )
        let route = try await router.route(trigger)
        #expect(route.sessionKey == "channel:peer:person:alice")
    }

    private func sampleEvent() -> ChannelMessageEvent {
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
            hasMention: false,
            mentionsBot: false,
            isDirect: true,
            isGroup: false,
            chatTypeRaw: "dm",
            internalEvent: false
        )
    }
}
