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
}
