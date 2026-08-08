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
    let target: ChannelDeliveryTarget
    private let resolveApproval: @Sendable () async -> (any ChannelApprovalCapabilityAdapting)?
    private let resolveOutbound: @Sendable () async -> (any ChannelOutboundAdapting)?

    /// Fixed adapters, resolved by the caller.
    ///
    /// No production caller: everything that ships goes through the resolving init below, which is
    /// what makes pause and teardown take effect mid-conversation. Retained for tests that exercise
    /// the delivery in isolation, without a registry.
    init(
        approval: any ChannelApprovalCapabilityAdapting,
        outbound: any ChannelOutboundAdapting,
        target: ChannelDeliveryTarget
    ) {
        self.target = target
        resolveApproval = { approval }
        resolveOutbound = { outbound }
    }

    /// Resolve the channel's plugin on **every** send.
    ///
    /// This delivery is built once per conversation and held for its lifetime, so capturing
    /// `plugin.approvalCapability` and `plugin.outbound` up front meant an exec-approval prompt kept
    /// going to a channel that had since been paused or torn down — a stored reference quietly
    /// bypassing the "outbound is armed exactly while the listener is running" invariant the registry
    /// enforces everywhere else. `outboundPlugin(for:)` is the question actually being asked: may the
    /// agent send there right now.
    init(channel: ChannelId, target: ChannelDeliveryTarget, registry: any ChannelPluginLooking) {
        self.target = target
        resolveApproval = { await registry.outboundPlugin(for: channel)?.approvalCapability }
        resolveOutbound = { await registry.outboundPlugin(for: channel)?.outbound }
    }

    func approval() async -> (any ChannelApprovalCapabilityAdapting)? {
        await resolveApproval()
    }

    func outbound() async -> (any ChannelOutboundAdapting)? {
        await resolveOutbound()
    }
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
        guard let approval = await route.approval() else {
            // The channel went away, or was paused, between building this delivery and needing it.
            // Falling back to the text approval flow is the same answer as having had no channel at
            // all, which is the honest one.
            return .deferred(request.presentation.textFallback(approvalID: request.id))
        }
        let sendResult = await approval.deliverApproval(
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
        guard let outbound = await route.outbound() else { return }
        _ = await outbound.sendPayload(payload, target: route.target)
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
              // A probe, not a binding: this decides whether the channel supports native approval
              // delivery at all. The adapter itself is re-resolved on every send, below.
              plugin.approvalCapability != nil
        else {
            return DefaultExecApprovalDelivery(
                approvalScope: scope,
                onPending: onPending,
                onCleared: onCleared
            )
        }
        let route = ExecApprovalPluginRoute(
            channel: channel,
            target: ChannelDeliveryTarget(
                chatId: chatId,
                threadId: trigger.sourceMetadata["threadId"],
                replyToMessageId: trigger.sourceMetadata["platformMessageId"]
            ),
            registry: channelRegistry
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
