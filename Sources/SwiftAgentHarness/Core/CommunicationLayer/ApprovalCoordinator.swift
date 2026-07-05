import Foundation

/// A resolved approval outcome on the unified vocabulary, with the provenance
/// metadata surfaces and the runtime need to report and act on it.
public struct ApprovalOutcome: Sendable, Equatable {
    public var decision: ApprovalDecision
    public var source: String
    public var reason: String?
    /// Free-form classifier kind (e.g. the tool path's `manual`/`timeoutDefault`/
    /// `runtimeAuto`). Opaque to the coordinator.
    public var kind: String?
    public var decidedAt: Date

    public init(
        decision: ApprovalDecision,
        source: String,
        reason: String? = nil,
        kind: String? = nil,
        decidedAt: Date = Date()
    ) {
        self.decision = decision
        self.source = source
        self.reason = reason
        self.kind = kind
        self.decidedAt = decidedAt
    }
}

/// How an unanswered approval resolves once its timeout elapses.
public enum ApprovalTimeoutResolution: Sendable, Equatable {
    /// Resolve as `allow-once`.
    case allow
    /// Resolve as `deny`.
    case deny

    var decision: ApprovalDecision {
        switch self {
        case .allow: return .allowOnce
        case .deny: return .deny
        }
    }
}

/// A notice that an approval was delivered somewhere other than the originating
/// chat (e.g. routed to the owner's DMs). Core aggregates these so a single
/// notice is posted back to the origin rather than each channel guessing.
public struct ApprovalRerouteNotice: Sendable, Equatable {
    public var approvalID: String
    public var deliveredTo: String
    public var detail: String?

    public init(approvalID: String, deliveredTo: String, detail: String? = nil) {
        self.approvalID = approvalID
        self.deliveredTo = deliveredTo
        self.detail = detail
    }
}

