import Foundation
import Vapor

@testable import SwiftAgentHarness

extension APILayer {
    /// Test-only convenience overload kept in the test target while production wiring remains split.
    func configureRoutesForTesting(
        app: Application,
        runtimeSession: HarnessRuntimeSession,
        modelProvider: APILayerModelManaging
    ) async {
        let gateway = await makeSplitGatewayServices(runtimeSession: runtimeSession)
        await configureRoutesForTesting(
            app: app,
            conversation: gateway.conversation,
            runtime: gateway.runtime,
            modelProvider: modelProvider
        )
    }
}
