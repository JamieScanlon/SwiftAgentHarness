import Foundation
import Logging

enum ModelPoolRuntimeWiring {
    static func resolve(
        llmFactory: (any ModelLLMFactoring)?,
        delegateCostTracker: (any DelegateCostTracking)?,
        logger: Logger?,
        serverConfig: ServerConfig = ServerConfig()
    ) -> (factory: any ModelLLMFactoring, tracker: any DelegateCostTracking) {
        let ledger = delegateCostTracker ?? ModelPoolCostLedger()
        let factory = llmFactory ?? StandardModelLLMFactory.productionConfigured(
            accounting: ledger,
            logger: logger,
            serverConfig: serverConfig
        )
        let alignedFactory = StandardModelLLMFactory.aligningAccounting(
            factory: factory,
            delegateCostTracker: ledger
        )
        return (alignedFactory, ledger)
    }
}
