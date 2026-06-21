import Foundation
import SwiftAgentKit

struct BudgetLedgerHydrationSeed: Sendable {
    let conversationID: UUID
    let parentConversationID: UUID?
    let ownerAccountID: UUID?
    let spentUSD: Double
    let maxUSD: Double?

    init(
        conversationID: UUID,
        parentConversationID: UUID?,
        ownerAccountID: UUID?,
        spentUSD: Double,
        maxUSD: Double? = nil
    ) {
        self.conversationID = conversationID
        self.parentConversationID = parentConversationID
        self.ownerAccountID = ownerAccountID
        self.spentUSD = spentUSD
        self.maxUSD = maxUSD
    }
}

protocol DelegateCostTracking: BudgetAccounting, BudgetReporting {
    func linkConversation(childConversationID: UUID, parentConversationID: UUID) async
    func recordDelegateCompletion(
        conversationID: UUID,
        success: Bool,
        settledCostUSD: Double?
    ) async
    func hydrate(from seeds: [BudgetLedgerHydrationSeed]) async
    func setConversationMaxUSD(conversationID: UUID, maxUSD: Double?) async
}

/// Process-wide model pool cost ledger: main-loop dispatches, compaction, memory recall, and sub-agent spend.
actor ModelPoolCostLedger: DelegateCostTracking {
    private var parentByConversationID: [UUID: UUID] = [:]
    private var ownerAccountIDByConversationID: [UUID: UUID] = [:]
    private var settledSpendByConversationID: [UUID: Double] = [:]
    private var settledSpendByAccountID: [UUID: Double] = [:]
    private var pendingProjectedByConversationID: [UUID: Double] = [:]
    private var pendingProjectedByAccountID: [UUID: Double] = [:]
    private var pendingReservationsByConversationID: [UUID: [Double]] = [:]
    private var pendingReservationsByAccountID: [UUID: [Double]] = [:]
    private var pendingReservationsWithoutConversation: [Double] = []
    private var settledGlobalUSD: Double = 0
    private var pendingGlobalUSD: Double = 0
    private var activeGlobalCapUSD: Double?
    private var hasSeenEnabledPolicy: Bool = false
    private var conversationMaxUSDByConversationID: [UUID: Double] = [:]
    private let defaultDelegateCompletionUSD: Double

    /// In-memory ledger for runtime accounting signals.
    /// Startup currently begins at zero spend (no hydration from persistence yet).
    init(defaultDelegateCompletionUSD: Double = 0.001) {
        self.defaultDelegateCompletionUSD = max(0, defaultDelegateCompletionUSD)
    }

    /// Primes policy-derived reporting state so hydrated totals can surface on wire before first dispatch.
    func setActivePolicy(_ policy: BudgetPolicy) async {
        if case .enabled(_, _, let maxUSDGlobal, _, _) = policy {
            hasSeenEnabledPolicy = true
            activeGlobalCapUSD = maxUSDGlobal
        } else {
            hasSeenEnabledPolicy = false
            activeGlobalCapUSD = nil
        }
    }

    func hydrate(from seeds: [BudgetLedgerHydrationSeed]) async {
        parentByConversationID = [:]
        ownerAccountIDByConversationID = [:]
        settledSpendByConversationID = [:]
        settledSpendByAccountID = [:]
        pendingProjectedByConversationID = [:]
        pendingProjectedByAccountID = [:]
        pendingReservationsByConversationID = [:]
        pendingReservationsByAccountID = [:]
        pendingReservationsWithoutConversation = []
        pendingGlobalUSD = 0
        conversationMaxUSDByConversationID = [:]

        var allIDs = Set<UUID>()
        for seed in seeds {
            allIDs.insert(seed.conversationID)
            if let parent = seed.parentConversationID {
                parentByConversationID[seed.conversationID] = parent
            }
            if let owner = seed.ownerAccountID {
                ownerAccountIDByConversationID[seed.conversationID] = owner
            }
            settledSpendByConversationID[seed.conversationID] = max(0, seed.spentUSD)
            if let maxUSD = seed.maxUSD, maxUSD > 0 {
                conversationMaxUSDByConversationID[seed.conversationID] = maxUSD
            }
        }

        // `spentUSD` snapshots on parent rows already include child rollups; sum root rows only.
        let roots = seeds.filter { seed in
            guard let parent = seed.parentConversationID else { return true }
            return !allIDs.contains(parent)
        }
        if roots.isEmpty {
            settledGlobalUSD = seeds.reduce(0) { $0 + max(0, $1.spentUSD) }
            for seed in seeds {
                guard let owner = seed.ownerAccountID else { continue }
                settledSpendByAccountID[owner, default: 0] += max(0, seed.spentUSD)
            }
        } else {
            settledGlobalUSD = roots.reduce(0) { $0 + max(0, $1.spentUSD) }
            for seed in roots {
                guard let owner = seed.ownerAccountID else { continue }
                settledSpendByAccountID[owner, default: 0] += max(0, seed.spentUSD)
            }
        }
    }

    func linkConversation(childConversationID: UUID, parentConversationID: UUID) async {
        parentByConversationID[childConversationID] = parentConversationID
    }

    func recordDelegateCompletion(
        conversationID: UUID,
        success: Bool,
        settledCostUSD: Double? = nil
    ) async {
        guard success else { return }
        let explicitCost = max(0, settledCostUSD ?? 0)
        let resolvedCost = explicitCost > 0 ? explicitCost : defaultDelegateCompletionUSD
        guard resolvedCost > 0 else { return }
        applySettledSpend(resolvedCost, to: conversationID)
        settledGlobalUSD += resolvedCost
    }

    func setConversationMaxUSD(conversationID: UUID, maxUSD: Double?) async {
        if let maxUSD, maxUSD > 0 {
            conversationMaxUSDByConversationID[conversationID] = maxUSD
        } else {
            conversationMaxUSDByConversationID.removeValue(forKey: conversationID)
        }
    }

    func authorize(
        policy: BudgetPolicy,
        modelID _: UUID,
        conversationID: UUID?,
        accountID: UUID?,
        projectedCostUSD: Double?
    ) async throws {
        guard case .enabled(
            let maxUSDPerCall,
            let maxUSDPerConversation,
            let maxUSDGlobal,
            let maxUSDPerAccount,
            let projectedCostFallback
        ) = policy else { return }

        hasSeenEnabledPolicy = true
        activeGlobalCapUSD = maxUSDGlobal
        let resolvedAccountID = resolveAccountID(conversationID: conversationID, explicitAccountID: accountID)
        if let conversationID, let resolvedAccountID {
            ownerAccountIDByConversationID[conversationID] = resolvedAccountID
        }

        let projected: Double
        switch projectedCostUSD {
        case .some(let value):
            projected = max(0, value)
        case .none:
            if projectedCostFallback == .denyWhenUnknown {
                throw LLMError.quotaExceeded
            }
            projected = 0
        }

        if let maxUSDPerCall, projected > maxUSDPerCall {
            throw LLMError.quotaExceeded
        }

        if let conversationID {
            let effectiveCap: Double?
            if let maxUSDPerConversation {
                effectiveCap = effectiveConversationCapUSD(
                    globalCap: maxUSDPerConversation,
                    conversationID: conversationID
                )
            } else if let snapshotCap = conversationMaxUSDByConversationID[conversationID] {
                effectiveCap = snapshotCap
            } else {
                effectiveCap = nil
            }
            if let effectiveCap {
                let currentConversationSpend = spendForConversation(conversationID)
                if currentConversationSpend + projected > effectiveCap {
                    throw LLMError.quotaExceeded
                }
            }
        }

        if let maxUSDGlobal {
            let currentGlobalSpend = settledGlobalUSD + pendingGlobalUSD
            if currentGlobalSpend + projected > maxUSDGlobal {
                throw LLMError.quotaExceeded
            }
        }

        if let maxUSDPerAccount,
           let resolvedAccountID {
            let currentAccountSpend = spendForAccount(resolvedAccountID)
            if currentAccountSpend + projected > maxUSDPerAccount {
                throw LLMError.quotaExceeded
            }
        }

        pendingGlobalUSD += projected
        if let conversationID {
            pendingReservationsByConversationID[conversationID, default: []].append(projected)
            applyPendingProjection(projected, to: conversationID)
        } else {
            pendingReservationsWithoutConversation.append(projected)
        }
        if let resolvedAccountID {
            pendingReservationsByAccountID[resolvedAccountID, default: []].append(projected)
            applyPendingProjection(projected, toAccount: resolvedAccountID)
        }
    }

    func recordCompletion(
        policy: BudgetPolicy,
        modelID _: UUID,
        conversationID: UUID?,
        accountID: UUID?,
        actualCostUSD: Double?
    ) async {
        guard case .enabled = policy else { return }
        let resolvedAccountID = resolveAccountID(conversationID: conversationID, explicitAccountID: accountID)
        if let conversationID, let resolvedAccountID {
            ownerAccountIDByConversationID[conversationID] = resolvedAccountID
        }

        let reserved: Double
        if let conversationID {
            var queue = pendingReservationsByConversationID[conversationID, default: []]
            reserved = queue.isEmpty ? 0 : queue.removeFirst()
            pendingReservationsByConversationID[conversationID] = queue
            applyPendingProjection(-reserved, to: conversationID)
        } else {
            reserved = pendingReservationsWithoutConversation.isEmpty ? 0 : pendingReservationsWithoutConversation.removeFirst()
        }
        pendingGlobalUSD = max(0, pendingGlobalUSD - reserved)
        if let resolvedAccountID {
            var queue = pendingReservationsByAccountID[resolvedAccountID, default: []]
            let accountReserved = queue.isEmpty ? 0 : queue.removeFirst()
            pendingReservationsByAccountID[resolvedAccountID] = queue
            applyPendingProjection(-accountReserved, toAccount: resolvedAccountID)
        }

        let actual = max(0, actualCostUSD ?? 0)
        guard actual > 0 else { return }
        settledGlobalUSD += actual
        if let conversationID {
            applySettledSpend(actual, to: conversationID)
        }
        if let resolvedAccountID {
            settledSpendByAccountID[resolvedAccountID, default: 0] += actual
        }
    }

    func poolBudgetRemainingUSD() async -> Double? {
        guard hasSeenEnabledPolicy, let activeGlobalCapUSD else { return nil }
        return max(0, activeGlobalCapUSD - (settledGlobalUSD + pendingGlobalUSD))
    }

    func projectedCostUSD(conversationID: UUID) async -> Double? {
        if hasSeenEnabledPolicy {
            return spendForConversation(conversationID)
        }
        let value = settledSpendByConversationID[conversationID, default: 0]
        return value > 0 ? value : nil
    }

    private func effectiveConversationCapUSD(globalCap: Double, conversationID: UUID) -> Double {
        guard let snapshotCap = conversationMaxUSDByConversationID[conversationID] else {
            return globalCap
        }
        return min(globalCap, snapshotCap)
    }

    private func spendForConversation(_ conversationID: UUID) -> Double {
        settledSpendByConversationID[conversationID, default: 0] + pendingProjectedByConversationID[conversationID, default: 0]
    }

    private func spendForAccount(_ accountID: UUID) -> Double {
        settledSpendByAccountID[accountID, default: 0] + pendingProjectedByAccountID[accountID, default: 0]
    }

    private func resolveAccountID(conversationID: UUID?, explicitAccountID: UUID?) -> UUID? {
        if let explicitAccountID { return explicitAccountID }
        guard let conversationID else { return nil }
        return ownerAccountIDByConversationID[conversationID]
    }

    private func applySettledSpend(_ usd: Double, to conversationID: UUID) {
        guard usd > 0 else { return }
        var cursor: UUID? = conversationID
        var visited: Set<UUID> = []
        while let id = cursor, !visited.contains(id) {
            visited.insert(id)
            settledSpendByConversationID[id, default: 0] += usd
            cursor = parentByConversationID[id]
        }
    }

    private func applyPendingProjection(_ usd: Double, to conversationID: UUID) {
        guard usd != 0 else { return }
        var cursor: UUID? = conversationID
        var visited: Set<UUID> = []
        while let id = cursor, !visited.contains(id) {
            visited.insert(id)
            let next = pendingProjectedByConversationID[id, default: 0] + usd
            pendingProjectedByConversationID[id] = max(0, next)
            cursor = parentByConversationID[id]
        }
    }

    private func applyPendingProjection(_ usd: Double, toAccount accountID: UUID) {
        guard usd != 0 else { return }
        let next = pendingProjectedByAccountID[accountID, default: 0] + usd
        pendingProjectedByAccountID[accountID] = max(0, next)
    }

}

/// Legacy name retained for sub-agent delegate wiring; same ledger as ``ModelPoolCostLedger``.
typealias DelegateCostLedger = ModelPoolCostLedger
