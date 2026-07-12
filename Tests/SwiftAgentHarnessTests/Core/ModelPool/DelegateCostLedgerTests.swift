import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Delegate cost ledger")
struct DelegateCostLedgerTests {
    @Test("delegate completion spend rolls up to parent conversation")
    func delegateSpendRollup() async {
        let ledger = DelegateCostLedger(defaultDelegateCompletionUSD: 0.25)
        let parentID = UUID()
        let childID = UUID()
        await ledger.linkConversation(childConversationID: childID, parentConversationID: parentID)
        await ledger.recordDelegateCompletion(conversationID: childID, success: true)
        #expect(await ledger.projectedCostUSD(conversationID: childID) == 0.25)
        #expect(await ledger.projectedCostUSD(conversationID: parentID) == 0.25)
    }

    @Test("failed delegate completion does not add spend")
    func failedCompletionNoSpend() async {
        let ledger = DelegateCostLedger(defaultDelegateCompletionUSD: 0.25)
        let conversationID = UUID()
        await ledger.recordDelegateCompletion(conversationID: conversationID, success: false, settledCostUSD: 2.0)
        #expect(await ledger.projectedCostUSD(conversationID: conversationID) == nil)
    }

    @Test("delegate completion settles explicit usage cost when provided")
    func delegateCompletionSettlesExplicitUsageCost() async {
        let ledger = DelegateCostLedger(defaultDelegateCompletionUSD: 0.25)
        let conversationID = UUID()
        await ledger.recordDelegateCompletion(conversationID: conversationID, success: true, settledCostUSD: 0.03)
        #expect(await ledger.projectedCostUSD(conversationID: conversationID) == 0.03)
    }

    @Test("delegate completion falls back to configured default when usage cost missing")
    func delegateCompletionFallsBackWhenUsageMissing() async {
        let ledger = DelegateCostLedger(defaultDelegateCompletionUSD: 0.25)
        let conversationID = UUID()
        await ledger.recordDelegateCompletion(conversationID: conversationID, success: true, settledCostUSD: nil)
        #expect(await ledger.projectedCostUSD(conversationID: conversationID) == 0.25)
    }

    @Test("duplicate completion announce ID settles cost once")
    func duplicateAnnounceIDSettlesOnce() async {
        let ledger = DelegateCostLedger()
        let conversationID = UUID()
        let announceID = UUID()
        await ledger.recordDelegateCompletion(
            conversationID: conversationID,
            success: true,
            settledCostUSD: 0.05,
            completionAnnounceID: announceID
        )
        await ledger.recordDelegateCompletion(
            conversationID: conversationID,
            success: true,
            settledCostUSD: 0.05,
            completionAnnounceID: announceID
        )
        #expect(await ledger.projectedCostUSD(conversationID: conversationID) == 0.05)
    }

    @Test("nil completion announce ID remains additive")
    func nilAnnounceIDRemainsAdditive() async {
        let ledger = DelegateCostLedger()
        let conversationID = UUID()
        await ledger.recordDelegateCompletion(
            conversationID: conversationID,
            success: true,
            settledCostUSD: 0.03,
            completionAnnounceID: nil
        )
        await ledger.recordDelegateCompletion(
            conversationID: conversationID,
            success: true,
            settledCostUSD: 0.03,
            completionAnnounceID: nil
        )
        #expect(await ledger.projectedCostUSD(conversationID: conversationID) == 0.06)
    }

