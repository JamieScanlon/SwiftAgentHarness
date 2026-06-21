import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("WebhookDirectDelivery")
struct WebhookDirectDeliveryTests {
    actor StubRegistry: ChannelListenerLooking {
        let listener: (any ChannelListener)?
        init(listener: (any ChannelListener)?) { self.listener = listener }
        func listener(for channel: ChannelId) async -> (any ChannelListener)? { listener }
    }

    final class RecordingChannelListener: ChannelListener, @unchecked Sendable {
        let channel: ChannelId
        var sent: [ChannelOutboundMessage] = []
        var failNext = false

        init(channel: ChannelId) {
            self.channel = channel
        }

        var id: ChannelId { channel }
        var platformIdentity: String { "test-bot" }
        var state: ChannelListenerState { .connected }
        var fatalError: ChannelFatalError? { nil }
        var config: ChannelListenerConfig { ChannelListenerConfig(platformIdentity: "test-bot") }

        func connect() async throws -> ChannelConnectResult { .connected }
        func disconnect() async {}
        func onTrigger(_ handler: @escaping ChannelTriggerHandler) -> @Sendable () -> Void { {} }
        func sendTyping(chatId: String) async {}
        func react(messageId: String, emoji: String) async {}

        func send(_ message: ChannelOutboundMessage) async -> ChannelSendResult {
            if failNext {
                return .failed(code: "send_failed", message: "mock failure")
            }
            sent.append(message)
            return .sent(messageId: "msg-1")
        }
    }

    @Test("deliverExtra templates into channel send")
    func deliverExtraTemplating() async {
        let listener = RecordingChannelListener(channel: .slack)
        let registry = StubRegistry(listener: listener)
        let delivery = WebhookDirectDelivery(channelRegistry: registry)
        let route = WebhookRoute(
            name: "notify",
            secret: "s",
            promptTemplate: "Hello {user}",
            delivery: "slack",
            deliverOnly: true,
            deliverExtra: ["chatId": "{channel.id}"]
        )
        let outcome = await delivery.deliver(
            route: route,
            rendered: "Hello alice",
            extra: ["chatId": "C123"]
        )
        #expect(outcome == .success)
        #expect(listener.sent.count == 1)
        #expect(listener.sent[0].chatId == "C123")
        #expect(listener.sent[0].text == "Hello alice")
    }

    @Test("webhook URL target posts JSON body")
    func webhookURLTarget() async {
        final class Capture: @unchecked Sendable {
            var url: String?
            var body: Data?
        }
        let capture = Capture()
        let delivery = WebhookDirectDelivery(
            channelRegistry: StubRegistry(listener: nil),
            webhookPost: { url, body in
                capture.url = url
                capture.body = body
                return 200
            }
        )
        let route = WebhookRoute(
            name: "hook",
            secret: "s",
            delivery: "webhook",
            deliverOnly: true,
            deliveryWebhookURL: "https://example.com/out"
        )
        let outcome = await delivery.deliver(route: route, rendered: "payload text", extra: [:])
        #expect(outcome == .success)
        #expect(capture.url == "https://example.com/out")
        let json = capture.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect(json?["text"] as? String == "payload text")
    }

    @Test("agent delivery rejected at validation")
    func agentDeliveryRejected() {
        let route = WebhookRoute(name: "bad", secret: "s", delivery: "agent", deliverOnly: true)
        #expect(throws: WebhookValidationFailure.deliverOnlyInvalidTarget) {
            try WebhookDeliverOnlyValidation.validate(route: route)
        }
    }

    @Test("missing target returns targetMissing")
    func missingTarget() async {
        let delivery = WebhookDirectDelivery(channelRegistry: StubRegistry(listener: nil))
        let route = WebhookRoute(name: "orphan", secret: "s", delivery: "slack", deliverOnly: true)
        let outcome = await delivery.deliver(route: route, rendered: "hi", extra: [:])
        #expect(outcome == .targetMissing)
    }
}
