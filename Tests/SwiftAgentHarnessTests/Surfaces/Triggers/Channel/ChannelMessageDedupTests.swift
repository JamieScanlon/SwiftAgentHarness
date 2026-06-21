import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ChannelMessageDedup")
struct ChannelMessageDedupTests {
    @Test("repeat id dropped within TTL")
    func repeatDropped() async {
        let dedup = ChannelMessageDedup(ttlSeconds: 60)
        let first = await dedup.isDuplicate(channel: .slack, platformMessageId: "m1")
        let second = await dedup.isDuplicate(channel: .slack, platformMessageId: "m1")
        #expect(first == false)
        #expect(second == true)
    }
}
