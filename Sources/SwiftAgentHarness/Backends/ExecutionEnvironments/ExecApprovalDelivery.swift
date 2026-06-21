import EasyJSON
import Foundation

public struct ExecApprovalRequest: Sendable, Equatable {
    public let id: String
    public let command: String
    public let title: String
    public let description: String
}

public enum ExecApprovalDeliveryResult: Sendable, Equatable {
    case approved
    case denied(String)
    case headlessDenied(String)
    case deferred(String)
}

public protocol ExecApprovalDelivering: Sendable {
    func requestApproval(_ request: ExecApprovalRequest, headless: Bool) async -> ExecApprovalDeliveryResult
    func sendFollowup(approvalID: String, approved: Bool) async
}

struct ExecApprovalChannelRoute: Sendable {
    let listener: any ChannelListener
    let chatId: String
    let threadId: String?

    init(listener: any ChannelListener, chatId: String, threadId: String?) {
        self.listener = listener
        self.chatId = chatId
        self.threadId = threadId
    }
}

public struct DefaultExecApprovalDelivery: ExecApprovalDelivering {
    private let store: ExecApprovalStore
    private let waitTimeoutSeconds: TimeInterval
    private let onPending: (@Sendable (ExecApprovalRequest) async -> Void)?

    public init(
        store: ExecApprovalStore = .shared,
        waitTimeoutSeconds: TimeInterval = 300,
        onPending: (@Sendable (ExecApprovalRequest) async -> Void)? = nil
    ) {
        self.store = store
        self.waitTimeoutSeconds = waitTimeoutSeconds
        self.onPending = onPending
    }

    public func requestApproval(_ request: ExecApprovalRequest, headless: Bool) async -> ExecApprovalDeliveryResult {
        if headless {
            return .headlessDenied("Approval required for exec in headless mode: \(request.command)")
        }
        if await store.isDurableApproved(command: request.command) {
            return .approved
        }
        await store.registerPending(id: request.id, command: request.command)
        await onPending?(request)
        if let resolution = await store.waitForResolution(id: request.id, timeoutSeconds: waitTimeoutSeconds) {
            switch resolution {
            case .approved:
                return .approved
            case .denied(let reason):
                return .denied(reason)
            }
        }
        return .denied("exec approval timed out")
    }

    public func sendFollowup(approvalID: String, approved: Bool) async {}
}

struct ChannelExecApprovalDelivery: ExecApprovalDelivering {
    private let store: ExecApprovalStore
    private let route: ExecApprovalChannelRoute?
    private let waitTimeoutSeconds: TimeInterval

    init(
        store: ExecApprovalStore = .shared,
        route: ExecApprovalChannelRoute?,
        waitTimeoutSeconds: TimeInterval = 300
    ) {
        self.store = store
        self.route = route
        self.waitTimeoutSeconds = waitTimeoutSeconds
    }

    func requestApproval(_ request: ExecApprovalRequest, headless: Bool) async -> ExecApprovalDeliveryResult {
        if headless {
            return .headlessDenied("Approval required for exec in headless mode: \(request.command)")
        }
        if await store.isDurableApproved(command: request.command) {
            return .approved
        }
        await store.registerPending(id: request.id, command: request.command)
        guard let route else {
            return .deferred("Use /approve \(request.id)")
        }
        let card = ChannelOutboundApprovalCard(
            approvalID: request.id,
            title: request.title,
            command: request.command,
            description: request.description,
            actions: [
                ChannelOutboundApprovalAction(id: "approve", label: "Approve"),
                ChannelOutboundApprovalAction(id: "deny", label: "Deny"),
            ]
        )
        let fallbackText = "Exec approval required for:\n\(request.command)\nUse /approve \(request.id)"
        let sendResult = await route.listener.send(
            ChannelOutboundMessage(
                chatId: route.chatId,
                threadId: route.threadId,
                text: fallbackText,
                replyToMessageId: nil,
                approvalCard: card
            )
        )
        guard case .sent = sendResult else {
            return .deferred("Use /approve \(request.id)")
        }
        if let resolution = await store.waitForResolution(id: request.id, timeoutSeconds: waitTimeoutSeconds) {
            switch resolution {
            case .approved:
                return .approved
            case .denied(let reason):
                return .denied(reason)
            }
        }
        return .deferred("Use /approve \(request.id)")
    }

    func sendFollowup(approvalID: String, approved: Bool) async {
        guard let route else { return }
        let text = approved
            ? "Exec approval \(approvalID) approved."
            : "Exec approval \(approvalID) denied."
        _ = await route.listener.send(
            ChannelOutboundMessage(
                chatId: route.chatId,
                threadId: route.threadId,
                text: text,
                replyToMessageId: nil,
                approvalCard: nil
            )
        )
    }
}

enum ExecApprovalDeliveryFactory {
    static func make(
        channelRegistry: (any ChannelListenerLooking)?,
        metadata: JSON?,
        onPending: (@Sendable (ExecApprovalRequest) async -> Void)? = nil
    ) async -> any ExecApprovalDelivering {
        guard let trigger = TriggerHostConversationMetadata.triggerFromFingerprint(metadata),
              let channelRaw = trigger.sourceMetadata["channel"],
              let channel = ChannelId(rawValue: channelRaw),
              let chatId = trigger.sourceMetadata["chatId"],
              !chatId.isEmpty,
              let channelRegistry,
              let listener = await channelRegistry.listener(for: channel)
        else {
            return DefaultExecApprovalDelivery(onPending: onPending)
        }
        let route = ExecApprovalChannelRoute(
            listener: listener,
            chatId: chatId,
            threadId: trigger.sourceMetadata["threadId"]
        )
        return ChannelExecApprovalDelivery(route: route)
    }
}
