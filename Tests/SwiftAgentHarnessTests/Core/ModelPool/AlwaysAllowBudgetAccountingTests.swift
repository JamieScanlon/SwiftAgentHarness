import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("AlwaysAllowBudgetAccounting")
struct AlwaysAllowBudgetAccountingTests {
    @Test("authorize does not throw under .disabled policy")
    func authorizeDisabled() async throws {
        let accounting = AlwaysAllowBudgetAccounting()
        try await accounting.authorize(
            policy: .disabled,
            modelID: UUID(),
            conversationID: nil,
            accountID: nil,
            projectedCostUSD: nil
        )
    }

    @Test("authorize does not throw under .enabled with both caps set")
    func authorizeEnabledBothCaps() async throws {
        let accounting = AlwaysAllowBudgetAccounting()
        try await accounting.authorize(
            policy: .enabled(maxUSDPerCall: 0.01, maxUSDPerConversation: 1.0),
            modelID: UUID(),
            conversationID: UUID(),
            accountID: nil,
            projectedCostUSD: 0.5
        )
    }

    @Test("authorize does not throw under .enabled with both caps nil (unbounded)")
    func authorizeEnabledBothNil() async throws {
        let accounting = AlwaysAllowBudgetAccounting()
        try await accounting.authorize(
            policy: .enabled(maxUSDPerCall: nil, maxUSDPerConversation: nil),
            modelID: UUID(),
            conversationID: UUID(),
            accountID: nil,
            projectedCostUSD: nil
        )
    }

    @Test("recordCompletion is a no-op (no throw, no observable side-effects)")
    func recordCompletionNoop() async {
        let accounting = AlwaysAllowBudgetAccounting()
        await accounting.recordCompletion(
            policy: .enabled(maxUSDPerCall: 0.01, maxUSDPerConversation: 1.0),
            modelID: UUID(),
            conversationID: UUID(),
            accountID: nil,
            actualCostUSD: 0.0
        )
        await accounting.recordCompletion(
            policy: .disabled,
            modelID: UUID(),
            conversationID: nil,
            accountID: nil,
            actualCostUSD: nil
        )
    }
}
