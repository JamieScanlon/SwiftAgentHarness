import Foundation

struct ToolApprovalRequiredInfo: Sendable {
    let iteration: Int
    let modelID: UUID
    let toolName: String
    let toolCallID: String?
    let route: ToolApprovalRoute
    let title: String?
    let description: String?
    let severity: String?
    let timeoutMs: Int?
    let timeoutBehavior: String?
    let resolutionKind: String
    let presentation: ApprovalPresentation?
    let source: String
}

struct ToolApprovalResolvedInfo: Sendable {
    let iteration: Int?
    let modelID: UUID?
    let toolName: String
    let toolCallID: String?
    let approvalState: RuntimeLifecycleApprovalState
    let policyReason: String?
    let approvalSource: String?
    let approvalReason: String?
    let route: ToolApprovalRoute?
    let title: String?
    let description: String?
    let severity: String?
    let timeoutMs: Int?
    let timeoutBehavior: String?
    let resolutionKind: String?
    let presentation: ApprovalPresentation?
    let source: String
}

enum AgentRuntimeLifecycleEmit: Sendable {
    case turnStarted
    case loopIterationStarted(iteration: Int, modelID: UUID)
    case loopIterationCompleted(iteration: Int, modelID: UUID)
    case modelCallStarted(iteration: Int, modelID: UUID)
    /// `usage` is the provider's report for *this* completion, plus a catalog-rate cost when the
    /// model carries one. Defaulted so the case stays source-compatible.
    case modelCallCompleted(iteration: Int, modelID: UUID, usage: DelegateCompletionUsagePayload? = nil)
    case toolCallStarted(iteration: Int, modelID: UUID, toolName: String, toolCallID: String?)
    case toolCallCompleted(
        iteration: Int,
        modelID: UUID,
        toolName: String,
        toolCallID: String?,
        resultTruncated: Bool? = nil
    )
    case toolCallFailed(
        iteration: Int,
        modelID: UUID,
        toolName: String,
        toolCallID: String?,
        errorClass: String,
        message: String,
        elapsedMs: Int?,
        mcpServerName: String? = nil
    )
    case toolApprovalRequired(ToolApprovalRequiredInfo)
    case toolApprovalResolved(ToolApprovalResolvedInfo)
    case turnTerminal(ConversationRunTerminalReason)
}

struct AgentRuntimeLifecycleEmitter {
    typealias Publish = @Sendable (_ conversationID: UUID, _ payload: RuntimeLifecycleEventPayload) async -> Void

    private let publish: Publish

    init(publish: @escaping Publish) {
        self.publish = publish
    }

