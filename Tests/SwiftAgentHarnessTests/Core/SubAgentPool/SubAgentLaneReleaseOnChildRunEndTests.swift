import Foundation
import Testing
@testable import SwiftAgentHarness

/// Regression cover for the run-lane leak: the lane bounds *running* sub-agents, so it must be
/// released when the child's run ends — not when whoever spawned it remembers to write a terminal
/// lifecycle row. Memory, Triggers and the REST ingress never wrote one, so eight spawns wedged
/// every subsequent delegate with `global_subagent_lane_capacity_reached`.
@Suite("Sub-agent lane release on child run end")
struct SubAgentLaneReleaseOnChildRunEndTests {
    private func entry(
        lifecycleID: String,
        parentConversationID: UUID,
        childConversationID: UUID?,
        phase: SubAgentLifecyclePhase
    ) -> SubAgentLifecycleEntryPayload {
        SubAgentLifecycleEntryPayload(
            lifecycleID: lifecycleID,
            parentConversationID: parentConversationID,
            childConversationID: childConversationID,
            phase: phase
        )
    }

    private func state(_ entries: [SubAgentLifecycleEntryPayload]) -> SubAgentLifecycleState {
        var state = SubAgentLifecycleState()
        for entry in entries {
            state.upsert(parentConversationID: entry.parentConversationID, entry: entry)
        }
        return state
    }

    @Test("A running child's invocation is found by its child conversation id")
    func findsRunningInvocation() {
        let parent = UUID()
        let child = UUID()
        let state = state([entry(lifecycleID: "l-1", parentConversationID: parent, childConversationID: child, phase: .running)])
        let found = state.activeEntries(childConversationID: child)
        #expect(found.map(\.lifecycleID) == ["l-1"])
        #expect(found.first?.parentConversationID == parent)
    }

    @Test("Background invocations parked in completing are found too")
    func findsBackgroundInvocation() {
        // `runInBackground: true` spawns sit in `.completing`, which is where memory extraction
        // and background delegates leaked from.
        let child = UUID()
        let state = state([entry(lifecycleID: "l-1", parentConversationID: UUID(), childConversationID: child, phase: .completing)])
        #expect(state.activeEntries(childConversationID: child).count == 1)
    }

    @Test("Already-terminal invocations are not rediscovered")
    func ignoresTerminalInvocations() {
        let child = UUID()
        for phase in [SubAgentLifecyclePhase.done, .failed, .orphaned] {
            let state = state([entry(lifecycleID: "l-1", parentConversationID: UUID(), childConversationID: child, phase: phase)])
            #expect(state.activeEntries(childConversationID: child).isEmpty, "phase \(phase) must not be reopened")
        }
    }

    @Test("An invocation paused for approval is left alone")
    func ignoresAwaitingApproval() {
        // A paused invocation resumes; ending its lane on a turn boundary would under-count
        // concurrency rather than fix a leak.
        let child = UUID()
        let state = state([entry(lifecycleID: "l-1", parentConversationID: UUID(), childConversationID: child, phase: .awaitingApproval)])
        #expect(state.activeEntries(childConversationID: child).isEmpty)
    }

    @Test("A different child's run end does not close this invocation")
    func scopedToTheEndedChild() {
        let mine = UUID()
        let other = UUID()
        let state = state([
            entry(lifecycleID: "l-1", parentConversationID: UUID(), childConversationID: mine, phase: .running),
            entry(lifecycleID: "l-2", parentConversationID: UUID(), childConversationID: other, phase: .running),
        ])
        #expect(state.activeEntries(childConversationID: mine).map(\.lifecycleID) == ["l-1"])
    }

    @Test("An invocation with no child conversation is untouched")
    func ignoresInvocationsWithoutAChild() {
        // Remote transports have no local child and release through their own delegate events.
        let state = state([entry(lifecycleID: "l-1", parentConversationID: UUID(), childConversationID: nil, phase: .running)])
        #expect(state.activeEntries(childConversationID: UUID()).isEmpty)
    }

    @Test("Concurrent children each resolve to their own invocation")
    func handlesConcurrentChildren() {
        let parent = UUID()
        let children = (0 ..< 8).map { _ in UUID() }
        let state = state(children.enumerated().map { index, child in
            entry(lifecycleID: "l-\(index)", parentConversationID: parent, childConversationID: child, phase: .running)
        })
        for (index, child) in children.enumerated() {
            #expect(state.activeEntries(childConversationID: child).map(\.lifecycleID) == ["l-\(index)"])
        }
    }
}
