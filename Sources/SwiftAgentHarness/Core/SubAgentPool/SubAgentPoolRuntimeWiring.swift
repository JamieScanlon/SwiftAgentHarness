import Foundation
import Logging
import SwiftAgentKitA2A
import SwiftAgentKitACP

enum SubAgentPoolRuntimeWiring {
    struct Resolved {
        let pool: DefaultSubAgentPool
        let a2aManagerProvider: SubAgentPoolA2AManagerProvider
        let acpManagerProvider: SubAgentPoolACPManagerProvider
        let sessionStore: SubAgentRemoteTransportSessionStore
    }

    static func resolve(
        a2aManager: A2AManager? = nil,
        acpManager: ACPManager? = nil,
        customEndpointConfiguration: SubAgentCustomEndpointConfiguration = .loadFromPromptConfigBundle(),
        customEndpointExecutor: (any CustomEndpointDelegateExecuting)? = nil,
        sessionStore: SubAgentRemoteTransportSessionStore = .shared,
        toolCallTimeout: TimeInterval = 300,
        hostingPolicyConfiguration: SubAgentHostingPolicyConfiguration = SubAgentHostingPolicyConfiguration.loadFromPromptConfigBundle(),
        logger: Logger? = nil
    ) -> Resolved {
        let a2aManagerProvider = SubAgentPoolA2AManagerProvider()
        if let a2aManager {
            Task { await a2aManagerProvider.setManager(a2aManager) }
        }
        let acpManagerProvider = SubAgentPoolACPManagerProvider()
        if let acpManager {
            Task { await acpManagerProvider.setBootstrap(manager: acpManager) }
        }
        let executor = customEndpointExecutor ?? URLSessionCustomEndpointDelegateExecutor()
        let adapters = SubAgentDefaultAdapters.make(
            a2aManagerProvider: a2aManagerProvider,
            acpManagerProvider: acpManagerProvider,
            customEndpointConfiguration: customEndpointConfiguration,
            customEndpointExecutor: executor,
            sessionStore: sessionStore,
            toolCallTimeout: toolCallTimeout,
            logger: logger
        )
        let pool = DefaultSubAgentPool(
            adapters: adapters,
            hostingPolicyConfiguration: hostingPolicyConfiguration
        )
        return Resolved(
            pool: pool,
            a2aManagerProvider: a2aManagerProvider,
            acpManagerProvider: acpManagerProvider,
            sessionStore: sessionStore
        )
    }
}
