import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("TriggerDelegateProfile")
struct TriggerDelegateProfileTests {
    @Test("round trips through metadata codec")
    func codecRoundTrip() {
        let profile = TriggerDelegateProfile(
            subagentType: "explore",
            agentID: "delegate_explore",
            context: .isolated,
            runInBackground: true,
            taskDescription: "webhook triage"
        )
        let encoded = TriggerDelegateProfileCodec.encodeToMetadata(profile)
        let decoded = TriggerDelegateProfileCodec.decodeFromMetadata(encoded)
        #expect(decoded == profile)
    }

    @Test("webhook route decodes delegate profile fields")
    func webhookRouteDecode() throws {
        let json = """
        {
          "name": "alerts",
          "secret": "s",
          "signatureScheme": "generic-hmac",
          "promptTemplate": "{__raw__}",
          "trust": "known-party",
          "delivery": "agent",
          "deliverOnly": false,
          "rateLimitPerMin": 30,
          "maxBodyBytes": 1048576,
          "enabled": true,
          "source": "static",
          "routingMode": "delegated",
          "deliveryWebhookURL": "https://example.com/hook",
          "delegate": {
            "runInBackground": true,
            "subagentType": "general-purpose"
          }
        }
        """
        let route = try JSONDecoder().decode(WebhookRoute.self, from: Data(json.utf8))
        #expect(route.routingMode == .delegated)
        #expect(route.deliveryWebhookURL == "https://example.com/hook")
        #expect(route.delegate?.runInBackground == true)
        #expect(route.delegate?.subagentType == "general-purpose")
    }

    @Test("webhook route decodes deliverExtra")
    func deliverExtraDecode() throws {
        let route = WebhookRoute(
            name: "notify",
            secret: "s",
            promptTemplate: "Hello {user}",
            delivery: "slack",
            deliverOnly: true,
            deliverExtra: [
                "chatId": "{channel.id}",
                "threadId": "{thread}",
            ]
        )
        let decoded = try JSONDecoder().decode(WebhookRoute.self, from: JSONEncoder().encode(route))
        #expect(decoded.deliverExtra?["chatId"] == "{channel.id}")
        #expect(decoded.deliverExtra?["threadId"] == "{thread}")
    }
}