/// The core-owned approval lifecycle engine. Owns the pending registry, dedupe,
/// expiry with a deterministic timeout behavior, waiter suspension/resume, and the
/// reroute-notice registry. Both the exec and tool approval paths sit on top of
/// this single engine so a new surface inherits filtering/dedupe/expiry/reroute for
/// free and only implements delivery.
public actor ApprovalCoordinator {
    public enum WaitError: Error, Sendable {
        case pendingRequestNotFound
    }

    /// Metadata to apply if a wait is cancelled out from under the request.
    public struct CancellationOutcome: Sendable {
        public var source: String
        public var reason: String?
        public var kind: String?

        public init(source: String = "runtime.cancelled", reason: String? = "denied-cancelled", kind: String? = nil) {
            self.source = source
            self.reason = reason
            self.kind = kind
        }
    }

    public struct ExpiredApproval: Sendable, Equatable {
        public var id: String
        public var outcome: ApprovalOutcome
        public var presentation: ApprovalPresentation?
    }

    private struct PendingApproval: Sendable {
        let requestedAt: Date
        /// `nil` means no timeout: the approval waits indefinitely (resolved only by
        /// an explicit decision or cancellation).
        let expiresAt: Date?
        let timeoutResolution: ApprovalTimeoutResolution
        let timeoutSource: String
        let timeoutReason: String?
        let timeoutKind: String?
        let presentation: ApprovalPresentation?
    }

    private var pending: [String: PendingApproval] = [:]
    private var resolutions: [String: ApprovalOutcome] = [:]
    private var waiters: [String: [CheckedContinuation<ApprovalOutcome, Error>]] = [:]
    private var rerouteNotices: [String: [ApprovalRerouteNotice]] = [:]

    public init() {}

    /// Registers a pending approval. Returns `false` if the id is already pending or
    /// already resolved (the dedupe guard), so a redelivery cannot fire twice.
    @discardableResult
    public func register(
        id: String,
        presentation: ApprovalPresentation? = nil,
        requestedAt: Date = Date(),
        timeoutMs: Int?,
        timeoutResolution: ApprovalTimeoutResolution,
        timeoutSource: String,
        timeoutReason: String? = nil,
        timeoutKind: String? = nil
    ) -> Bool {
        guard resolutions[id] == nil, pending[id] == nil else { return false }
        pending[id] = PendingApproval(
            requestedAt: requestedAt,
            expiresAt: timeoutMs.map { requestedAt.addingTimeInterval(TimeInterval($0) / 1000.0) },
            timeoutResolution: timeoutResolution,
            timeoutSource: timeoutSource,
            timeoutReason: timeoutReason,
            timeoutKind: timeoutKind,
            presentation: presentation
        )
        return true
    }

    public func isPending(id: String) -> Bool {
        pending[id] != nil
    }

    public func resolution(id: String) -> ApprovalOutcome? {
        resolutions[id]
    }

    public func presentation(id: String) -> ApprovalPresentation? {
        pending[id]?.presentation
    }

    /// Resolves a pending approval. Returns `nil` (the dedupe/unknown guard) when the
    /// id is not currently pending, so a second resolve is a no-op.
    @discardableResult
    public func resolve(
        id: String,
        decision: ApprovalDecision,
        source: String,
        reason: String? = nil,
        kind: String? = nil,
        decidedAt: Date = Date()
    ) -> ApprovalOutcome? {
        guard pending.removeValue(forKey: id) != nil else { return nil }
        let outcome = ApprovalOutcome(
            decision: decision,
            source: source,
            reason: reason,
            kind: kind,
            decidedAt: decidedAt
        )
        resolutions[id] = outcome
        resumeWaiters(for: id, with: outcome)
        return outcome
    }

    /// Tool-path wait: resolves via the registered timeout/behavior, and resolves as
    /// `cancelled` if the awaiting task is cancelled. Throws only when nothing is
    /// pending for the id.
    public func waitForResolution(
        id: String,
        cancellation: CancellationOutcome = CancellationOutcome()
    ) async throws -> ApprovalOutcome {
        if let existing = resolutions[id] { return existing }
        guard let request = pending[id] else { throw WaitError.pendingRequestNotFound }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: ApprovalOutcome.self) { group in
                group.addTask { try await self.suspendForResolution(id: id) }
                if let expiresAt = request.expiresAt {
                    group.addTask {
                        let delay = expiresAt.timeIntervalSince(Date())
                        if delay > 0 {
                            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        }
                        return await self.resolveExpired(id: id)
                    }
                }
                guard let first = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return first
            }
        } onCancel: {
            Task { await self.cancel(id: id, cancellation: cancellation) }
        }
    }

    /// Exec-path wait: uses a caller-supplied timeout (or no timeout when
    /// `timeoutSeconds` is `nil`, i.e. wait indefinitely) and returns `nil` on
    /// timeout/cancellation without persisting a resolution. Returns `nil`
    /// immediately if nothing is pending.
    public func waitForResolution(id: String, timeoutSeconds: TimeInterval?) async -> ApprovalOutcome? {
        if let existing = resolutions[id] { return existing }
        guard pending[id] != nil else { return nil }
        return await withTaskCancellationHandler {
            await withTaskGroup(of: ApprovalOutcome?.self) { group in
                group.addTask { try? await self.suspendForResolution(id: id) }
                if let timeoutSeconds {
                    group.addTask {
                        let nanoseconds = UInt64(max(0, timeoutSeconds) * 1_000_000_000)
                        try? await Task.sleep(nanoseconds: nanoseconds)
                        return nil
                    }
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                // Resume the still-parked suspend child so the group can drain; a
                // cancelled task blocked on a continuation is not auto-resumed.
                if first == nil {
                    self.dropWaiters(for: id)
                }
                return first
            }
        } onCancel: {
            // An indefinite wait only resumes via resolution or cancellation; on
            // cancellation resume the parked waiter so the run never hangs.
            Task { await self.dropWaiters(for: id) }
        }
    }

    /// Resolves any pending approvals whose timeout has elapsed, returning them so the
    /// runtime can emit lifecycle events. Idempotent with the per-wait timeout.
    /// When `matchingIDs` is non-nil, only expired pendings whose id is in the set are consumed.
    @discardableResult
    public func consumeExpired(matchingIDs: Set<String>? = nil, now: Date = Date()) -> [ExpiredApproval] {
        let expiredIDs = pending.compactMap { id, request -> String? in
            if let matchingIDs, !matchingIDs.contains(id) { return nil }
            guard let expiresAt = request.expiresAt else { return nil }
            return expiresAt <= now ? id : nil
        }
        return expiredIDs.compactMap { id in
            let presentation = pending[id]?.presentation
            guard let outcome = resolveExpiredOutcome(id: id, now: now) else { return nil }
            return ExpiredApproval(id: id, outcome: outcome, presentation: presentation)
        }
    }

    /// Records that an approval was delivered to a non-origin target.
    public func recordRerouteNotice(_ notice: ApprovalRerouteNotice) {
        rerouteNotices[notice.approvalID, default: []].append(notice)
    }

    /// Drains the reroute notices for an approval id (so the origin posts a single
    /// aggregated notice).
    public func takeRerouteNotices(id: String) -> [ApprovalRerouteNotice] {
        rerouteNotices.removeValue(forKey: id) ?? []
    }

    private func cancel(id: String, cancellation: CancellationOutcome) {
        resolve(
            id: id,
            decision: .cancelled,
            source: cancellation.source,
            reason: cancellation.reason,
            kind: cancellation.kind
        )
    }

    private func resolveExpired(id: String) -> ApprovalOutcome {
        if let existing = resolutions[id] { return existing }
        return resolveExpiredOutcome(id: id, now: Date()) ?? resolutions[id]
            ?? ApprovalOutcome(decision: .timeout, source: "runtime.approvalTimeout")
    }

    private func resolveExpiredOutcome(id: String, now: Date) -> ApprovalOutcome? {
        guard let request = pending[id] else { return nil }
        let outcome = resolve(
            id: id,
            decision: request.timeoutResolution.decision,
            source: request.timeoutSource,
            reason: request.timeoutReason,
            kind: request.timeoutKind,
            decidedAt: now
        )
        return outcome
    }

    private func suspendForResolution(id: String) async throws -> ApprovalOutcome {
        try await withCheckedThrowingContinuation { continuation in
            if let existing = resolutions[id] {
                continuation.resume(returning: existing)
                return
            }
            waiters[id, default: []].append(continuation)
        }
    }

    private func resumeWaiters(for id: String, with outcome: ApprovalOutcome) {
        let pendingWaiters = waiters.removeValue(forKey: id) ?? []
        for continuation in pendingWaiters {
            continuation.resume(returning: outcome)
        }
    }

    private func dropWaiters(for id: String) {
        let pendingWaiters = waiters.removeValue(forKey: id) ?? []
        for continuation in pendingWaiters {
            continuation.resume(throwing: WaitError.pendingRequestNotFound)
        }
    }

    /// Clears all pending/resume state. Used by tests to isolate `ExecApprovalStore.shared`.
    func resetForTesting() {
        for id in waiters.keys {
            dropWaiters(for: id)
        }
        pending.removeAll()
        resolutions.removeAll()
        waiters.removeAll()
        rerouteNotices.removeAll()
    }
}
