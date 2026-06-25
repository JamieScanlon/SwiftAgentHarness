import EasyJSON
import Foundation

public struct ExecApprovalRequest: Sendable, Equatable {
    public let id: String
    public let command: String
    public let title: String
    public let description: String
    /// Portable presentation a surface renders natively (and core degrades to text).
    public let presentation: ApprovalPresentation

    public init(
        id: String,
        command: String,
        title: String,
        description: String,
        presentation: ApprovalPresentation? = nil
    ) {
        self.id = id
        self.command = command
        self.title = title
        self.description = description
        self.presentation = presentation ?? ApprovalPresentation.standard(
            title: title,
            context: [command, description == command ? "" : description]
        )
    }
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
    private let waitTimeoutSeconds: TimeInterval?
    private let onPending: (@Sendable (ExecApprovalRequest) async -> Void)?
    private let onCleared: (@Sendable (String) async -> Void)?

    public init(
        store: ExecApprovalStore = .shared,
        waitTimeoutSeconds: TimeInterval? = nil,
        onPending: (@Sendable (ExecApprovalRequest) async -> Void)? = nil,
        onCleared: (@Sendable (String) async -> Void)? = nil
    ) {
        self.store = store
        self.waitTimeoutSeconds = waitTimeoutSeconds
        self.onPending = onPending
        self.onCleared = onCleared
    }

    public func requestApproval(_ request: ExecApprovalRequest, headless: Bool) async -> ExecApprovalDeliveryResult {
        if headless {
            return .headlessDenied("Approval required for exec in headless mode: \(request.command)")
        }
        if await store.isDurableApproved(command: request.command) {
            return .approved
        }
        await store.registerPending(id: request.id, command: request.command, presentation: request.presentation)
        await onPending?(request)
        if let resolution = await store.waitForResolution(id: request.id, timeoutSeconds: waitTimeoutSeconds) {
            switch resolution {
            case .approved:
                return .approved
            case .denied(let reason):
                return .denied(reason)
            }
        }
        // With the indefinite default, a `nil` resolution only happens when the
        // awaiting run is stopped/cancelled. Notify so the surface can dismiss the
        // stale prompt.
        await onCleared?(request.id)
        return .denied("exec approval cancelled")
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
        await store.registerPending(id: request.id, command: request.command, presentation: request.presentation)
        guard let route else {
            return .deferred(request.presentation.textFallback(approvalID: request.id))
        }
        let card = ChannelOutboundApprovalCard(
            approvalID: request.id,
            title: request.title,
            command: request.command,
            description: request.description,
            actions: request.presentation.buttons.map {
                ChannelOutboundApprovalAction(id: $0.id, label: $0.label)
            }
        )
        let fallbackText = request.presentation.textFallback(approvalID: request.id)
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
            return .deferred(fallbackText)
        }
        if let resolution = await store.waitForResolution(id: request.id, timeoutSeconds: waitTimeoutSeconds) {
            switch resolution {
            case .approved:
                return .approved
            case .denied(let reason):
                return .denied(reason)
            }
        }
        return .deferred(fallbackText)
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
        onPending: (@Sendable (ExecApprovalRequest) async -> Void)? = nil,
        onCleared: (@Sendable (String) async -> Void)? = nil
    ) async -> any ExecApprovalDelivering {
        guard let trigger = TriggerHostConversationMetadata.triggerFromFingerprint(metadata),
              let channelRaw = trigger.sourceMetadata["channel"],
              let channel = ChannelId(rawValue: channelRaw),
              let chatId = trigger.sourceMetadata["chatId"],
              !chatId.isEmpty,
              let channelRegistry,
              let listener = await channelRegistry.listener(for: channel)
        else {
            return DefaultExecApprovalDelivery(onPending: onPending, onCleared: onCleared)
        }
        let route = ExecApprovalChannelRoute(
            listener: listener,
            chatId: chatId,
            threadId: trigger.sourceMetadata["threadId"]
        )
        return ChannelExecApprovalDelivery(route: route)
    }
}
