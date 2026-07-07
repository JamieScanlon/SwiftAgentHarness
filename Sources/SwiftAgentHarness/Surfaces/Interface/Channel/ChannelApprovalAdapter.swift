import Foundation

public struct ChannelApprovalCapabilityAdapter: ChannelApprovalCapabilityAdapting {
    let outbound: any ChannelOutboundAdapting

    public init(outbound: any ChannelOutboundAdapting) {
        self.outbound = outbound
    }

    public func deliverApproval(
        presentation: ApprovalPresentation,
        approvalID: String,
        command: String,
        target: ChannelDeliveryTarget
    ) async -> ChannelSendResult {
        let messagePresentation = presentation.asMessagePresentation(title: nil)
        let card = ChannelOutboundApprovalCard(
            approvalID: approvalID,
            title: messagePresentation.title ?? "Approval required",
            command: command,
            description: messagePresentation.textFallback(),
            actions: presentation.buttons.map { ChannelOutboundApprovalAction(id: $0.id, label: $0.label) }
        )
        let fallbackText = presentation.textFallback(approvalID: approvalID)
        let payload = ChannelRenderedPayload(text: fallbackText, approvalCard: card)
        return await outbound.sendPayload(payload, target: target)
    }
}
