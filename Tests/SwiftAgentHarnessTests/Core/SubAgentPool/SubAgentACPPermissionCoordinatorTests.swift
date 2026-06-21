import Foundation
import SwiftAgentKitACP
import Testing
@testable import SwiftAgentHarness

@Suite("ACP permission coordinator", .serialized)
struct SubAgentACPPermissionCoordinatorTests {
    private func permissionRequest(requestID: String = "perm-1") -> ACPRequestPermissionRequest {
        ACPRequestPermissionRequest(
            sessionId: "session-1",
            toolCall: ACPToolCallUpdate(toolCallId: requestID, title: "Write file"),
            options: [
                ACPPermissionOption(optionId: "allow-once", name: "Allow Once", kind: "allow"),
                ACPPermissionOption(optionId: "deny", name: "Deny", kind: "deny")
            ]
        )
    }

    @Test("waitForResolution resumes with selected option on approve")
    func waitResumesOnApprove() async {
        let coordinator = SubAgentACPPermissionCoordinator()
        let sessionStore = SubAgentRemoteTransportSessionStore()
        let lifecycleID = "lifecycle-perm-\(UUID().uuidString.lowercased())"
        let parentConversationID = UUID()
        let correlation = SubAgentTransportInvocationCorrelation(
            lifecycleID: lifecycleID,
            transportKind: .acpStdio,
            sessionHandleID: "agent-1",
            completionHandleID: nil
        )
        let session = RemoteTransportSession(
            correlation: correlation,
            parentConversationID: parentConversationID,
            delegateToolName: "delegate_acp",
            defaultTrustLevel: SubAgentTrustLevel.unknownParty.rawValue,
            permissionPolicy: SubAgentPermissionPolicy.askUser.rawValue,
            status: .running,
            executionStarted: true
        )
        _ = await sessionStore.register(
            session: session,
            initialEvent: SubAgentDelegateEvent(
                lifecycleID: lifecycleID,
                parentConversationID: parentConversationID,
                delegateToolName: "delegate_acp",
                phase: .running,
                updatedAt: Date()
            )
        )
        let phaseBox = PhaseCollector()
        await coordinator.configure(
            sessionStore: sessionStore,
            emitEvent: { event in
                await phaseBox.append(event.phase)
            },
            registerPendingApproval: { _, _, _, _, _, _ in }
        )
        let waitTask = Task {
            await coordinator.waitForResolution(
                lifecycleID: lifecycleID,
                parentConversationID: parentConversationID,
                runID: nil,
                delegateToolName: "delegate_acp",
                defaultTrustLevel: SubAgentTrustLevel.unknownParty.rawValue,
                permissionPolicy: SubAgentPermissionPolicy.askUser.rawValue,
                request: permissionRequest(),
                policy: .askUser
            )
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await coordinator.applyResolution(
            lifecycleID: lifecycleID,
            requestID: "perm-1",
            decision: .approved,
            approvalRoute: .user,
            optionId: "allow-once"
        )
        let response = await waitTask.value
        if case .selected(let optionID) = response.outcome {
            #expect(optionID == "allow-once")
        } else {
            Issue.record("Expected selected outcome")
        }
        #expect(await phaseBox.phases.contains(.awaitingApproval))
        #expect(await phaseBox.phases.contains(.running))
    }

    @Test("transport session cancel releases parked ACP permission wait")
    func transportCancelReleasesParkedPermissionWait() async {
        let coordinator = SubAgentACPPermissionCoordinator.shared
        let sessionStore = SubAgentRemoteTransportSessionStore()
        let lifecycleID = "lifecycle-transport-cancel-\(UUID().uuidString.lowercased())"
        let parentConversationID = UUID()
        let correlation = SubAgentTransportInvocationCorrelation(
            lifecycleID: lifecycleID,
            transportKind: .acpStdio,
            sessionHandleID: "agent-1",
            completionHandleID: nil
        )
        let session = RemoteTransportSession(
            correlation: correlation,
            parentConversationID: parentConversationID,
            delegateToolName: "delegate_acp",
            defaultTrustLevel: SubAgentTrustLevel.unknownParty.rawValue,
            permissionPolicy: SubAgentPermissionPolicy.askUser.rawValue,
            status: .running,
            executionStarted: true
        )
        _ = await sessionStore.register(
            session: session,
            initialEvent: SubAgentDelegateEvent(
                lifecycleID: lifecycleID,
                parentConversationID: parentConversationID,
                phase: .running,
                updatedAt: Date()
            )
        )
        await coordinator.configure(
            sessionStore: sessionStore,
            emitEvent: { _ in },
            registerPendingApproval: { _, _, _, _, _, _ in }
        )
        let waitTask = Task {
            await coordinator.waitForResolution(
                lifecycleID: lifecycleID,
                parentConversationID: parentConversationID,
                runID: UUID(),
                delegateToolName: "delegate_acp",
                defaultTrustLevel: SubAgentTrustLevel.unknownParty.rawValue,
                permissionPolicy: SubAgentPermissionPolicy.askUser.rawValue,
                request: permissionRequest(requestID: "perm-transport-cancel"),
                policy: .askUser
            )
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        _ = await sessionStore.cancel(
            SubAgentTransportCancellationRequest(
                lifecycleID: lifecycleID,
                transportKind: .acpStdio,
                sessionHandleID: "agent-1",
                completionHandleID: nil
            )
        )
        let response = await waitTask.value
        #expect(response.outcome == .cancelled)
    }

    @Test("cancelWaits returns cancelled outcome")
    func cancelReturnsCancelled() async {
        let coordinator = SubAgentACPPermissionCoordinator()
        let sessionStore = SubAgentRemoteTransportSessionStore()
        let lifecycleID = "lifecycle-cancel-\(UUID().uuidString.lowercased())"
        let parentConversationID = UUID()
        let correlation = SubAgentTransportInvocationCorrelation(
            lifecycleID: lifecycleID,
            transportKind: .acpStdio,
            sessionHandleID: "agent-1",
            completionHandleID: nil
        )
        let session = RemoteTransportSession(
            correlation: correlation,
            parentConversationID: parentConversationID,
            delegateToolName: "delegate_acp",
            defaultTrustLevel: SubAgentTrustLevel.unknownParty.rawValue,
            permissionPolicy: SubAgentPermissionPolicy.askUser.rawValue,
            status: .running,
            executionStarted: true
        )
        _ = await sessionStore.register(
            session: session,
            initialEvent: SubAgentDelegateEvent(
                lifecycleID: lifecycleID,
                parentConversationID: parentConversationID,
                phase: .running,
                updatedAt: Date()
            )
        )
        await coordinator.configure(
            sessionStore: sessionStore,
            emitEvent: { _ in },
            registerPendingApproval: { _, _, _, _, _, _ in }
        )
        let waitTask = Task {
            await coordinator.waitForResolution(
                lifecycleID: lifecycleID,
                parentConversationID: parentConversationID,
                runID: nil,
                delegateToolName: nil,
                defaultTrustLevel: nil,
                permissionPolicy: nil,
                request: permissionRequest(requestID: "perm-cancel"),
                policy: .askUser
            )
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await coordinator.cancelWaits(lifecycleID: lifecycleID)
        let response = await waitTask.value
        #expect(response.outcome == .cancelled)
    }

    @Test("permission tool name parses lifecycle and request id")
    func permissionToolNameParse() {
        let toolName = SubAgentACPPermissionToolName.make(lifecycleID: "life-1", requestID: "req-2")
        let parsed = SubAgentACPPermissionToolName.parse(toolName)
        #expect(parsed?.lifecycleID == "life-1")
        #expect(parsed?.requestID == "req-2")
    }
}

private actor PhaseCollector {
    var phases: [SubAgentDelegateEventPhase] = []

    func append(_ phase: SubAgentDelegateEventPhase) {
        phases.append(phase)
    }
}
