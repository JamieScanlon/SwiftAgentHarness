import Foundation

/// Maps an inbound approval action (a native card button click, or a normalized
/// channel reply) back onto the unified decision vocabulary and resolves the exec
/// approval. This is the surface-side "report the decision back" seam; the
/// classification and lifecycle remain core-owned.
public enum ExecApprovalInbound {
    @discardableResult
    public static func resolve(
        approvalID: String,
        actionID: String,
        scope: ExecApprovalScope,
        strictTenancy: Bool,
        ownerScope: UUID?,
        store: ExecApprovalStore = .shared,
        reason: String? = nil
    ) async -> ExecApprovalResolution? {
        guard let decision = ApprovalDecision.fromToken(actionID) else { return nil }
        switch decision {
        case .allowOnce:
            return await store.resolve(
                id: approvalID,
                scope: scope,
                strictTenancy: strictTenancy,
                ownerScope: ownerScope,
                approved: true,
                durable: false
            )
        case .allowAlways:
            return await store.resolve(
                id: approvalID,
                scope: scope,
                strictTenancy: strictTenancy,
                ownerScope: ownerScope,
                approved: true,
                durable: true
            )
        case .deny, .timeout, .cancelled:
            return await store.resolve(
                id: approvalID,
                scope: scope,
                strictTenancy: strictTenancy,
                ownerScope: ownerScope,
                approved: false,
                reason: reason ?? "denied"
            )
        }
    }
}
