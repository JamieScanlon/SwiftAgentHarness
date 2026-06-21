import Foundation

enum SubAgentTransportAdapterError: Error, Sendable {
    case notImplemented
    case transportUnavailable
    case invalidExecutionEnvironment(expected: SubAgentTransportKind, actual: SubAgentTransportKind)
    case missingAgentHandle
    case missingEndpointConfiguration(delegateToolName: String)
    case a2aManagerUnavailable
    case acpManagerUnavailable
}

enum RemoteTransportSessionStatus: Sendable {
    case awaitingApproval
    case running
    case cancelled
}

struct RemoteTransportSession: Sendable {
    var correlation: SubAgentTransportInvocationCorrelation
    var parentConversationID: UUID
    var delegateToolName: String?
    var defaultTrustLevel: String?
    var permissionPolicy: String?
    var status: RemoteTransportSessionStatus
    var executionStarted: Bool = false
    var execution: (@Sendable () async -> Void)?
}

actor SubAgentRemoteTransportSessionStore {
    static let shared = SubAgentRemoteTransportSessionStore()

    private var sessionsByLifecycleID: [String: RemoteTransportSession] = [:]
    private var bufferedEventsByLifecycleID: [String: [SubAgentDelegateEvent]] = [:]
    private var continuationsByLifecycleID: [String: AsyncStream<SubAgentDelegateEvent>.Continuation] = [:]

    func register(session: RemoteTransportSession, initialEvent: SubAgentDelegateEvent) -> [SubAgentDelegateEvent] {
        sessionsByLifecycleID[session.correlation.lifecycleID] = session
        emit(initialEvent, lifecycleID: session.correlation.lifecycleID)
        return [initialEvent]
    }

    func setExecution(lifecycleID: String, execution: @escaping @Sendable () async -> Void) {
        guard var session = sessionsByLifecycleID[lifecycleID] else { return }
        session.execution = execution
        sessionsByLifecycleID[lifecycleID] = session
    }

    func startExecution(lifecycleID: String) {
        guard var session = sessionsByLifecycleID[lifecycleID],
              let execution = session.execution,
              !session.executionStarted else {
            return
        }
        session.executionStarted = true
        sessionsByLifecycleID[lifecycleID] = session
        Task { await execution() }
    }

    func markAwaitingApproval(
        lifecycleID: String,
        approvalRoute: ToolApprovalRoute
    ) -> SubAgentDelegateEvent? {
        guard var session = sessionsByLifecycleID[lifecycleID] else { return nil }
        session.status = .awaitingApproval
        sessionsByLifecycleID[lifecycleID] = session
        return SubAgentDelegateEvent(
            lifecycleID: session.correlation.lifecycleID,
            parentConversationID: session.parentConversationID,
            delegateToolName: session.delegateToolName,
            asyncHandleID: session.correlation.completionHandleID,
            phase: .awaitingApproval,
            defaultTrustLevel: session.defaultTrustLevel,
            permissionPolicy: session.permissionPolicy,
            approvalRoute: approvalRoute,
            updatedAt: Date()
        )
    }

    func markRunningAfterApproval(
        lifecycleID: String,
        approvalRoute: ToolApprovalRoute
    ) -> SubAgentDelegateEvent? {
        guard var session = sessionsByLifecycleID[lifecycleID] else { return nil }
        session.status = .running
        sessionsByLifecycleID[lifecycleID] = session
        return SubAgentDelegateEvent(
            lifecycleID: session.correlation.lifecycleID,
            parentConversationID: session.parentConversationID,
            delegateToolName: session.delegateToolName,
            asyncHandleID: session.correlation.completionHandleID,
            phase: .running,
            defaultTrustLevel: session.defaultTrustLevel,
            permissionPolicy: session.permissionPolicy,
            approvalRoute: approvalRoute,
            updatedAt: Date()
        )
    }

    func executionStarted(lifecycleID: String) -> Bool {
        sessionsByLifecycleID[lifecycleID]?.executionStarted ?? false
    }

    func updateCorrelation(lifecycleID: String, sessionHandleID: String, completionHandleID: String?) {
        guard var session = sessionsByLifecycleID[lifecycleID] else { return }
        session.correlation.sessionHandleID = sessionHandleID
        if let completionHandleID {
            session.correlation.completionHandleID = completionHandleID
        }
        sessionsByLifecycleID[lifecycleID] = session
    }

    func stream(correlation: SubAgentTransportInvocationCorrelation) -> AsyncStream<SubAgentDelegateEvent> {
        let lifecycleID = correlation.lifecycleID
        guard sessionsByLifecycleID[lifecycleID] != nil else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        return AsyncStream { continuation in
            Task {
                self.attachContinuation(continuation, lifecycleID: lifecycleID)
            }
        }
    }

    func emit(_ event: SubAgentDelegateEvent, lifecycleID: String) {
        if let continuation = continuationsByLifecycleID[lifecycleID] {
            continuation.yield(event)
            return
        }
        bufferedEventsByLifecycleID[lifecycleID, default: []].append(event)
    }

    func cancel(_ request: SubAgentTransportCancellationRequest) -> SubAgentTransportCancellationResult {
        guard var session = sessionsByLifecycleID[request.lifecycleID] else {
            return SubAgentTransportCancellationResult(disposition: .noAction, note: "session_not_found")
        }
        if session.status == .cancelled {
            return SubAgentTransportCancellationResult(disposition: .noAction, note: "already_cancelled")
        }
        session.status = .cancelled
        sessionsByLifecycleID[request.lifecycleID] = session
        Task { await SubAgentACPPermissionCoordinator.shared.cancelWaits(lifecycleID: request.lifecycleID) }
        let event = failedEvent(
            session: session,
            error: "cancelled_by_operator"
        )
        emit(event, lifecycleID: request.lifecycleID)
        return SubAgentTransportCancellationResult(
            disposition: .cancelled,
            note: "transport_cancelled",
            delegateEvents: [event]
        )
    }

    func resolvePermission(
        _ request: SubAgentTransportPermissionResolutionRequest
    ) -> SubAgentTransportPermissionResolutionResult {
        guard var session = sessionsByLifecycleID[request.lifecycleID] else {
            return SubAgentTransportPermissionResolutionResult(disposition: .noAction, note: "session_not_found")
        }
        guard session.status == .awaitingApproval else {
            return SubAgentTransportPermissionResolutionResult(disposition: .noAction, note: "not_waiting_for_approval")
        }
        switch request.decision {
        case .approved:
            session.status = .running
            let shouldStartExecution = !session.executionStarted
            if shouldStartExecution {
                session.executionStarted = true
            }
            sessionsByLifecycleID[request.lifecycleID] = session
            let event = SubAgentDelegateEvent(
                lifecycleID: session.correlation.lifecycleID,
                parentConversationID: session.parentConversationID,
                delegateToolName: session.delegateToolName,
                asyncHandleID: session.correlation.completionHandleID,
                phase: .running,
                defaultTrustLevel: session.defaultTrustLevel,
                permissionPolicy: session.permissionPolicy,
                approvalRoute: request.approvalRoute,
                updatedAt: Date()
            )
            emit(event, lifecycleID: request.lifecycleID)
            if shouldStartExecution, let execution = session.execution {
                Task { await execution() }
            }
            return SubAgentTransportPermissionResolutionResult(
                disposition: .resumed,
                note: "permission_approved",
                correlation: session.correlation,
                delegateEvents: [event]
            )
        case .denied:
            session.status = .cancelled
            sessionsByLifecycleID[request.lifecycleID] = session
            let event = failedEvent(
                session: session,
                error: "permission_denied",
                approvalRoute: request.approvalRoute
            )
            emit(event, lifecycleID: request.lifecycleID)
            return SubAgentTransportPermissionResolutionResult(
                disposition: .cancelled,
                note: "permission_denied",
                correlation: session.correlation,
                delegateEvents: [event]
            )
        }
    }

    func recover(_ request: SubAgentTransportRecoveryRequest) -> SubAgentTransportRecoveryResult {
        guard let session = sessionsByLifecycleID[request.lifecycleID] else {
            return SubAgentTransportRecoveryResult(disposition: .noAction, note: "session_not_found")
        }
        switch session.status {
        case .awaitingApproval:
            let event = SubAgentDelegateEvent(
                lifecycleID: session.correlation.lifecycleID,
                parentConversationID: session.parentConversationID,
                delegateToolName: session.delegateToolName,
                asyncHandleID: session.correlation.completionHandleID,
                phase: .awaitingApproval,
                defaultTrustLevel: session.defaultTrustLevel,
                permissionPolicy: session.permissionPolicy,
                updatedAt: Date()
            )
            return SubAgentTransportRecoveryResult(
                disposition: .resumed,
                note: "awaiting_approval",
                correlation: session.correlation,
                delegateEvents: [event]
            )
        case .running:
            let event = SubAgentDelegateEvent(
                lifecycleID: session.correlation.lifecycleID,
                parentConversationID: session.parentConversationID,
                delegateToolName: session.delegateToolName,
                asyncHandleID: session.correlation.completionHandleID,
                phase: .running,
                defaultTrustLevel: session.defaultTrustLevel,
                permissionPolicy: session.permissionPolicy,
                updatedAt: Date()
            )
            return SubAgentTransportRecoveryResult(
                disposition: .resumed,
                note: "running",
                correlation: session.correlation,
                delegateEvents: [event]
            )
        case .cancelled:
            let event = failedEvent(session: session, error: "remote_transport_recovery_cancelled")
            return SubAgentTransportRecoveryResult(
                disposition: .cancelled,
                note: "cancelled",
                correlation: session.correlation,
                delegateEvents: [event]
            )
        }
    }

    private func attachContinuation(
        _ continuation: AsyncStream<SubAgentDelegateEvent>.Continuation,
        lifecycleID: String
    ) {
        continuationsByLifecycleID[lifecycleID] = continuation
        let buffered = bufferedEventsByLifecycleID.removeValue(forKey: lifecycleID) ?? []
        for event in buffered {
            continuation.yield(event)
        }
    }

    private func failedEvent(
        session: RemoteTransportSession,
        error: String,
        approvalRoute: ToolApprovalRoute? = nil
    ) -> SubAgentDelegateEvent {
        SubAgentDelegateEvent(
            lifecycleID: session.correlation.lifecycleID,
            parentConversationID: session.parentConversationID,
            delegateToolName: session.delegateToolName,
            asyncHandleID: session.correlation.completionHandleID,
            phase: .failed,
            defaultTrustLevel: session.defaultTrustLevel,
            permissionPolicy: session.permissionPolicy,
            approvalRoute: approvalRoute,
            error: error,
            updatedAt: Date()
        )
    }
}
