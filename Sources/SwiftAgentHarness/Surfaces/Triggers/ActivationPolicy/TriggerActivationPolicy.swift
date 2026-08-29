import Foundation

struct TriggerAuthorizationContext: Sendable {
    var routeEnabled: Bool
    var sourceAllowed: Bool

    static let allowed = TriggerAuthorizationContext(routeEnabled: true, sourceAllowed: true)
}

struct TriggerActivationPolicy: Sendable {
    let idempotency: TriggerIdempotencyGate
    let rateLimit: TriggerRateLimitGate
    /// Per-initiator burst cap, denominated in *fires*. Cheap O(1) pre-filter.
    let initiatorBurst: TriggerInitiatorBurstGate
    /// Stage 4 proper, denominated in *spend*. `nil` disables the ledger entirely.
    let budget: TriggerBudgetGate?
    let auditLog: TriggerAuditLog
    let rateLimitKey: @Sendable (HarnessTrigger) -> String
    let initiatorKey: @Sendable (HarnessTrigger) -> String
    let authorize: @Sendable (HarnessTrigger) -> TriggerAuthorizationContext

    init(
        idempotency: TriggerIdempotencyGate,
        rateLimit: TriggerRateLimitGate,
        initiatorBurst: TriggerInitiatorBurstGate,
        budget: TriggerBudgetGate? = nil,
        auditLog: TriggerAuditLog,
        // Source-prefixed: the webhook validation gate already consumed the bare route-name bucket
        // with the route's own `rateLimitPerMin`. Sharing one key made every admitted delivery
        // record two hits, silently halving the configured limit.
        rateLimitKey: @escaping @Sendable (HarnessTrigger) -> String = {
            guard let routeName = $0.sourceMetadata["routeName"], !routeName.isEmpty else {
                return $0.source.rawValue
            }
            return "\($0.source.rawValue):\(routeName)"
        },
        initiatorKey: @escaping @Sendable (HarnessTrigger) -> String = { $0.initiator.id ?? $0.source.rawValue },
        authorize: @escaping @Sendable (HarnessTrigger) -> TriggerAuthorizationContext = { _ in .allowed }
    ) {
        self.idempotency = idempotency
        self.rateLimit = rateLimit
        self.initiatorBurst = initiatorBurst
        self.budget = budget
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
        if await initiatorBurst.isOverBurstLimit(initiatorKey: initKey) {
            audit(trigger, decision: .overBudget)
            return .overBudget
        }
        // Fires are not a cost proxy: 30/min under an unbounded `agentTurn` is not a bounded bill.
        // The ledger is the gate that speaks the right unit.
        if let budget, case .refuse = await budget.admit(trigger) {
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
