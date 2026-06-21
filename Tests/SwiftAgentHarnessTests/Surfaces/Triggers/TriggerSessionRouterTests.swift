import Foundation
import os
import Testing
@testable import SwiftAgentHarness

@Suite("TriggerSessionRouter")
struct TriggerSessionRouterTests {
    @Test("isolated routing creates session key prefix")
    func isolatedKey() async throws {
        let index = TriggerSessionIndex { _ in UUID() }
        let router = TriggerSessionRouter(sessionIndex: index)
        let trigger = HarnessTrigger(
            id: "t1",
            source: .cron,
            sourceMetadata: ["cronJobId": "job-1"],
            payload: "ping",
            initiator: TriggerInitiator(kind: .system),
            trust: .system,
            routingMode: .isolated
        )
        let route = try await router.route(trigger)
        #expect(route.sessionKey == "cron:isolated:job-1")
        #expect(route.conversationID != nil)
    }

    @Test("isolated routing stamps trigger host catalog identity")
    func isolatedStampsHost() async throws {
        let stamped: OSAllocatedUnfairLock<[UUID]> = OSAllocatedUnfairLock(initialState: [])
        let index = TriggerSessionIndex(
            createConversation: { _ in UUID() },
            stampDelegatedHost: { id, _, _ in
                stamped.withLock { $0.append(id) }
            }
        )
        let router = TriggerSessionRouter(sessionIndex: index)
        let trigger = HarnessTrigger(
            id: "t-isolated",
            source: .cron,
            sourceMetadata: ["cronJobId": "job-1"],
            payload: "ping",
            initiator: TriggerInitiator(kind: .system),
            trust: .system,
            routingMode: .isolated
        )
        let route = try await router.route(trigger)
        #expect(route.conversationID != nil)
        #expect(stamped.withLock { $0.count } == 1)
    }

    @Test("threaded routing uses conversation metadata")
    func threadedConversation() async throws {
        let expected = UUID()
        let index = TriggerSessionIndex { _ in UUID() }
        let router = TriggerSessionRouter(sessionIndex: index)
        let trigger = HarnessTrigger(
            id: "t2",
            source: .webhook,
            sourceMetadata: ["conversationID": expected.uuidString],
            payload: "msg",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty,
            routingMode: .threaded
        )
        let route = try await router.route(trigger)
        #expect(route.conversationID == expected)
        #expect(route.routingMode == .threaded)
    }
}
