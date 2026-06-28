import Foundation

struct TriggerAuthorizationContext: Sendable {
    var routeEnabled: Bool
    var sourceAllowed: Bool

    static let allowed = TriggerAuthorizationContext(routeEnabled: true, sourceAllowed: true)
}

struct TriggerActivationPolicy: Sendable {
    let idempotency: TriggerIdempotencyGate
    let rateLimit: TriggerRateLimitGate
    let costCeiling: TriggerCostCeilingGate
    let auditLog: TriggerAuditLog
    let rateLimitKey: @Sendable (HarnessTrigger) -> String
    let initiatorKey: @Sendable (HarnessTrigger) -> String
    let authorize: @Sendable (HarnessTrigger) -> TriggerAuthorizationContext

    init(
        idempotency: TriggerIdempotencyGate,
        rateLimit: TriggerRateLimitGate,
        costCeiling: TriggerCostCeilingGate,
        auditLog: TriggerAuditLog,
        rateLimitKey: @escaping @Sendable (HarnessTrigger) -> String = { $0.sourceMetadata["routeName"] ?? $0.source.rawValue },
        initiatorKey: @escaping @Sendable (HarnessTrigger) -> String = { $0.initiator.id ?? $0.source.rawValue },
        authorize: @escaping @Sendable (HarnessTrigger) -> TriggerAuthorizationContext = { _ in .allowed }
    ) {
        self.idempotency = idempotency
        self.rateLimit = rateLimit
        self.costCeiling = costCeiling
        self.auditLog = auditLog
        self.rateLimitKey = rateLimitKey
        self.initiatorKey = initiatorKey
        self.authorize = authorize
    }

    func evaluate(_ trigger: HarnessTrigger) async throws -> TriggerActivationDecision {
        let auth = authorize(trigger)
        guard auth.routeEnabled, auth.sourceAllowed else {
            audit(trigger, decision: .unauthorized)
            return .unauthorized
        }
        if try await !idempotency.claimTrigger(triggerID: trigger.id) {
            audit(trigger, decision: .dedupHit)
            return .dedupHit
        }
        let rateKey = rateLimitKey(trigger)
        if await rateLimit.isRateLimited(key: rateKey) {
            audit(trigger, decision: .rateLimited)
            return .rateLimited
        }
        let initKey = initiatorKey(trigger)
        if await costCeiling.isOverBudget(initiatorKey: initKey) {
            audit(trigger, decision: .overBudget)
            return .overBudget
        }
        audit(trigger, decision: .admitted)
        return .admitted
    }

    private func audit(_ trigger: HarnessTrigger, decision: TriggerActivationDecision) {
        auditLog.record(TriggerAuditEntry.from(trigger: trigger, decision: decision))
    }
}
