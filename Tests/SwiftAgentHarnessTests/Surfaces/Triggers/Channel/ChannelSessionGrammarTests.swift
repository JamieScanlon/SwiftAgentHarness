import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("Channel session grammar")
struct ChannelSessionGrammarTests {
    @Test("resolve includes parent fallback candidates narrowest to broadest")
    func parentFallbacks() {
        let config = ChannelListenerConfig(
            platformIdentity: "bot-1",
            dmScope: .perChannelPeer
        )
        let event = ChannelMessageEvent(
            channel: .slack,
            platformMessageId: "m1",
            senderId: "user-1",
            chatId: "C123",
            threadId: "T456",
            receivedAt: 1,
            type: .text,
            text: "hi",
            attachments: [],
            isReplyToBot: false,
            hasMention: true,
            mentionsBot: true,
            isDirect: false,
            isGroup: true,
            chatTypeRaw: "group",
            internalEvent: false
        )
        let resolution = ChannelSessionGrammar.resolve(event: event, config: config)
        #expect(resolution.baseConversationKey.contains("T456"))
        #expect(!resolution.parentFallbackCandidates.isEmpty)
        #expect(resolution.parentFallbackCandidates.first?.contains("T456") == false)
    }

    @Test("bootstrap resolver works without runtime")
    func bootstrapResolve() {
        let key = ChannelSessionGrammar.bootstrapResolveSessionKey(
            channel: .telegram,
            chatId: "chat",
            threadId: nil,
            senderId: "peer",
            platformIdentity: "bot"
        )
        #expect(key.contains("telegram"))
        #expect(key.contains("peer"))
    }
}

@Suite("Channel plugin factory")
struct ChannelPluginFactoryTests {
    @Test("mock plugin declares message tool media params")
    func describeMessageTool() throws {
        let config = ChannelListenerConfig(enabled: true, platformIdentity: "mock-bot")
        let logger = Logger(label: "test")
        let bundle = try ChannelPluginFactory.build(channel: .slack, config: config, logger: logger)
        let plugin = bundle.plugin
        #expect(plugin.outbound.textChunkLimit > 0)
        #expect(plugin.messageToolDescriptor?.describeMessageTool().isEmpty == false)
        let rendered = plugin.outbound.renderPresentation(MessagePresentation(blocks: [.text("hi")]))
        #expect(rendered.text == "hi")
        #expect(rendered.richPresentation?.blocks == [.text("hi")])
    }
}

@Suite("Channel identifier redaction")
struct ChannelIdentifierRedactionTests {
    @Test("redacts phone-like identifiers")
    func phone() {
        let redacted = ChannelIdentifierRedaction.redact("15551234567")
        #expect(!redacted.contains("15551234567"))
    }

    @Test("redacts email-like identifiers")
    func email() {
        let redacted = ChannelIdentifierRedaction.redact("user@example.com")
        #expect(redacted.contains("@"))
        #expect(!redacted.contains("user@example.com"))
    }
}

@Suite("Channel message dedupe key")
struct ChannelMessageDedupKeyTests {
    @Test("dedupe key includes channel account peer session and message id")
    func keyShape() {
        let key = ChannelMessageDedup.dedupeKey(
            channel: .discord,
            platformMessageId: "msg-1",
            accountId: "acct",
            peerId: "peer",
            sessionKey: "session"
        )
        #expect(key == "discord:acct:peer:session:msg-1")
    }
}
