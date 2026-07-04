import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("SubAgentRemoteTransportSessionStore lifecycle")
struct SubAgentRemoteTransportSessionStoreTests {
    private let testGraceNanoseconds: UInt64 = 50_000_000

    private func makeStore() -> SubAgentRemoteTransportSessionStore {
        SubAgentRemoteTransportSessionStore(sessionEvictionGraceNanoseconds: testGraceNanoseconds)
    }

    private func makeSession(lifecycleID: String) -> (RemoteTransportSession, UUID) {
        let parentConversationID = UUID()
        let correlation = SubAgentTransportInvocationCorrelation(
            lifecycleID: lifecycleID,
            transportKind: .a2a,
            sessionHandleID: "agent-1",
            completionHandleID: "handle-1"
        )
        let session = RemoteTransportSession(
            correlation: correlation,
            parentConversationID: parentConversationID,
            delegateToolName: "delegate_remote",
            defaultTrustLevel: SubAgentTrustLevel.unknownParty.rawValue,
            permissionPolicy: SubAgentPermissionPolicy.askUser.rawValue,
            status: .running
        )
        return (session, parentConversationID)
    }

    private func runningEvent(
        lifecycleID: String,
        parentConversationID: UUID
    ) -> SubAgentDelegateEvent {
        SubAgentDelegateEvent(
            lifecycleID: lifecycleID,
            parentConversationID: parentConversationID,
            delegateToolName: "delegate_remote",
            phase: .running,
            updatedAt: Date()
        )
    }

    private func doneEvent(
        lifecycleID: String,
        parentConversationID: UUID
    ) -> SubAgentDelegateEvent {
        SubAgentDelegateEvent(
            lifecycleID: lifecycleID,
            parentConversationID: parentConversationID,
            delegateToolName: "delegate_remote",
            phase: .done,
            completionSource: "completed",
            updatedAt: Date()
        )
    }

    @Test("stream finishes on terminal emit without manual break")
    func streamFinishesOnTerminalEmit() async {
        let store = makeStore()
        let lifecycleID = "lifecycle-finish-\(UUID().uuidString.lowercased())"
        let (session, parentConversationID) = makeSession(lifecycleID: lifecycleID)
        _ = await store.register(
            session: session,
            initialEvent: runningEvent(lifecycleID: lifecycleID, parentConversationID: parentConversationID)
        )
        let stream = await store.stream(correlation: session.correlation)
        try? await Task.sleep(nanoseconds: 10_000_000)
        await store.emit(
            doneEvent(lifecycleID: lifecycleID, parentConversationID: parentConversationID),
            lifecycleID: lifecycleID
        )

        var events: [SubAgentDelegateEvent] = []
        for await event in stream {
            events.append(event)
        }

        #expect(events.contains { $0.phase == .running })
        #expect(events.contains { $0.phase == .done })
        #expect(await store.testing_retainedLifecycleCount() == 1)
    }

    @Test("session evicted after grace period")
    func sessionEvictedAfterGrace() async {
        let store = makeStore()
        let lifecycleID = "lifecycle-evict-\(UUID().uuidString.lowercased())"
        let (session, parentConversationID) = makeSession(lifecycleID: lifecycleID)
        _ = await store.register(
            session: session,
            initialEvent: runningEvent(lifecycleID: lifecycleID, parentConversationID: parentConversationID)
        )
        let stream = await store.stream(correlation: session.correlation)
        try? await Task.sleep(nanoseconds: 10_000_000)
        await store.emit(
            doneEvent(lifecycleID: lifecycleID, parentConversationID: parentConversationID),
            lifecycleID: lifecycleID
        )
        for await _ in stream {}

        try? await Task.sleep(nanoseconds: testGraceNanoseconds + 25_000_000)
        #expect(await store.testing_retainedLifecycleCount() == 0)
    }

    @Test("late stream attach replays buffered terminal and finishes")
    func lateStreamAttachReplaysBufferedTerminal() async {
        let store = makeStore()
        let lifecycleID = "lifecycle-late-\(UUID().uuidString.lowercased())"
        let (session, parentConversationID) = makeSession(lifecycleID: lifecycleID)
        _ = await store.register(
            session: session,
            initialEvent: runningEvent(lifecycleID: lifecycleID, parentConversationID: parentConversationID)
        )
        await store.emit(
            doneEvent(lifecycleID: lifecycleID, parentConversationID: parentConversationID),
            lifecycleID: lifecycleID
        )

        let stream = await store.stream(correlation: session.correlation)
        var events: [SubAgentDelegateEvent] = []
        for await event in stream {
            events.append(event)
        }

        #expect(events.count == 2)
        #expect(events[0].phase == .running)
        #expect(events[1].phase == .done)
    }

