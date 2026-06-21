import Foundation
@testable import SwiftAgentHarness

func makeSplitConversationAdapter(runtimeSession: HarnessRuntimeSession) async -> APILayerConversationAdapter {
    await HarnessConversationTestFixtures.makeServiceGraph(from: runtimeSession).conversationAdapter
}

func makeSplitGatewayServices(runtimeSession: HarnessRuntimeSession) async -> APILayerChatGatewayServices {
    await HarnessConversationTestFixtures.makeServiceGraph(from: runtimeSession).gatewayServices
}
