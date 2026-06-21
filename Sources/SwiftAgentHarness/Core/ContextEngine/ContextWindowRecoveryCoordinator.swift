import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator

enum ContextWindowRecoveryCoordinator {
    static func shouldRetry(
        error: Error,
        config: ContextCompactionConfiguration,
        alreadyRetriedThisTurn: Bool
    ) -> Bool {
        config.reactiveTriggerEnabled
            && !alreadyRetriedThisTurn
            && ContextCompactionErrorMatcher.isContextWindowExceeded(
                error,
                patterns: config.reactiveErrorPatterns
            )
    }
}
