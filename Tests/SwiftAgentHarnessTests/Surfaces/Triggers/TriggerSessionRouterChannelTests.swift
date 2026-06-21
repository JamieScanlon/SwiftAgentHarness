import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("TriggerSessionRouter channel threading")
struct TriggerSessionRouterChannelTests {
    @Test("channel session key includes threadId")
    func threadKey() {
        let key = TriggerSessionKeyPrefix.make(
            source: .channel,
            routingMode: .isolated,
            metadata: ["channel": "slack", "chatId": "C1", "threadId": "T1"]
        )
        #expect(key == "channel:slack:C1:T1")
    }
}
