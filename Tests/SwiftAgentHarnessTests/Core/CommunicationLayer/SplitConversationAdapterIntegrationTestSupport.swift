import Foundation
@testable import SwiftAgentHarness

private func makeHarnessRuntimeGraph(runtimeSession: HarnessRuntimeSession) async -> HarnessRuntimeGraph {
    let services = await runtimeSession.services
    let subAgentIngress = SubAgentAPIIngressService(
        spawn: services.subAgentSpawnService,
        completion: services.subAgentCompletionRuntimeService
    )
    return SplitGatewayServiceFactory.makeRuntimeGraph(
        services: services,
        subAgentLifecycleHost: subAgentIngress,
        subAgentCompletionHost: subAgentIngress,
        subAgentCompletion: SubAgentCompletionIngressService(host: subAgentIngress)
    )
}
