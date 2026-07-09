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
    case modelCallCompleted(iteration: Int, modelID: UUID)
    case toolCallStarted(iteration: Int, modelID: UUID, toolName: String, toolCallID: String?)
    case toolCallCompleted(
        iteration: Int,
        modelID: UUID,
        toolName: String,
        toolCallID: String?,
        resultTruncated: Bool? = nil
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
        case .modelCallCompleted(let iteration, let modelID):
            await publishPayload(
                RuntimeLifecycleEventPayload(
                    name: .modelCallCompleted,
                    conversationID: conversationID,
                    runID: runID,
                    iteration: iteration,
                    modelID: modelID,
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
