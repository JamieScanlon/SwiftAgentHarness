import Foundation
@testable import SwiftAgentHarness

private let _ensureProviderRegistryForHarnessFixtures: Bool = TestTargetBootstrapGate.linked

func makeSplitConversationAdapter(runtimeSession: HarnessRuntimeSession) async -> APILayerConversationAdapter {
    TestTargetBootstrap.ensureProvidersRegistered()
    return await HarnessConversationTestFixtures.makeServiceGraph(from: runtimeSession).conversationAdapter
}

func makeSplitGatewayServices(runtimeSession: HarnessRuntimeSession) async -> APILayerChatGatewayServices {
    await HarnessConversationTestFixtures.makeServiceGraph(from: runtimeSession).gatewayServices
}