    @Test("authorize enforces per-call cap")
    func authorizeEnforcesPerCallCap() async {
        let ledger = DelegateCostLedger()
        await #expect(throws: LLMError.self) {
            try await ledger.authorize(
                policy: .enabled(maxUSDPerCall: 0.01, maxUSDPerConversation: nil),
                modelID: UUID(),
                conversationID: UUID(),
                accountID: nil,
                projectedCostUSD: 0.02
            )
        }
    }

    @Test("authorize enforces per-conversation cumulative cap")
    func authorizeEnforcesPerConversationCap() async throws {
        let ledger = DelegateCostLedger()
        let conversationID = UUID()
        let modelID = UUID()
        let policy: BudgetPolicy = .enabled(maxUSDPerCall: nil, maxUSDPerConversation: 0.05)

        try await ledger.authorize(policy: policy, modelID: modelID, conversationID: conversationID, accountID: nil, projectedCostUSD: 0.03)
        await ledger.recordCompletion(policy: policy, modelID: modelID, conversationID: conversationID, accountID: nil, actualCostUSD: 0.03)

        await #expect(throws: LLMError.self) {
            try await ledger.authorize(policy: policy, modelID: modelID, conversationID: conversationID, accountID: nil, projectedCostUSD: 0.03)
        }
    }

    @Test("poolBudgetRemainingUSD tracks active global cap")
    func poolBudgetRemainingTracksGlobal() async throws {
        let ledger = DelegateCostLedger()
        let policy: BudgetPolicy = .enabled(maxUSDPerCall: nil, maxUSDPerConversation: nil, maxUSDGlobal: 1.0)
        let conversationID = UUID()
        let modelID = UUID()

        try await ledger.authorize(policy: policy, modelID: modelID, conversationID: conversationID, accountID: nil, projectedCostUSD: 0.40)
        #expect(await ledger.poolBudgetRemainingUSD() == 0.60)

        await ledger.recordCompletion(policy: policy, modelID: modelID, conversationID: conversationID, accountID: nil, actualCostUSD: 0.25)
        #expect(await ledger.poolBudgetRemainingUSD() == 0.75)
    }

    @Test("authorize enforces global cumulative cap across calls")
    func authorizeEnforcesGlobalCap() async throws {
        let ledger = DelegateCostLedger()
        let policy: BudgetPolicy = .enabled(maxUSDPerCall: nil, maxUSDPerConversation: nil, maxUSDGlobal: 0.05)
        let modelID = UUID()
        let c1 = UUID()
        let c2 = UUID()

        try await ledger.authorize(policy: policy, modelID: modelID, conversationID: c1, accountID: nil, projectedCostUSD: 0.03)
        await ledger.recordCompletion(policy: policy, modelID: modelID, conversationID: c1, accountID: nil, actualCostUSD: 0.03)
        await #expect(throws: LLMError.self) {
            try await ledger.authorize(policy: policy, modelID: modelID, conversationID: c2, accountID: nil, projectedCostUSD: 0.03)
        }
    }

    @Test("authorize enforces account cumulative cap across conversations")
    func authorizeEnforcesAccountCap() async throws {
        let ledger = DelegateCostLedger()
        let accountID = UUID()
        let policy: BudgetPolicy = .enabled(maxUSDPerCall: nil, maxUSDPerConversation: nil, maxUSDGlobal: nil, maxUSDPerAccount: 0.05)
        let modelID = UUID()
        let c1 = UUID()
        let c2 = UUID()

        try await ledger.authorize(
            policy: policy,
            modelID: modelID,
            conversationID: c1,
            accountID: accountID,
            projectedCostUSD: 0.03
        )
        await ledger.recordCompletion(
            policy: policy,
            modelID: modelID,
            conversationID: c1,
            accountID: accountID,
            actualCostUSD: 0.03
        )
        await #expect(throws: LLMError.self) {
            try await ledger.authorize(
                policy: policy,
                modelID: modelID,
                conversationID: c2,
                accountID: accountID,
                projectedCostUSD: 0.03
            )
        }
    }

    @Test("authorize denies when per-account cap is set but account is unresolved")
    func authorizeDeniesWithoutAccountWhenPerAccountCapSet() async {
        let ledger = DelegateCostLedger()
        let policy: BudgetPolicy = .enabled(
            maxUSDPerCall: nil,
            maxUSDPerConversation: nil,
            maxUSDGlobal: nil,
            maxUSDPerAccount: 0.05
        )
        await #expect(throws: LLMError.self) {
            try await ledger.authorize(
                policy: policy,
                modelID: UUID(),
                conversationID: UUID(),
                accountID: nil,
                projectedCostUSD: 0.01
            )
        }
    }

    @Test("denyWhenUnknown rejects authorize when projected cost is nil")
    func denyUnknownProjection() async {
        let ledger = DelegateCostLedger()
        await #expect(throws: LLMError.self) {
            try await ledger.authorize(
                policy: .enabled(
                    maxUSDPerCall: 0.05,
                    maxUSDPerConversation: nil,
                    maxUSDGlobal: nil,
                    projectedCostFallback: .denyWhenUnknown
                ),
                modelID: UUID(),
                conversationID: UUID(),
                accountID: nil,
                projectedCostUSD: nil
            )
        }
    }

    @Test("cancellation-style settle with zero releases reservation")
    func settleZeroReleasesReservation() async throws {
        let ledger = DelegateCostLedger()
        let policy: BudgetPolicy = .enabled(maxUSDPerCall: nil, maxUSDPerConversation: 1.0, maxUSDGlobal: 1.0)
        let conversationID = UUID()
        let modelID = UUID()

        try await ledger.authorize(policy: policy, modelID: modelID, conversationID: conversationID, accountID: nil, projectedCostUSD: 0.20)
        #expect(await ledger.projectedCostUSD(conversationID: conversationID) == 0.20)
        await ledger.recordCompletion(policy: policy, modelID: modelID, conversationID: conversationID, accountID: nil, actualCostUSD: 0)
        #expect(await ledger.projectedCostUSD(conversationID: conversationID) == 0.0)
        #expect(await ledger.poolBudgetRemainingUSD() == 1.0)
    }

    @Test("hydration restores settled spend aggregates across restart")
    func hydrationRestoresSettledAggregates() async {
        let ledger = DelegateCostLedger()
        let accountID = UUID()
        let rootID = UUID()
        let childID = UUID()
        await ledger.hydrate(from: [
            BudgetLedgerHydrationSeed(
                conversationID: rootID,
                parentConversationID: nil,
                ownerAccountID: accountID,
                spentUSD: 0.90
            ),
            BudgetLedgerHydrationSeed(
                conversationID: childID,
                parentConversationID: rootID,
                ownerAccountID: accountID,
                spentUSD: 0.35
            )
        ])

        #expect(await ledger.projectedCostUSD(conversationID: rootID) == 0.90)
        #expect(await ledger.projectedCostUSD(conversationID: childID) == 0.35)
        await #expect(throws: LLMError.self) {
            try await ledger.authorize(
                policy: .enabled(maxUSDPerCall: nil, maxUSDPerConversation: nil, maxUSDGlobal: 0.95),
                modelID: UUID(),
                conversationID: childID,
                accountID: nil,
                projectedCostUSD: 0.10
            )
        }
    }

    @Test("hydrated spend reports poolBudgetRemaining once policy is primed")
    func hydratedSpendReportsPoolRemainingAfterPolicyPrime() async {
        let ledger = DelegateCostLedger()
        await ledger.hydrate(from: [
            BudgetLedgerHydrationSeed(
                conversationID: UUID(),
                parentConversationID: nil,
                ownerAccountID: nil,
                spentUSD: 0.40
            )
        ])
        await ledger.setActivePolicy(.enabled(maxUSDPerCall: nil, maxUSDPerConversation: nil, maxUSDGlobal: 1.0))
        #expect(await ledger.poolBudgetRemainingUSD() == 0.60)
    }

    @Test("per-conversation maxUSD tighter than global conversation cap is enforced")
    func perConversationMaxUSDCap() async {
        let ledger = DelegateCostLedger()
        let conversationID = UUID()
        await ledger.setConversationMaxUSD(conversationID: conversationID, maxUSD: 0.05)
        await #expect(throws: LLMError.self) {
            try await ledger.authorize(
                policy: .enabled(maxUSDPerCall: nil, maxUSDPerConversation: 1.0, maxUSDGlobal: nil),
                modelID: UUID(),
                conversationID: conversationID,
                accountID: nil,
                projectedCostUSD: 0.10
            )
        }
    }
}
