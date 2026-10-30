import Foundation

/// A computer-use specialist waiting on the user.
public struct ComputerUsePendingRequest: Sendable, Codable, Equatable {
    public var id: String
    public var kind: ComputerUseSurfaceIntentPayload.RequestKind
    /// The user's conversation: the parent that delegated the task.
    public var conversationID: UUID
    public var lifecycleID: String?
    public var prompt: String
    public var reason: String?
    public var target: String
    public var createdAt: Date
}

public enum ComputerUseRequestResolution: Sendable, Equatable {
    case answered(String)
    case handedBack(note: String?)
    case declined
    case timedOut
}

/// Pending questions and handoffs across all computer-use sessions. Each is published to the user's conversation
/// as a surface intent and blocks the specialist until a client answers through the control plane.
actor ComputerUseOversightCoordinator {
    typealias Publish = @Sendable (UUID, ClientSurfaceIntent) async -> Void

    private let publish: Publish
    private let questionTimeout: Duration
    private let handoffTimeout: Duration
    private var requests: [String: ComputerUsePendingRequest] = [:]
    private var waiters: [String: CheckedContinuation<ComputerUseRequestResolution, Never>] = [:]
    /// Resolutions that arrived before the waiter registered: a client can answer while the request is still
    /// being published.
    private var early: [String: ComputerUseRequestResolution] = [:]

    init(publish: @escaping Publish, questionTimeout: Duration = .seconds(600), handoffTimeout: Duration = .seconds(1_800)) {
        self.publish = publish
        self.questionTimeout = questionTimeout
        self.handoffTimeout = handoffTimeout
    }

    func pending(conversationID: UUID) -> [ComputerUsePendingRequest] {
        requests.values.filter { $0.conversationID == conversationID }.sorted { $0.createdAt < $1.createdAt }
    }

    func ask(conversationID: UUID, lifecycleID: String?, target: String, question: String) async -> ComputerUseRequestResolution {
        await wait(for: ComputerUsePendingRequest(
            id: "cu-q-\(UUID().uuidString.lowercased())",
            kind: .question,
            conversationID: conversationID,
            lifecycleID: lifecycleID,
            prompt: question,
            reason: nil,
            target: target,
            createdAt: Date()
        ), timeout: questionTimeout)
    }

    func handoff(conversationID: UUID, lifecycleID: String?, target: String, request: ComputerUseHandoffRequest) async -> ComputerUseRequestResolution {
        await wait(for: ComputerUsePendingRequest(
            id: "cu-h-\(UUID().uuidString.lowercased())",
            kind: .handoff,
            conversationID: conversationID,
            lifecycleID: lifecycleID,
            prompt: request.prompt,
            reason: request.reason.rawValue,
            target: target,
            createdAt: Date()
        ), timeout: handoffTimeout)
    }

    /// A client's answer. Rejected for an unknown id, another conversation, or a resolution of the wrong kind.
    @discardableResult
    func resolve(id: String, conversationID: UUID, resolution: ComputerUseRequestResolution) async -> Bool {
        guard let request = requests[id], request.conversationID == conversationID else { return false }
        switch (request.kind, resolution) {
        case (.question, .answered), (.question, .declined), (.handoff, .handedBack), (.handoff, .declined):
            await finish(id, resolution)
            return true
        default:
            return false
        }
    }

    private func wait(for request: ComputerUsePendingRequest, timeout: Duration) async -> ComputerUseRequestResolution {
        requests[request.id] = request
        await publish(request.conversationID, .computerUseRequest(ComputerUseSurfaceIntentPayload(
            requestID: request.id,
            requestKind: request.kind,
            prompt: request.prompt,
            reason: request.reason,
            target: request.target,
            lifecycleID: request.lifecycleID
        )))
        let id = request.id
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.finish(id, .timedOut)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let resolution = early.removeValue(forKey: id) {
                    continuation.resume(returning: resolution)
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.finish(id, .declined) }
        }
    }

    private func finish(_ id: String, _ resolution: ComputerUseRequestResolution) async {
        guard let request = requests.removeValue(forKey: id) else { return }
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume(returning: resolution)
        } else {
            early[id] = resolution
        }
        await publish(request.conversationID, .computerUseRequestCleared(requestID: id, lifecycleID: request.lifecycleID))
    }
}

/// ``ComputerUseOversight`` for one specialist run, answering through its parent conversation.
struct ComputerUseConversationOversight: ComputerUseOversight {
    let coordinator: ComputerUseOversightCoordinator
    let conversationID: UUID
    let lifecycleID: String?
    let targetLabel: String

    func askUser(_ question: String) async -> ComputerUseUserReply {
        switch await coordinator.ask(conversationID: conversationID, lifecycleID: lifecycleID, target: targetLabel, question: question) {
        case .answered(let answer): return .answered(answer)
        case .handedBack, .declined, .timedOut: return .unavailable
        }
    }

    func handoff(_ request: ComputerUseHandoffRequest) async -> ComputerUseHandoffResult {
        switch await coordinator.handoff(conversationID: conversationID, lifecycleID: lifecycleID, target: targetLabel, request: request) {
        case .handedBack(let note): return .handedBack(note: note)
        case .declined, .timedOut, .answered: return .declined
        }
    }
}

/// Pauses the specialist's idle clock while the user is asked something or doing a human-only step.
struct ComputerUseLivenessOversight: ComputerUseOversight {
    let base: any ComputerUseOversight
    let liveness: LocalAgentLiveness

    func askUser(_ question: String) async -> ComputerUseUserReply {
        liveness.pause()
        defer { liveness.resume() }
        return await base.askUser(question)
    }

    func handoff(_ request: ComputerUseHandoffRequest) async -> ComputerUseHandoffResult {
        liveness.pause()
        defer { liveness.resume() }
        return await base.handoff(request)
    }

    func continuePastCeiling(_ question: ComputerUseCeilingQuestion) async -> Bool {
        liveness.pause()
        defer { liveness.resume() }
        return await base.continuePastCeiling(question)
    }
}

/// Pauses the specialist's idle clock while a consequential action waits on the user's confirmation.
struct ComputerUseLivenessApprovals: ExecApprovalDelivering {
    let base: any ExecApprovalDelivering
    let liveness: LocalAgentLiveness

    func requestApproval(_ request: ExecApprovalRequest, headless: Bool) async -> ExecApprovalDeliveryResult {
        liveness.pause()
        defer { liveness.resume() }
        return await base.requestApproval(request, headless: headless)
    }

    func sendFollowup(approvalID: String, approved: Bool) async {
        await base.sendFollowup(approvalID: approvalID, approved: approved)
    }
}
