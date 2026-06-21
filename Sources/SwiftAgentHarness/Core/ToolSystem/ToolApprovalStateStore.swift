import Foundation

enum ToolApprovalResolutionStatus: String, Sendable, Codable {
    case approved
    case denied
    case pending
}

enum ToolApprovalResolutionKind: String, Sendable, Codable {
    case manual
    case timeoutDefault
    case runtimeAuto
}

struct ToolApprovalResolution: Sendable, Codable, Equatable {
    let status: ToolApprovalResolutionStatus
    let decidedAt: Date
    let source: String
    let reason: String?
    let kind: ToolApprovalResolutionKind
}

struct ToolApprovalContractSpec: Sendable, Codable, Equatable {
    let title: String
    let description: String
    let severity: String
    let timeoutMs: Int
    let timeoutBehavior: ToolPolicyConfiguration.ApprovalTimeoutBehavior
}

struct ToolApprovalTimedOutResolution: Sendable, Equatable {
    let conversationID: UUID
    let runID: UUID?
    let toolName: String
    let route: ToolApprovalRoute
    let status: ToolApprovalResolutionStatus
    let source: String
    let reason: String
    let spec: ToolApprovalContractSpec
    let resolvedAt: Date
}

private struct ToolApprovalStateKey: Hashable, Sendable {
    let conversationID: UUID
    let runID: UUID?
    let toolName: String
    let route: ToolApprovalRoute
}

enum ToolApprovalWaitError: Error, Sendable {
    case pendingRequestNotFound
}

