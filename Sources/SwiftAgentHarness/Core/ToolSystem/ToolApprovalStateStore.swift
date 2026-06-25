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
    /// `nil` disables the approval timeout (wait indefinitely for a response).
    let timeoutMs: Int?
    let timeoutBehavior: ToolPolicyConfiguration.ApprovalTimeoutBehavior
    let presentation: ApprovalPresentation?

    init(
        title: String,
        description: String,
        severity: String,
        timeoutMs: Int?,
        timeoutBehavior: ToolPolicyConfiguration.ApprovalTimeoutBehavior,
        presentation: ApprovalPresentation? = nil
    ) {
        self.title = title
        self.description = description
        self.severity = severity
        self.timeoutMs = timeoutMs
        self.timeoutBehavior = timeoutBehavior
        self.presentation = presentation
    }
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

    /// A stable string id for the shared `ApprovalCoordinator` lifecycle engine.
    var coordinatorID: String {
        "tool|\(conversationID.uuidString)|\(runID?.uuidString ?? "-")|\(toolName)|\(route.rawValue)"
    }
}

enum ToolApprovalWaitError: Error, Sendable {
    case pendingRequestNotFound
}

/// Tool-path façade over the core-owned `ApprovalCoordinator`. The coordinator owns
/// pending registration, dedupe, expiry/timeout, waiter resume, and cancellation;
/// this store keeps the tuple-indexed resolution map the runtime queries
/// (conversation-wide fallback, approved-tool-name set) and the per-key contract
/// specs needed to report timeouts.
actor ToolApprovalStateStore {
    private let coordinator: ApprovalCoordinator
    private var resolutions: [ToolApprovalStateKey: ToolApprovalResolution] = [:]
    private var specs: [ToolApprovalStateKey: ToolApprovalContractSpec] = [:]
    private var keyByID: [String: ToolApprovalStateKey] = [:]

    init(coordinator: ApprovalCoordinator = ApprovalCoordinator()) {
        self.coordinator = coordinator
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
    ) async {
        let key = ToolApprovalStateKey(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            route: route
        )
        let resolution = ToolApprovalResolution(
            status: status,
            decidedAt: decidedAt,
            source: source,
            reason: reason,
            kind: kind
        )
        resolutions[key] = resolution
        guard status != .pending else { return }
        _ = await coordinator.resolve(
            id: key.coordinatorID,
            decision: status == .approved ? .allowOnce : .deny,
            source: source,
            reason: reason,
            kind: kind.rawValue,
            decidedAt: decidedAt
        )
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
        let cancellation = ApprovalCoordinator.CancellationOutcome(
            source: "runtime.cancelled",
            reason: "denied-cancelled",
            kind: ToolApprovalResolutionKind.runtimeAuto.rawValue
        )
        return try await withTaskCancellationHandler {
            do {
                let outcome = try await coordinator.waitForResolution(
                    id: key.coordinatorID,
                    cancellation: cancellation
                )
                return persist(outcome: outcome, for: key)
            } catch is CancellationError {
                return cancelResolution(for: key)
            } catch ApprovalCoordinator.WaitError.pendingRequestNotFound {
                throw ToolApprovalWaitError.pendingRequestNotFound
            }
        } onCancel: {
            Task { await self.markCancelled(key: key) }
        }
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
    ) async -> Bool {
        let key = ToolApprovalStateKey(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            route: route
        )
        if let existing = resolutions[key], existing.status != .pending {
            return false
        }
        let registered = await coordinator.register(
            id: key.coordinatorID,
            presentation: spec.presentation,
            requestedAt: requestedAt,
            timeoutMs: spec.timeoutMs,
            timeoutResolution: spec.timeoutBehavior.timeoutResolution,
            timeoutSource: "runtime.approvalTimeout",
            timeoutReason: "approval_timeout_\(spec.timeoutBehavior.rawValue)",
            timeoutKind: ToolApprovalResolutionKind.timeoutDefault.rawValue
        )
        guard registered else { return false }
        specs[key] = spec
        keyByID[key.coordinatorID] = key
        resolutions[key] = ToolApprovalResolution(
            status: .pending,
            decidedAt: requestedAt,
            source: "runtime.approvalPending",
            reason: "awaiting_approval",
            kind: .runtimeAuto
        )
        return true
    }

    func consumeTimedOutApprovals(now: Date = Date()) async -> [ToolApprovalTimedOutResolution] {
        let expired = await coordinator.consumeExpired(now: now)
        var out: [ToolApprovalTimedOutResolution] = []
        for entry in expired {
            guard let key = keyByID[entry.id], let spec = specs[key] else { continue }
            let status = ToolApprovalResolutionStatus(decision: entry.outcome.decision)
            let reason = entry.outcome.reason ?? "approval_timeout_\(spec.timeoutBehavior.rawValue)"
            resolutions[key] = ToolApprovalResolution(
                status: status,
                decidedAt: entry.outcome.decidedAt,
                source: entry.outcome.source,
                reason: reason,
                kind: .timeoutDefault
            )
            out.append(
                ToolApprovalTimedOutResolution(
                    conversationID: key.conversationID,
                    runID: key.runID,
                    toolName: key.toolName,
                    route: key.route,
                    status: status,
                    source: entry.outcome.source,
                    reason: reason,
                    spec: spec,
                    resolvedAt: entry.outcome.decidedAt
                )
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

    private func persist(outcome: ApprovalOutcome, for key: ToolApprovalStateKey) -> ToolApprovalResolution {
        let resolution = ToolApprovalResolution(
            status: ToolApprovalResolutionStatus(decision: outcome.decision),
            decidedAt: outcome.decidedAt,
            source: outcome.source,
            reason: outcome.reason,
            kind: ToolApprovalResolutionKind(rawValue: outcome.kind ?? "") ?? .manual
        )
        resolutions[key] = resolution
        return resolution
    }

    private func cancelResolution(for key: ToolApprovalStateKey) -> ToolApprovalResolution {
        markCancelled(key: key)
        return resolutions[key] ?? ToolApprovalResolution(
            status: .denied,
            decidedAt: Date(),
            source: "runtime.cancelled",
            reason: "denied-cancelled",
            kind: .runtimeAuto
        )
    }

    private func markCancelled(key: ToolApprovalStateKey) {
        let resolution = ToolApprovalResolution(
            status: .denied,
            decidedAt: Date(),
            source: "runtime.cancelled",
            reason: "denied-cancelled",
            kind: .runtimeAuto
        )
        resolutions[key] = resolution
        Task { [coordinator] in
            await coordinator.resolve(
                id: key.coordinatorID,
                decision: .cancelled,
                source: "runtime.cancelled",
                reason: "denied-cancelled",
                kind: ToolApprovalResolutionKind.runtimeAuto.rawValue
            )
        }
    }
}

extension ToolPolicyConfiguration.ApprovalTimeoutBehavior {
    var timeoutResolution: ApprovalTimeoutResolution {
        switch self {
        case .autoDeny: return .deny
        case .autoApprove: return .allow
        }
    }
}
