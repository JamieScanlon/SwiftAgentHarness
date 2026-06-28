import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("TriggerCorrelation")
struct TriggerCorrelationTests {
    @Test("root sets rootId and correlationId to trigger id")
    func rootCorrelation() {
        let correlation = TriggerCorrelation.root(triggerID: "webhook-abc")
        #expect(correlation.rootId == "webhook-abc")
        #expect(correlation.correlationId == "webhook-abc")
        #expect(correlation.parentTriggerId == nil)
    }

    @Test("child inherits workflow ids from parent")
    func childCorrelation() {
        let parent = HarnessTrigger(
            id: "webhook-abc",
            source: .webhook,
            payload: "hello",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty,
            correlation: .root(triggerID: "webhook-abc")
        )
        let child = TriggerCorrelation.child(parent: parent, followUpKind: "scheduled")
        #expect(child.rootId == "webhook-abc")
        #expect(child.correlationId == "webhook-abc")
        #expect(child.parentTriggerId == "webhook-abc")
        #expect(child.followUpKind == "scheduled")
    }

    @Test("withRootCorrelation is idempotent")
    func withRootCorrelationIdempotent() {
        let trigger = HarnessTrigger(
            id: "t1",
            source: .webhook,
            payload: "x",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty
        )
        let once = trigger.withRootCorrelation()
        let twice = once.withRootCorrelation()
        #expect(once.correlation?.rootId == "t1")
        #expect(twice.correlation == once.correlation)
    }

    @Test("fromPayload uses explicit triad when provided")
    func fromPayloadExplicit() {
        let correlation = TriggerCorrelation.fromPayload(
            rootId: "root-1",
            parentTriggerId: "parent-1",
            correlationId: "workflow-1",
            fallbackTriggerID: "fallback"
        )
        #expect(correlation.rootId == "root-1")
        #expect(correlation.parentTriggerId == "parent-1")
        #expect(correlation.correlationId == "workflow-1")
    }

    @Test("fromPayload falls back to root when triad incomplete")
    func fromPayloadFallback() {
        let correlation = TriggerCorrelation.fromPayload(
            rootId: nil,
            parentTriggerId: "parent-1",
            correlationId: nil,
            fallbackTriggerID: "fallback"
        )
        #expect(correlation.rootId == "fallback")
        #expect(correlation.correlationId == "fallback")
        #expect(correlation.parentTriggerId == nil)
    }
}
