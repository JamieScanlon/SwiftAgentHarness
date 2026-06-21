import Foundation
import SwiftAgentKitACP

enum SubAgentACPPermissionToolName {
    static let prefix = "subagent-acp-permission"

    static func make(lifecycleID: String, requestID: String) -> String {
        "\(prefix):\(lifecycleID):\(requestID)"
    }

    static func parse(_ toolName: String) -> (lifecycleID: String, requestID: String)? {
        guard toolName.hasPrefix("\(prefix):") else { return nil }
        let remainder = String(toolName.dropFirst(prefix.count + 1))
        let parts = remainder.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }
}

actor SubAgentACPPermissionCoordinator {
    static let shared = SubAgentACPPermissionCoordinator()

    private struct PendingWait: Sendable {
        var lifecycleID: String
        var requestID: String
        var options: [ACPPermissionOption]
        var continuation: CheckedContinuation<ACPRequestPermissionResponse, Never>
    }

    private var waitsByKey: [String: PendingWait] = [:]
    private var sessionStore: SubAgentRemoteTransportSessionStore = .shared
    private var emitEvent: (@Sendable (SubAgentDelegateEvent) async -> Void)?
    private var registerPendingApproval: (
        @Sendable (
            UUID,
            UUID?,
            String,
            ToolApprovalRoute,
            String,
            String?
        ) async -> Void
    )?

    func configure(
        sessionStore: SubAgentRemoteTransportSessionStore = .shared,
        emitEvent: @escaping @Sendable (SubAgentDelegateEvent) async -> Void,
        registerPendingApproval: @escaping @Sendable (
            UUID,
            UUID?,
            String,
            ToolApprovalRoute,
            String,
            String?
        ) async -> Void
    ) {
        self.sessionStore = sessionStore
        self.emitEvent = emitEvent
        self.registerPendingApproval = registerPendingApproval
    }

    func waitForResolution(
        lifecycleID: String,
        parentConversationID: UUID,
        runID: UUID?,
        delegateToolName: String?,
        defaultTrustLevel: String?,
        permissionPolicy: String?,
        request: ACPRequestPermissionRequest,
        policy: SubAgentPermissionPolicy
    ) async -> ACPRequestPermissionResponse {
        if policy == .auto {
            if let first = request.options.first {
                return ACPRequestPermissionResponse(outcome: .selected(optionId: first.optionId))
            }
            return ACPRequestPermissionResponse(outcome: .cancelled)
        }

        let requestID = request.toolCall.toolCallId
        let route: ToolApprovalRoute = policy == .askParent ? .parent : .user
        let approvalToolName = SubAgentACPPermissionToolName.make(lifecycleID: lifecycleID, requestID: requestID)
        let permissionTitle = request.toolCall.title ?? "ACP permission request"

        if let event = await sessionStore.markAwaitingApproval(lifecycleID: lifecycleID, approvalRoute: route) {
            var delegateEvent = event
            delegateEvent.toolCallID = requestID
            delegateEvent.runtimeLifecycleEvent = RuntimeLifecycleEventPayload(
                name: .toolApprovalRequired,
                conversationID: parentConversationID,
                runID: runID,
                toolName: approvalToolName,
                approvalState: .pending,
                policyReason: ToolAvailabilityBlockReason.approvalRequired.rawValue,
                approvalRoute: route,
                approvalTitle: "Sub-Agent Permission Required",
                approvalDescription: permissionTitle,
                delegateHandleID: lifecycleID,
                toolCallID: requestID,
                source: "subagent.acp.permission"
            )
            await emitEvent?(delegateEvent)
        }

        await registerPendingApproval?(
            parentConversationID,
            runID,
            approvalToolName,
            route,
            permissionTitle,
            delegateToolName
        )

        let key = waitKey(lifecycleID: lifecycleID, requestID: requestID)
        return await withCheckedContinuation { continuation in
            waitsByKey[key] = PendingWait(
                lifecycleID: lifecycleID,
                requestID: requestID,
                options: request.options,
                continuation: continuation
            )
        }
    }

    func applyResolution(
        lifecycleID: String,
        requestID: String,
        decision: SubAgentTransportPermissionDecision,
        approvalRoute: ToolApprovalRoute,
        optionId: String?
    ) async {
        let key = waitKey(lifecycleID: lifecycleID, requestID: requestID)
        guard let pending = waitsByKey.removeValue(forKey: key) else { return }

        switch decision {
        case .approved:
            let selectedID = optionId ?? pending.options.first?.optionId
            if let selectedID {
                if let event = await sessionStore.markRunningAfterApproval(
                    lifecycleID: lifecycleID,
                    approvalRoute: approvalRoute
                ) {
                    await emitEvent?(event)
                }
                pending.continuation.resume(
                    returning: ACPRequestPermissionResponse(outcome: .selected(optionId: selectedID))
                )
            } else {
                pending.continuation.resume(returning: ACPRequestPermissionResponse(outcome: .cancelled))
            }
        case .denied:
            pending.continuation.resume(returning: ACPRequestPermissionResponse(outcome: .cancelled))
        }
    }

    func cancelWaits(lifecycleID: String) {
        let prefix = "\(lifecycleID)|"
        for key in waitsByKey.keys where key.hasPrefix(prefix) {
            guard let pending = waitsByKey.removeValue(forKey: key) else { continue }
            pending.continuation.resume(returning: ACPRequestPermissionResponse(outcome: .cancelled))
        }
    }

    private func waitKey(lifecycleID: String, requestID: String) -> String {
        "\(lifecycleID)|\(requestID)"
    }
}