actor ToolApprovalStateStore {
    private var resolutions: [ToolApprovalStateKey: ToolApprovalResolution] = [:]
    private var pendingRequests: [ToolApprovalStateKey: PendingApprovalRequest] = [:]
    private var waiters: [ToolApprovalStateKey: [CheckedContinuation<ToolApprovalResolution, Error>]] = [:]

    private struct PendingApprovalRequest: Sendable {
        let requestedAt: Date
        let expiresAt: Date
        let spec: ToolApprovalContractSpec
    }

    func setResolution(
        conversationID: UUID,
        runID: UUID?,
        toolName: String,
        route: ToolApprovalRoute = .user,
        status: ToolApprovalResolutionStatus,
        source: String,
        reason: String? = nil,
        kind: ToolApprovalResolutionKind = .manual,
        decidedAt: Date = Date()
    ) {
        let key = ToolApprovalStateKey(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            route: route
        )
        pendingRequests.removeValue(forKey: key)
        let resolution = ToolApprovalResolution(
            status: status,
            decidedAt: decidedAt,
            source: source,
            reason: reason,
            kind: kind
        )
        resolutions[key] = resolution
        if status != .pending {
            resumeWaiters(for: key, returning: resolution)
        }
    }

    private func resumeWaiters(for key: ToolApprovalStateKey, returning resolution: ToolApprovalResolution) {
        let pending = waiters.removeValue(forKey: key) ?? []
        for continuation in pending {
            continuation.resume(returning: resolution)
        }
    }

    func waitForResolution(
        conversationID: UUID,
        runID: UUID?,
        toolName: String,
        route: ToolApprovalRoute = .user
    ) async throws -> ToolApprovalResolution {
        let key = ToolApprovalStateKey(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            route: route
        )
        if let existing = resolution(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            route: route
        ), existing.status != .pending {
            return existing
        }
        guard let pending = pendingRequests[key] else {
            throw ToolApprovalWaitError.pendingRequestNotFound
        }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: ToolApprovalResolution.self) { group in
                group.addTask {
                    try await self.suspendForResolution(key: key)
                }
                group.addTask {
                    let delay = pending.expiresAt.timeIntervalSince(Date())
                    if delay > 0 {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                    return await self.resolveTimedOutApproval(for: key, request: pending)
                }
                guard let first = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return first
            }
        } onCancel: {
            Task {
                await self.cancelWaiters(
                    for: key,
                    conversationID: conversationID,
                    runID: runID,
                    toolName: toolName,
                    route: route
                )
            }
        }
    }

    private func suspendForResolution(key: ToolApprovalStateKey) async throws -> ToolApprovalResolution {
        try await withCheckedThrowingContinuation { continuation in
            if let existing = resolutions[key], existing.status != .pending {
                continuation.resume(returning: existing)
                return
            }
            waiters[key, default: []].append(continuation)
        }
    }

    private func resolveTimedOutApproval(
        for key: ToolApprovalStateKey,
        request: PendingApprovalRequest
    ) -> ToolApprovalResolution {
        let status: ToolApprovalResolutionStatus = switch request.spec.timeoutBehavior {
        case .autoDeny:
            .denied
        case .autoApprove:
            .approved
        }
        let timeoutReason = "approval_timeout_\(request.spec.timeoutBehavior.rawValue)"
        setResolution(
            conversationID: key.conversationID,
            runID: key.runID,
            toolName: key.toolName,
            route: key.route,
            status: status,
            source: "runtime.approvalTimeout",
            reason: timeoutReason,
            kind: .timeoutDefault,
            decidedAt: Date()
        )
        return resolutions[key]!
    }

    private func cancelWaiters(
        for key: ToolApprovalStateKey,
        conversationID: UUID,
        runID: UUID?,
        toolName: String,
        route: ToolApprovalRoute
    ) {
        setResolution(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            route: route,
            status: .denied,
            source: "runtime.cancelled",
            reason: "denied-cancelled",
            kind: .runtimeAuto
        )
    }

    func resolution(
        conversationID: UUID,
        runID: UUID?,
        toolName: String,
        route: ToolApprovalRoute = .user
    ) -> ToolApprovalResolution? {
        let scoped = ToolApprovalStateKey(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            route: route
        )
        if let exact = resolutions[scoped] {
            return exact
        }
        // Fallback for approvals not tied to a specific run.
        let conversationWide = ToolApprovalStateKey(
            conversationID: conversationID,
            runID: nil,
            toolName: toolName,
            route: route
        )
        return resolutions[conversationWide]
    }

    @discardableResult
    func registerPendingApproval(
        conversationID: UUID,
        runID: UUID?,
        toolName: String,
        route: ToolApprovalRoute = .user,
        requestedAt: Date = Date(),
        spec: ToolApprovalContractSpec
    ) -> Bool {
        let key = ToolApprovalStateKey(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            route: route
        )
        if let existing = resolutions[key], existing.status != .pending {
            return false
        }
        if pendingRequests[key] != nil {
            return false
        }
        pendingRequests[key] = PendingApprovalRequest(
            requestedAt: requestedAt,
            expiresAt: requestedAt.addingTimeInterval(TimeInterval(spec.timeoutMs) / 1000.0),
            spec: spec
        )
        resolutions[key] = ToolApprovalResolution(
            status: .pending,
            decidedAt: requestedAt,
            source: "runtime.approvalPending",
            reason: "awaiting_approval",
            kind: .runtimeAuto
        )
        return true
    }

    func consumeTimedOutApprovals(now: Date = Date()) -> [ToolApprovalTimedOutResolution] {
        var out: [ToolApprovalTimedOutResolution] = []
        for (key, request) in pendingRequests where request.expiresAt <= now {
            let status: ToolApprovalResolutionStatus = switch request.spec.timeoutBehavior {
            case .autoDeny:
                .denied
            case .autoApprove:
                .approved
            }
            let timeoutReason = "approval_timeout_\(request.spec.timeoutBehavior.rawValue)"
            out.append(
                ToolApprovalTimedOutResolution(
                    conversationID: key.conversationID,
                    runID: key.runID,
                    toolName: key.toolName,
                    route: key.route,
                    status: status,
                    source: "runtime.approvalTimeout",
                    reason: timeoutReason,
                    spec: request.spec,
                    resolvedAt: now
                )
            )
        }
        for resolved in out {
            setResolution(
                conversationID: resolved.conversationID,
                runID: resolved.runID,
                toolName: resolved.toolName,
                route: resolved.route,
                status: resolved.status,
                source: resolved.source,
                reason: resolved.reason,
                kind: .timeoutDefault,
                decidedAt: resolved.resolvedAt
            )
        }
        return out
    }

    func approvedToolNames(
        conversationID: UUID,
        runID: UUID?,
        route: ToolApprovalRoute? = nil
    ) -> Set<String> {
        let exact = resolutions.compactMap { key, value -> String? in
            guard key.conversationID == conversationID,
                  key.runID == runID,
                  (route == nil || key.route == route),
                  value.status == .approved
            else { return nil }
            return key.toolName
        }
        let fallback = resolutions.compactMap { key, value -> String? in
            guard key.conversationID == conversationID,
                  key.runID == nil,
                  (route == nil || key.route == route),
                  value.status == .approved
            else { return nil }
            return key.toolName
        }
        return Set(exact + fallback)
    }
}
