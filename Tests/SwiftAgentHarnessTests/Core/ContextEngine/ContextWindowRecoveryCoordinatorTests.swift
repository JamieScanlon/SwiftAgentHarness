import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ContextWindowRecoveryCoordinator")
struct ContextWindowRecoveryCoordinatorTests {
    @Test("shouldRetry requires reactive trigger enabled and first attempt")
    func shouldRetryGate() {
        var config = ContextCompactionConfiguration.default
        config.reactiveTriggerEnabled = false
        let disabled = ContextWindowRecoveryCoordinator.shouldRetry(
            error: NSError(domain: "x", code: 1),
            config: config,
            alreadyRetriedThisTurn: false
        )
        #expect(disabled == false)
    }

    @Test("shouldRetry blocks when already retried")
    func shouldRetryAlreadyRetried() {
        var config = ContextCompactionConfiguration.default
        config.reactiveTriggerEnabled = true
        config.reactiveErrorPatterns = ["context", "window"]
        let blocked = ContextWindowRecoveryCoordinator.shouldRetry(
            error: NSError(domain: "context window exceeded", code: 1),
            config: config,
            alreadyRetriedThisTurn: true
        )
        #expect(blocked == false)
    }
}
