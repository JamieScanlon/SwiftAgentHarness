import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("WebhookReplayBuilder")
struct WebhookReplayBuilderTests {
    @Test("builds trigger from route and payload")
    func buildsTrigger() throws {
        let route = WebhookRoute(
            name: "github-pr",
            secret: "s",
            promptTemplate: "PR: {pull_request.title}",
            trust: .knownParty
        )
        let store = WebhookRouteStore(staticRoutes: [route], dynamicStore: tempDynamicStore())
        let builder = WebhookReplayBuilder(routeStore: store)
        let trigger = try builder.build(
            routeName: "github-pr",
            payload: ["pull_request": ["title": "Fix bug"]],
            deliveryID: "delivery-1"
        )
        #expect(trigger.id == "delivery-1")
        #expect(trigger.source == .webhook)
        #expect(trigger.payload == "PR: Fix bug")
        #expect(trigger.sourceMetadata["routeName"] == "github-pr")
    }

    @Test("throws when route not found")
    func routeNotFound() throws {
        let builder = WebhookReplayBuilder(routeStore: WebhookRouteStore(dynamicStore: tempDynamicStore()))
        #expect(throws: WebhookReplayFailure.routeNotFound) {
            _ = try builder.build(routeName: "missing", payload: [:])
        }
    }

    @Test("enriches delegated profile metadata")
    func delegatedMetadata() throws {
        let delegate = TriggerDelegateProfile(subagentType: "researcher", runInBackground: true)
        let route = WebhookRoute(
            name: "delegated",
            secret: "s",
            routingMode: .delegated,
            delegate: delegate,
            deliveryWebhookURL: "https://example.com/hook"
        )
        let store = WebhookRouteStore(staticRoutes: [route], dynamicStore: tempDynamicStore())
        let trigger = try WebhookReplayBuilder(routeStore: store).build(routeName: "delegated", payload: ["x": 1])
        #expect(trigger.routingMode == .delegated)
        #expect(trigger.sourceMetadata["deliveryWebhookURL"] == "https://example.com/hook")
        #expect(trigger.sourceMetadata["delegateProfileJSON"] != nil)
    }

    private func tempDynamicStore() -> WebhookDynamicRouteStore {
        WebhookDynamicRouteStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("wh-replay-\(UUID().uuidString).json")
        )
    }
}
