import Foundation

extension SubAgentSpawnService {
    /// How following a remote delegate's events ended.
    struct RemoteDelegateEnding: Sendable {
        /// The terminal event, or `nil` when the stream ended without one.
        var terminal: SubAgentDelegateEvent?
        /// Set when the idle timeout ended the invocation: the timeout, in seconds.
        var idleTimedOut: TimeInterval?
    }

    /// Applies a remote delegate's events until it reaches a terminal phase or its stream ends. When no event
    /// arrives for `idleTimeoutSeconds`, the invocation is cancelled with reason `idle-timeout` and ends failed.
    /// Events applied from elsewhere, such as permission requests, also count, and the clock pauses while the
    /// invocation awaits approval. With `applyingTerminal` false, the terminal event is returned unapplied.
    /// `now` is the clock quiet time is measured on.
    func followRemoteDelegate(
        _ stream: AsyncStream<SubAgentDelegateEvent>,
        correlation: SubAgentTransportInvocationCorrelation,
        parentConversationID: UUID,
        idleTimeoutSeconds: TimeInterval?,
        applyingTerminal: Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async -> RemoteDelegateEnding {
        let lifecycleID = correlation.lifecycleID
        let liveness = DelegateLiveness(now: now)
        liveness.observe(waitingOnApproval: { [weak self] in
            await self?.isAwaitingApproval(lifecycleID: lifecycleID, parentConversationID: parentConversationID) ?? false
        })
        remoteDelegateLiveness[lifecycleID] = liveness
        defer { remoteDelegateLiveness[lifecycleID] = nil }

        let ending = await withTaskGroup(of: RemoteDelegateEnding?.self) { group in
            group.addTask {
                for await event in stream {
                    let terminal = event.phase == .done || event.phase == .failed
                    if terminal, !applyingTerminal { return RemoteDelegateEnding(terminal: event) }
                    await self.applySubAgentDelegateEvent(event)
                    if terminal { return RemoteDelegateEnding(terminal: event) }
                }
                return RemoteDelegateEnding(terminal: nil)
            }
            if let idleTimeoutSeconds, idleTimeoutSeconds > 0 {
                group.addTask {
                    do {
                        try await liveness.waitUntilIdle(for: idleTimeoutSeconds)
                    } catch {
                        return nil
                    }
                    return RemoteDelegateEnding(idleTimedOut: idleTimeoutSeconds)
                }
            }
            var first: RemoteDelegateEnding?
            while first == nil, let next = await group.next() {
                first = next
            }
            group.cancelAll()
            return first ?? RemoteDelegateEnding(terminal: nil)
        }

        guard let seconds = ending.idleTimedOut else { return ending }
        let failed = await cancelRemoteDelegateForIdleTimeout(
            correlation: correlation,
            parentConversationID: parentConversationID,
            seconds: seconds
        )
        if applyingTerminal { await applySubAgentDelegateEvent(failed) }
        return RemoteDelegateEnding(terminal: failed, idleTimedOut: seconds)
    }

    static func remoteIdleTimeoutReport(delegateName: String, seconds: TimeInterval) -> String {
        "Delegate '\(delegateName)' produced nothing for \(Int(seconds))s (its idleTimeoutSeconds) and was cancelled. That usually points at the remote agent or its connection rather than at the task."
    }

    private func isAwaitingApproval(lifecycleID: String, parentConversationID: UUID) -> Bool {
        subAgentLifecycleEntry(parentConversationID: parentConversationID, lifecycleID: lifecycleID)?.phase == .awaitingApproval
    }

    /// Cancels the transport, which may not answer, and returns the failed event that ends the invocation.
    private func cancelRemoteDelegateForIdleTimeout(
        correlation: SubAgentTransportInvocationCorrelation,
        parentConversationID: UUID,
        seconds: TimeInterval
    ) async -> SubAgentDelegateEvent {
        _ = try? await subAgentPool.cancelTransport(
            SubAgentTransportCancellationRequest(
                lifecycleID: correlation.lifecycleID,
                transportKind: correlation.transportKind,
                sessionHandleID: correlation.sessionHandleID,
                completionHandleID: correlation.completionHandleID,
                reason: Self.idleTimeoutCancelReason
            )
        )
        return SubAgentDelegateEvent(
            lifecycleID: correlation.lifecycleID,
            parentConversationID: parentConversationID,
            asyncHandleID: correlation.completionHandleID,
            phase: .failed,
            error: "\(Self.idleTimeoutCancelReason): no events for \(Int(seconds))s"
        )
    }
}
