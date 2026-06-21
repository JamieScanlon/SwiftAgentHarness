import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("NilBudgetReporting")
struct BudgetReportingNilTests {
    @Test("poolBudgetRemainingUSD always returns nil")
    func poolBudgetRemainingNil() async {
        let reporter = NilBudgetReporting()
        let value = await reporter.poolBudgetRemainingUSD()
        #expect(value == nil)
    }

    @Test("projectedCostUSD returns nil regardless of conversation id")
    func projectedCostNil() async {
        let reporter = NilBudgetReporting()
        for _ in 0..<5 {
            let value = await reporter.projectedCostUSD(conversationID: UUID())
            #expect(value == nil)
        }
    }
}
