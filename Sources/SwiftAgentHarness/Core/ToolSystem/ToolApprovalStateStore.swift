import EasyJSON
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
    let decision: ApprovalDecision?

    init(
        status: ToolApprovalResolutionStatus,
        decidedAt: Date,
        source: String,
        reason: String?,
        kind: ToolApprovalResolutionKind,
        decision: ApprovalDecision? = nil
    ) {
        self.status = status
        self.decidedAt = decidedAt
        self.source = source
        self.reason = reason
        self.kind = kind
        self.decision = decision
    }
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
    let binding: ToolCallApprovalBinding
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
    let binding: ToolCallApprovalBinding
    let route: ToolApprovalRoute

    var toolName: String { binding.toolName }

    /// A stable string id for the shared `ApprovalCoordinator` lifecycle engine.
    var coordinatorID: String {
        "tool|\(conversationID.uuidString)|\(runID?.uuidString ?? "-")|\(binding.toolName)|\(binding.argumentsFingerprint)|\(route.rawValue)"
    }
}

enum ToolApprovalWaitError: Error, Sendable {
    case pendingRequestNotFound
}

/// Tool-path façade over the core-owned `ApprovalCoordinator`. The coordinator owns
/// pending registration, dedupe, expiry/timeout, waiter resume, and cancellation;
/// this store keeps the tuple-indexed resolution map the runtime queries
/// (conversation-wide fallback, approved call bindings) and the per-key contract
/// specs needed to report timeouts.
actor ToolApprovalStateStore {
    private let coordinator: ApprovalCoordinator
    private var resolutions: [ToolApprovalStateKey: ToolApprovalResolution] = [:]
    private var specs: [ToolApprovalStateKey: ToolApprovalContractSpec] = [:]
    private var keyByID: [String: ToolApprovalStateKey] = [:]
    /// Optional tool-call id recorded when the pending approval was registered from a live call.
    private var toolCallIDs: [ToolApprovalStateKey: String] = [:]

    init(coordinator: ApprovalCoordinator = ApprovalCoordinator()) {
        self.coordinator = coordinator
    }

    func setResolution(
        conversationID: UUID,
        runID: UUID?,
        binding: ToolCallApprovalBinding,
        route: ToolApprovalRoute = .user,
        status: ToolApprovalResolutionStatus,
        source: String,
        reason: String? = nil,
        kind: ToolApprovalResolutionKind = .manual,
        decision: ApprovalDecision? = nil,
        decidedAt: Date = Date()
    ) async {
        let key = ToolApprovalStateKey(
            conversationID: conversationID,
            runID: runID,
            binding: binding,
            route: route
        )
        let resolvedDecision: ApprovalDecision? = switch status {
        case .approved:
            decision ?? .allowOnce
        case .denied, .pending:
            decision
        }
        let resolution = ToolApprovalResolution(
            status: status,
            decidedAt: decidedAt,
            source: source,
            reason: reason,
            kind: kind,
            decision: resolvedDecision
        )
        resolutions[key] = resolution
        guard status != .pending else { return }
        _ = await coordinator.resolve(
            id: key.coordinatorID,
            decision: status == .approved ? (resolvedDecision ?? .allowOnce) : .deny,
            source: source,
            reason: reason,
            kind: kind.rawValue,
            decidedAt: decidedAt
        )
    }

    func waitForResolution(
        conversationID: UUID,
        runID: UUID?,
        binding: ToolCallApprovalBinding,
        route: ToolApprovalRoute = .user
    ) async throws -> ToolApprovalResolution {
        let key = ToolApprovalStateKey(
            conversationID: conversationID,
            runID: runID,
            binding: binding,
            route: route
        )
        if let existing = resolution(
            conversationID: conversationID,
            runID: runID,
            binding: binding,
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
        binding: ToolCallApprovalBinding,
        route: ToolApprovalRoute = .user
    ) -> ToolApprovalResolution? {
        let scoped = ToolApprovalStateKey(
            conversationID: conversationID,
            runID: runID,
            binding: binding,
            route: route
        )
        if let exact = resolutions[scoped] {
            return exact
        }
        let conversationWide = ToolApprovalStateKey(
            conversationID: conversationID,
            runID: nil,
            binding: binding,
            route: route
        )
        return resolutions[conversationWide]
    }

    func pendingBindings(
        conversationID: UUID,
        runID: UUID?,
        toolName: String,
        route: ToolApprovalRoute? = nil
    ) -> [ToolCallApprovalBinding] {
        let canonicalToolName = ToolNamePolicyNormalization.canonical(toolName)
        return resolutions.compactMap { key, value -> ToolCallApprovalBinding? in
            guard key.conversationID == conversationID,
                  key.runID == runID || key.runID == nil,
                  key.binding.toolName == canonicalToolName,
                  route == nil || key.route == route,
                  value.status == .pending
            else { return nil }
            return key.binding
        }
    }

    func resolveBindingForAPI(
        conversationID: UUID,
        runID: UUID?,
        toolName: String,
        route: ToolApprovalRoute,
        arguments: JSON?
    ) throws -> ToolCallApprovalBinding {
        if let arguments {
            return ToolCallApprovalBinding.from(toolName: toolName, arguments: arguments)
        }
        let pending = pendingBindings(
            conversationID: conversationID,
            runID: runID,
            toolName: toolName,
            route: route
        )
        switch pending.count {
        case 0:
            throw ToolApprovalResolutionError.pendingApprovalNotFound(toolName: toolName)
        case 1:
            return pending[0]
        default:
            throw ToolApprovalResolutionError.ambiguousPendingApproval(
                toolName: toolName,
                pendingCount: pending.count
            )
        }
    }

    @discardableResult
    func registerPendingApproval(
        conversationID: UUID,
        runID: UUID?,
        binding: ToolCallApprovalBinding,
        route: ToolApprovalRoute = .user,
        requestedAt: Date = Date(),
        spec: ToolApprovalContractSpec,
        toolCallId: String? = nil
    ) async -> Bool {
        let key = ToolApprovalStateKey(
            conversationID: conversationID,
            runID: runID,
            binding: binding,
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
        if let toolCallId, !toolCallId.isEmpty {
            toolCallIDs[key] = toolCallId
        }
        resolutions[key] = ToolApprovalResolution(
            status: .pending,
            decidedAt: requestedAt,
            source: "runtime.approvalPending",
            reason: "awaiting_approval",
            kind: .runtimeAuto,
            decision: nil
        )
        return true
    }

    func recordedToolCallId(
        conversationID: UUID,
        runID: UUID?,
        binding: ToolCallApprovalBinding,
        route: ToolApprovalRoute = .user
    ) -> String? {
        let scoped = ToolApprovalStateKey(
            conversationID: conversationID,
            runID: runID,
            binding: binding,
            route: route
        )
        if let id = toolCallIDs[scoped] {
            return id
        }
        let conversationWide = ToolApprovalStateKey(
            conversationID: conversationID,
            runID: nil,
            binding: binding,
            route: route
        )
        return toolCallIDs[conversationWide]
    }

    func consumeTimedOutApprovals(
        conversationID: UUID,
        runID: UUID?,
        now: Date = Date()
    ) async -> [ToolApprovalTimedOutResolution] {
        let matchingIDs = Set(
            keyByID.compactMap { id, key -> String? in
                guard key.conversationID == conversationID, key.runID == runID else { return nil }
                return id
            }
        )
        let expired = await coordinator.consumeExpired(matchingIDs: matchingIDs, now: now)
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
                kind: .timeoutDefault,
                decision: entry.outcome.decision
            )
            out.append(
                ToolApprovalTimedOutResolution(
                    conversationID: key.conversationID,
                    runID: key.runID,
                    toolName: key.toolName,
                    binding: key.binding,
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

    func approvedCallBindings(
        conversationID: UUID,
        runID: UUID?,
        route: ToolApprovalRoute? = nil
    ) -> Set<ToolCallApprovalBinding> {
        Set(
            resolutions.compactMap { key, value -> ToolCallApprovalBinding? in
                guard key.conversationID == conversationID,
                      route == nil || key.route == route,
                      value.status == .approved,
                      value.decision != .allowAlways
                else { return nil }
                if let runID, let keyRunID = key.runID, keyRunID != runID {
                    return nil
                }
                return key.binding
            }
        )
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
                  value.status == .approved,
                  value.decision == .allowAlways
            else { return nil }
            return key.toolName
        }
        let fallback = resolutions.compactMap { key, value -> String? in
            guard key.conversationID == conversationID,
                  key.runID == nil,
                  (route == nil || key.route == route),
                  value.status == .approved,
                  value.decision == .allowAlways
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
            kind: ToolApprovalResolutionKind(rawValue: outcome.kind ?? "") ?? .manual,
            decision: outcome.decision
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
            kind: .runtimeAuto,
            decision: .cancelled
        )
    }

    private func markCancelled(key: ToolApprovalStateKey) {
        let resolution = ToolApprovalResolution(
            status: .denied,
            decidedAt: Date(),
            source: "runtime.cancelled",
            reason: "denied-cancelled",
            kind: .runtimeAuto,
            decision: .cancelled
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