    func emit(
        _ event: AgentRuntimeLifecycleEmit,
        conversationID: UUID,
        runID: UUID?,
        source: String = "runtime"
    ) async {
        switch event {
        case .turnStarted:
            await publishPayload(
                RuntimeLifecycleEventPayload(
                    name: .turnStarted,
                    conversationID: conversationID,
                    runID: runID,
                    source: source
                )
            )
        case .loopIterationStarted(let iteration, let modelID):
            await publishPayload(
                RuntimeLifecycleEventPayload(
                    name: .loopIterationStarted,
                    conversationID: conversationID,
                    runID: runID,
                    iteration: iteration,
                    modelID: modelID,
                    source: source
                )
            )
        case .loopIterationCompleted(let iteration, let modelID):
            await publishPayload(
                RuntimeLifecycleEventPayload(
                    name: .loopIterationCompleted,
                    conversationID: conversationID,
                    runID: runID,
                    iteration: iteration,
                    modelID: modelID,
                    source: source
                )
            )
        case .modelCallStarted(let iteration, let modelID):
            await publishPayload(
                RuntimeLifecycleEventPayload(
                    name: .modelCallStarted,
                    conversationID: conversationID,
                    runID: runID,
                    iteration: iteration,
                    modelID: modelID,
                    source: source
                )
            )
        case .modelCallCompleted(let iteration, let modelID, let usage):
            await publishPayload(
                RuntimeLifecycleEventPayload(
                    name: .modelCallCompleted,
                    conversationID: conversationID,
                    runID: runID,
                    iteration: iteration,
                    modelID: modelID,
                    toolName: usage == nil ? nil : RuntimeLifecycleModelCompletionAudit.toolName,
                    toolCallID: usage == nil
                        ? nil
                        : RuntimeLifecycleModelCompletionAudit.correlationID(runID: runID, iteration: iteration),
                    usage: usage,
                    source: source
                )
            )
        case .toolCallStarted(let iteration, let modelID, let toolName, let toolCallID):
            await publishPayload(
                RuntimeLifecycleEventPayload(
                    name: .toolCallStarted,
                    conversationID: conversationID,
                    runID: runID,
                    iteration: iteration,
                    modelID: modelID,
                    toolName: toolName,
                    toolCallID: toolCallID,
                    source: source
                )
            )
        case .toolCallCompleted(let iteration, let modelID, let toolName, let toolCallID, let resultTruncated):
            await publishPayload(
                RuntimeLifecycleEventPayload(
                    name: .toolCallCompleted,
                    conversationID: conversationID,
                    runID: runID,
                    iteration: iteration,
                    modelID: modelID,
                    toolName: toolName,
                    toolCallID: toolCallID,
                    resultTruncated: resultTruncated,
                    source: source
                )
            )
        case .toolCallFailed(
            let iteration,
            let modelID,
            let toolName,
            let toolCallID,
            let errorClass,
            let message,
            let elapsedMs,
            let mcpServerName
        ):
            await publishPayload(
                RuntimeLifecycleEventPayload(
                    name: .toolCallFailed,
                    conversationID: conversationID,
                    runID: runID,
                    iteration: iteration,
                    modelID: modelID,
                    toolName: toolName,
                    policyReason: errorClass,
                    toolCallID: toolCallID,
                    summaryText: message,
                    errorClass: errorClass,
                    elapsedMs: elapsedMs,
                    mcpServerName: mcpServerName,
                    source: source
                )
            )
        case .toolApprovalRequired(let info):
            await publishPayload(
                RuntimeLifecycleEventPayload(
                    name: .toolApprovalRequired,
                    conversationID: conversationID,
                    runID: runID,
                    iteration: info.iteration,
                    modelID: info.modelID,
                    toolName: info.toolName,
                    approvalState: .pending,
                    policyReason: ToolAvailabilityBlockReason.approvalRequired.rawValue,
                    approvalRoute: info.route,
                    approvalTitle: info.title,
                    approvalDescription: info.description,
                    approvalSeverity: info.severity,
                    approvalTimeoutMs: info.timeoutMs,
                    approvalTimeoutBehavior: info.timeoutBehavior,
                    approvalResolutionKind: info.resolutionKind,
                    approvalPresentation: info.presentation,
                    toolCallID: info.toolCallID,
                    source: info.source
                )
            )
        case .toolApprovalResolved(let info):
            await publishPayload(
                RuntimeLifecycleEventPayload(
                    name: .toolApprovalResolved,
                    conversationID: conversationID,
                    runID: runID,
                    iteration: info.iteration,
                    modelID: info.modelID,
                    toolName: info.toolName,
                    approvalState: info.approvalState,
                    policyReason: info.policyReason,
                    approvalSource: info.approvalSource,
                    approvalReason: info.approvalReason,
                    approvalRoute: info.route,
                    approvalTitle: info.title,
                    approvalDescription: info.description,
                    approvalSeverity: info.severity,
                    approvalTimeoutMs: info.timeoutMs,
                    approvalTimeoutBehavior: info.timeoutBehavior,
                    approvalResolutionKind: info.resolutionKind,
                    approvalPresentation: info.presentation,
                    toolCallID: info.toolCallID,
                    source: info.source
                )
            )
        case .turnTerminal(let reason):
            await publishPayload(
                RuntimeLifecycleEventPayload(
                    name: Self.terminalEventName(for: reason),
                    conversationID: conversationID,
                    runID: runID,
                    terminalReason: reason,
                    source: source
                )
            )
        }
    }

    private func publishPayload(_ payload: RuntimeLifecycleEventPayload) async {
        await publish(payload.conversationID, payload)
    }

    static func terminalEventName(for reason: ConversationRunTerminalReason?) -> RuntimeLifecycleEventName {
        switch reason?.category {
        case .externalCancellation:
            return .turnCancelled
        case .boundedStop:
            return .turnBounded
        default:
            return .turnCompleted
        }
    }
}

/// How a main-loop completion is made to fit a row type shaped for tool calls.
///
/// The audit row (`ToolAuditLifecycleEventPayload`) requires a non-optional `toolName`, and the
/// usage rollup deduplicates on `completionAnnounceID` → `toolCallID` → the row's own event id. A
/// model completion has neither of the first two naturally, and the third tier deduplicates nothing
/// — every persisted row is a distinct event id, so a replayed or re-published event would be
/// counted twice and silently inflate the run's cost.
///
/// So the emitter synthesizes both: a fixed tool name, and a deterministic correlation id from
/// `(runID, iteration)`. `iteration` is the turn loop's `for iteration in 1...maxIterations`
/// counter, and `.modelCallCompleted` fires at most once per value — the compaction-retry path
/// continues the outer loop rather than repeating a number — so the pair identifies a completion
/// exactly once and re-publishing is idempotent.
///
/// The cleaner alternative is a dedicated `model_usage_event` derived-artifact kind, which needs a
/// contract-matrix entry, a persister, a codec path and a second loop in the rollup. Recorded as
/// debt rather than paid here.
enum RuntimeLifecycleModelCompletionAudit {
    /// Deliberately not a real tool name, and deliberately greppable — it will show up in trace-span
    /// attributes and in anything that groups audit rows by tool.
    static let toolName = "model_completion"

    static func correlationID(runID: UUID?, iteration: Int) -> String {
        "model:\(runID?.uuidString.lowercased() ?? "no-run"):\(iteration)"
    }
}
