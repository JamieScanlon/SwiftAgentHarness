import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Model pool runtime budget wiring")
struct HarnessRuntimeSessionBudgetWiringTests {
    @Test("resolve() wires ModelPoolCostLedger and enabled budget when factory omitted")
    func resolveWiresProductionFactory() {
        let (factory, tracker) = ModelPoolRuntimeWiring.resolve(
            llmFactory: nil,
            delegateCostTracker: nil,
            logger: nil
        )
        #expect(tracker is ModelPoolCostLedger)
        guard let std = factory as? StandardModelLLMFactory else {
            Issue.record("expected StandardModelLLMFactory")
            return
        }
        #expect(std.accounting is ModelPoolCostLedger)
        guard case .enabled = std.advanced.budget else {
            Issue.record("expected enabled budget policy")
            return
        }
        #expect(std.advanced.failover.maxRetries == 2)
    }

    @Test("aligningAccounting replaces pass-through when tracker is provided")
    func aligningAccountingReplacesPassThrough() {
        let ledger = ModelPoolCostLedger()
        let passThrough = StandardModelLLMFactory(accounting: AlwaysAllowBudgetAccounting())
        let aligned = StandardModelLLMFactory.aligningAccounting(
            factory: passThrough,
            delegateCostTracker: ledger
        ) as? StandardModelLLMFactory
        #expect(aligned?.accounting is ModelPoolCostLedger)
    }
}
