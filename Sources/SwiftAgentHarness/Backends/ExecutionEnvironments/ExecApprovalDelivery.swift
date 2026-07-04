import EasyJSON
import Foundation

public struct ExecApprovalRequest: Sendable, Equatable {
    public let id: String
    public let command: String
    public let title: String
    public let description: String
    /// When false, name-scoped durable grants must not bypass approval (elevated/host exec).
    public let allowsDurableBypass: Bool
    /// Portable presentation a surface renders natively (and core degrades to text).
    public let presentation: ApprovalPresentation

    public init(
        id: String,
        command: String,
        title: String,
        description: String,
        allowsDurableBypass: Bool = true,
        presentation: ApprovalPresentation? = nil
    ) {
        self.id = id
        self.command = command
        self.title = title
        self.description = description
        self.allowsDurableBypass = allowsDurableBypass
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

struct ExecApprovalPluginRoute: Sendable {
    let approval: any ChannelApprovalCapabilityAdapting
    let outbound: any ChannelOutboundAdapting
    let target: ChannelDeliveryTarget
}

struct PluginChannelExecApprovalDelivery: ExecApprovalDelivering {
    private let store: ExecApprovalStore
    private let approvalScope: ExecApprovalScope
    private let route: ExecApprovalPluginRoute?
    private let waitTimeoutSeconds: TimeInterval

    init(
        store: ExecApprovalStore = .shared,
        approvalScope: ExecApprovalScope,
        route: ExecApprovalPluginRoute?,
        waitTimeoutSeconds: TimeInterval = 300
    ) {
        self.store = store
        self.approvalScope = approvalScope
        self.route = route
        self.waitTimeoutSeconds = waitTimeoutSeconds
    }

    func requestApproval(_ request: ExecApprovalRequest, headless: Bool) async -> ExecApprovalDeliveryResult {
        if headless {
            return .headlessDenied("Approval required for exec in headless mode: \(request.command)")
        }
        if request.allowsDurableBypass,
           await store.isDurableApproved(command: request.command) {
            return .approved
        }
        await store.registerPending(
            id: request.id,
            command: request.command,
            scope: approvalScope,
            allowsDurableBypass: request.allowsDurableBypass,
            presentation: request.presentation
        )
        guard let route else {
            return .deferred(request.presentation.textFallback(approvalID: request.id))
        }
        let sendResult = await route.approval.deliverApproval(
            presentation: request.presentation,
            approvalID: request.id,
            command: request.command,
            target: route.target
        )
        guard case .sent = sendResult else {
            return .deferred(request.presentation.textFallback(approvalID: request.id))
        }
        if let resolution = await store.waitForResolution(id: request.id, timeoutSeconds: waitTimeoutSeconds) {
            switch resolution {
            case .approved:
                return .approved
            case .denied(let reason):
                return .denied(reason)
            }
        }
        return .deferred(request.presentation.textFallback(approvalID: request.id))
    }

    func sendFollowup(approvalID: String, approved: Bool) async {
        guard let route else { return }
        let text = approved
            ? "Exec approval \(approvalID) approved."
            : "Exec approval \(approvalID) denied."
        let payload = ChannelRenderedPayload(text: text, approvalCard: nil)
        _ = await route.outbound.sendPayload(payload, target: route.target)
    }
}

enum ExecApprovalDeliveryFactory {
    static func make(
        scope: ExecApprovalScope,
        channelRegistry: (any ChannelPluginLooking)?,
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
              let plugin = await channelRegistry.plugin(for: channel),
              let approval = plugin.approvalCapability
        else {
            return DefaultExecApprovalDelivery(
                approvalScope: scope,
                onPending: onPending,
                onCleared: onCleared
            )
        }
        let route = ExecApprovalPluginRoute(
            approval: approval,
            outbound: plugin.outbound,
            target: ChannelDeliveryTarget(
                chatId: chatId,
                threadId: trigger.sourceMetadata["threadId"],
                replyToMessageId: trigger.sourceMetadata["platformMessageId"]
            )
        )
        return PluginChannelExecApprovalDelivery(approvalScope: scope, route: route)
    }
}

public struct DefaultExecApprovalDelivery: ExecApprovalDelivering {
    private let store: ExecApprovalStore
    private let approvalScope: ExecApprovalScope
    private let waitTimeoutSeconds: TimeInterval?
    private let onPending: (@Sendable (ExecApprovalRequest) async -> Void)?
    private let onCleared: (@Sendable (String) async -> Void)?

    public init(
        store: ExecApprovalStore = .shared,
        approvalScope: ExecApprovalScope,
        waitTimeoutSeconds: TimeInterval? = nil,
        onPending: (@Sendable (ExecApprovalRequest) async -> Void)? = nil,
        onCleared: (@Sendable (String) async -> Void)? = nil
    ) {
        self.store = store
        self.approvalScope = approvalScope
        self.waitTimeoutSeconds = waitTimeoutSeconds
        self.onPending = onPending
        self.onCleared = onCleared
    }

    public func requestApproval(_ request: ExecApprovalRequest, headless: Bool) async -> ExecApprovalDeliveryResult {
        if headless {
            return .headlessDenied("Approval required for exec in headless mode: \(request.command)")
        }
        if request.allowsDurableBypass,
           await store.isDurableApproved(command: request.command) {
            return .approved
        }
        await store.registerPending(
            id: request.id,
            command: request.command,
            scope: approvalScope,
            allowsDurableBypass: request.allowsDurableBypass,
            presentation: request.presentation
        )
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
