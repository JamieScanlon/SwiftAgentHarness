import Foundation
import os
import Testing
@testable import SwiftAgentHarness

@Suite("TriggerSessionRouterDelegated")
struct TriggerSessionRouterDelegatedTests {
    @Test("delegated routing preserves mode and session key prefix")
    func delegatedKey() async throws {
        let stamped: OSAllocatedUnfairLock<[UUID]> = OSAllocatedUnfairLock(initialState: [])
        let index = TriggerSessionIndex(
            createConversation: { _ in UUID() },
            stampDelegatedHost: { id, _, _ in
                stamped.withLock { $0.append(id) }
            }
        )
        let router = TriggerSessionRouter(sessionIndex: index)
        let trigger = HarnessTrigger(
            id: "t-delegated",
            source: .webhook,
            sourceMetadata: ["routeName": "alerts"],
            payload: "payload",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty,
            routingMode: .delegated
        )
        let route = try await router.route(trigger)
        #expect(route.sessionKey == "webhook:delegated:alerts")
        #expect(route.routingMode == .delegated)
        #expect(route.conversationID != nil)
        #expect(stamped.withLock { $0.count } == 1)
    }

    @Test("cron delegated uses routing mode in session key")
    func cronDelegatedKey() async throws {
        let index = TriggerSessionIndex(createConversation: { _ in UUID() })
        let router = TriggerSessionRouter(sessionIndex: index)
        let trigger = HarnessTrigger(
            id: "cron-1",
            source: .cron,
            sourceMetadata: ["cronJobId": "job-42"],
            payload: "tick",
            initiator: TriggerInitiator(kind: .system),
            trust: .system,
            routingMode: .delegated
        )
        let route = try await router.route(trigger)
        #expect(route.sessionKey == "cron:delegated:job-42")
        #expect(route.routingMode == .delegated)
    }
}
