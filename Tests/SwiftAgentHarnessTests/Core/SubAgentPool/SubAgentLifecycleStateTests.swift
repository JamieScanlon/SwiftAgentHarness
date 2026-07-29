import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("SubAgent lifecycle state")
struct SubAgentLifecycleStateTests {
    @Test("assignPathSegments is stable per lifecycle and tracks sibling ordinals")
    func assignPathSegmentsStableAndOrdinal() {
        var state = SubAgentLifecycleState()
        let root = UUID()
        let first = state.assignPathSegments(
            lifecycleID: "lifecycle-1",
            rootConversationID: root,
            parentPathSegments: []
        )
        let firstRepeat = state.assignPathSegments(
            lifecycleID: "lifecycle-1",
            rootConversationID: root,
            parentPathSegments: []
        )
        let second = state.assignPathSegments(
            lifecycleID: "lifecycle-2",
            rootConversationID: root,
            parentPathSegments: []
        )
        #expect(first == ["agent-0"])
        #expect(firstRepeat == ["agent-0"])
        #expect(second == ["agent-1"])
    }

    @Test("transport context is tracked and cleared on terminal lifecycle")
    func transportContextLifecycle() {
        var state = SubAgentLifecycleState()
        let parentID = UUID()
        state.setTransportContext(
            lifecycleID: "lifecycle-1",
            context: .init(
                transportKind: .a2a,
                sessionHandleID: "delegate_remote",
                completionHandleID: "handle-1"
            )
        )
        let running = SubAgentLifecycleEntryPayload(
            lifecycleID: "lifecycle-1",
            parentConversationID: parentID,
            phase: .running
        )
        state.upsert(parentConversationID: parentID, entry: running)
        #expect(state.transportContext(lifecycleID: "lifecycle-1")?.transportKind == .a2a)

        var done = running
        done.phase = .done
        state.upsert(parentConversationID: parentID, entry: done)
        #expect(state.transportContext(lifecycleID: "lifecycle-1") == nil)
    }

    @Test("upsert stores entry after path assignment")
    func upsertAfterPathAssignment() {
        var state = SubAgentLifecycleState()
        let parentID = UUID()
        let entry = SubAgentLifecycleEntryPayload(
            lifecycleID: "lifecycle-1",
            parentConversationID: parentID,
            phase: .queued
        )
        _ = state.assignPathSegments(
            lifecycleID: entry.lifecycleID,
            rootConversationID: parentID,
            parentPathSegments: []
        )
        state.upsert(parentConversationID: parentID, entry: entry)
        #expect(state.pathSegments(lifecycleID: "lifecycle-1") == ["agent-0"])
        #expect(state.entries(parentConversationID: parentID).count == 1)
    }

    @Test("snapshot filters by branch path")
    func snapshotFiltersByBranchPath() {
        var state = SubAgentLifecycleState()
        let rootID = UUID()
        let parentID = UUID()
        state.registerRestoredLifecycle(
            lifecycleID: "l-1",
            pathSegments: ["agent-0"],
            rootConversationID: rootID,
            updatedAt: Date(),
            startedAt: Date()
        )
        state.registerRestoredLifecycle(
            lifecycleID: "l-2",
            pathSegments: ["agent-0", "agent-1"],
            rootConversationID: rootID,
            updatedAt: Date(),
            startedAt: Date()
        )
        state.registerRestoredLifecycle(
            lifecycleID: "l-3",
            pathSegments: ["agent-2"],
            rootConversationID: rootID,
            updatedAt: Date(),
            startedAt: Date()
        )
        state.upsert(parentConversationID: parentID, entry: .init(lifecycleID: "l-1", parentConversationID: parentID, phase: .running))
        state.upsert(parentConversationID: parentID, entry: .init(lifecycleID: "l-2", parentConversationID: parentID, phase: .running))
        state.upsert(parentConversationID: parentID, entry: .init(lifecycleID: "l-3", parentConversationID: parentID, phase: .running))

        let payload = state.snapshot(conversationID: rootID, pathSegments: ["agent-0"])
        #expect(payload.entries.map(\.lifecycleID) == ["l-1", "l-2"])
    }

    @Test("Delegate activity is idle with no entries and with only terminal ones")
    func activityIdleWhenNothingRunning() {
        var state = SubAgentLifecycleState()
        let parentID = UUID()
        #expect(state.subAgentActivityPhase(conversationID: parentID) == .idle)

        state.upsert(
            parentConversationID: parentID,
            entry: .init(lifecycleID: "l-1", parentConversationID: parentID, childConversationID: UUID(), phase: .done)
        )
        state.upsert(
            parentConversationID: parentID,
            entry: .init(lifecycleID: "l-2", parentConversationID: parentID, childConversationID: UUID(), phase: .failed)
        )
        #expect(state.subAgentActivityPhase(conversationID: parentID) == .idle)
    }