    @Test("cancel finishes stream and eventually evicts session")
    func cancelFinishesStreamAndEventuallyEvicts() async {
        let store = makeStore()
        let lifecycleID = "lifecycle-cancel-\(UUID().uuidString.lowercased())"
        let (session, parentConversationID) = makeSession(lifecycleID: lifecycleID)
        _ = await store.register(
            session: session,
            initialEvent: runningEvent(lifecycleID: lifecycleID, parentConversationID: parentConversationID)
        )
        let stream = await store.stream(correlation: session.correlation)
        try? await Task.sleep(nanoseconds: 10_000_000)

        _ = await store.cancel(
            SubAgentTransportCancellationRequest(
                lifecycleID: lifecycleID,
                transportKind: .a2a,
                sessionHandleID: session.correlation.sessionHandleID,
                completionHandleID: session.correlation.completionHandleID
            )
        )

        var terminal: SubAgentDelegateEventPhase?
        for await event in stream {
            if event.phase == .failed {
                terminal = event.phase
            }
        }
        #expect(terminal == .failed)

        try? await Task.sleep(nanoseconds: testGraceNanoseconds + 25_000_000)
        #expect(await store.testing_retainedLifecycleCount() == 0)
    }

    @Test("permission denied finishes stream")
    func permissionDeniedFinishesStream() async {
        let store = makeStore()
        let lifecycleID = "lifecycle-deny-\(UUID().uuidString.lowercased())"
        let (session, parentConversationID) = makeSession(lifecycleID: lifecycleID)
        var awaitingSession = session
        awaitingSession.status = .awaitingApproval
        _ = await store.register(
            session: awaitingSession,
            initialEvent: SubAgentDelegateEvent(
                lifecycleID: lifecycleID,
                parentConversationID: parentConversationID,
                delegateToolName: "delegate_remote",
                phase: .awaitingApproval,
                updatedAt: Date()
            )
        )
        let stream = await store.stream(correlation: session.correlation)
        try? await Task.sleep(nanoseconds: 10_000_000)

        _ = await store.resolvePermission(
            SubAgentTransportPermissionResolutionRequest(
                lifecycleID: lifecycleID,
                transportKind: .a2a,
                sessionHandleID: session.correlation.sessionHandleID,
                completionHandleID: session.correlation.completionHandleID,
                parentConversationID: parentConversationID,
                approvalRoute: .user,
                decision: .denied,
                source: "test"
            )
        )

        var terminal: SubAgentDelegateEventPhase?
        for await event in stream {
            if event.phase == .failed {
                terminal = event.phase
            }
        }
        #expect(terminal == .failed)
    }

    @Test("recover works before grace expires after cancel")
    func recoverWorksBeforeGraceExpires() async {
        let store = makeStore()
        let lifecycleID = "lifecycle-recover-\(UUID().uuidString.lowercased())"
        let (session, _) = makeSession(lifecycleID: lifecycleID)
        _ = await store.register(
            session: session,
            initialEvent: SubAgentDelegateEvent(
                lifecycleID: lifecycleID,
                parentConversationID: session.parentConversationID,
                delegateToolName: "delegate_remote",
                phase: .running,
                updatedAt: Date()
            )
        )

        _ = await store.cancel(
            SubAgentTransportCancellationRequest(
                lifecycleID: lifecycleID,
                transportKind: .a2a,
                sessionHandleID: session.correlation.sessionHandleID,
                completionHandleID: session.correlation.completionHandleID
            )
        )

        let result = await store.recover(
            SubAgentTransportRecoveryRequest(
                lifecycleID: lifecycleID,
                transportKind: .a2a,
                sessionHandleID: session.correlation.sessionHandleID,
                completionHandleID: session.correlation.completionHandleID
            )
        )
        #expect(result.disposition == .cancelled)
        #expect(result.delegateEvents.first?.phase == .failed)
    }
}