    @Test("Every non-terminal phase short of approval reads as working")
    func activityWorkingForEachRunningPhase() {
        for phase in [SubAgentLifecyclePhase.queued, .dispatching, .running, .completing] {
            var state = SubAgentLifecycleState()
            let parentID = UUID()
            state.upsert(
                parentConversationID: parentID,
                entry: .init(lifecycleID: "l-1", parentConversationID: parentID, childConversationID: UUID(), phase: phase)
            )
            #expect(state.subAgentActivityPhase(conversationID: parentID) == .working)
        }
    }

    @Test("A queued entry with no child conversation yet still reads as working")
    func activityWorkingBeforeChildExists() {
        var state = SubAgentLifecycleState()
        let parentID = UUID()
        // `childConversationID` is only populated once the child is created, so a union that keyed
        // off the child link would report idle for the whole dispatch window.
        state.upsert(
            parentConversationID: parentID,
            entry: .init(lifecycleID: "l-1", parentConversationID: parentID, phase: .queued)
        )
        #expect(state.subAgentActivityPhase(conversationID: parentID) == .working)
    }

    @Test("An approval-blocked delegate outranks a running sibling")
    func activityApprovalOutranksWorking() {
        var state = SubAgentLifecycleState()
        let parentID = UUID()
        state.upsert(
            parentConversationID: parentID,
            entry: .init(lifecycleID: "l-1", parentConversationID: parentID, childConversationID: UUID(), phase: .running)
        )
        state.upsert(
            parentConversationID: parentID,
            entry: .init(lifecycleID: "l-2", parentConversationID: parentID, childConversationID: UUID(), phase: .awaitingApproval)
        )
        // Reporting the mixed set as `working` would hide the one item the user has to act on.
        #expect(state.subAgentActivityPhase(conversationID: parentID) == .awaitingApproval)
    }

    @Test("Activity unions the whole subtree, not just direct children")
    func activityUnionsSubtree() {
        var state = SubAgentLifecycleState()
        let rootID = UUID()
        let childID = UUID()
        let grandchildID = UUID()
        // The child finished; the grandchild it left running is the only live work. A direct-children
        // union would report the root idle while a delegate is still going.
        state.upsert(
            parentConversationID: rootID,
            entry: .init(lifecycleID: "l-1", parentConversationID: rootID, childConversationID: childID, phase: .done)
        )
        state.upsert(
            parentConversationID: childID,
            entry: .init(lifecycleID: "l-2", parentConversationID: childID, childConversationID: grandchildID, phase: .running)
        )
        #expect(state.subAgentActivityPhase(conversationID: rootID) == .working)
        #expect(state.subAgentActivityPhase(conversationID: childID) == .working)
        #expect(state.subAgentActivityPhase(conversationID: grandchildID) == .idle)
    }

    @Test("Ancestors of a nested delegate are reported nearest first")
    func ancestorChainIsWalkedToTheRoot() {
        var state = SubAgentLifecycleState()
        let rootID = UUID()
        let childID = UUID()
        let grandchildID = UUID()
        state.upsert(
            parentConversationID: rootID,
            entry: .init(lifecycleID: "l-1", parentConversationID: rootID, childConversationID: childID, phase: .running)
        )
        state.upsert(
            parentConversationID: childID,
            entry: .init(lifecycleID: "l-2", parentConversationID: childID, childConversationID: grandchildID, phase: .running)
        )
        // The status is read on whichever conversation the user is watching, so a transition deep in
        // the tree has to refresh the chain above it.
        #expect(state.ancestorConversationIDs(of: grandchildID) == [childID, rootID])
        #expect(state.ancestorConversationIDs(of: childID) == [rootID])
        #expect(state.ancestorConversationIDs(of: rootID).isEmpty)
    }

    @Test("A cycle in the parent links terminates both walks")
    func cyclicLinksTerminate() {
        var state = SubAgentLifecycleState()
        let a = UUID()
        let b = UUID()
        // Not reachable through the spawn path, but both walks are unbounded loops without the
        // visited set, and an unbounded loop inside a status read would hang the snapshot.
        state.upsert(
            parentConversationID: a,
            entry: .init(lifecycleID: "l-1", parentConversationID: a, childConversationID: b, phase: .running)
        )
        state.upsert(
            parentConversationID: b,
            entry: .init(lifecycleID: "l-2", parentConversationID: b, childConversationID: a, phase: .running)
        )
        #expect(state.subAgentActivityPhase(conversationID: a) == .working)
        #expect(state.ancestorConversationIDs(of: a) == [b])
    }
}
