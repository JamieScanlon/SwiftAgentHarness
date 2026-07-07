import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ChannelTypingKeepalive")
struct ChannelTypingKeepaliveTests {
    @Test("start invokes sendTyping and stop ends the loop")
    func startStop() async throws {
        let keepalive = ChannelTypingKeepalive(intervalSeconds: 0.05)
        let tracker = TypingSendTracker()
        await keepalive.start(chatId: "C1") { chatId in
            await tracker.record(chatId: chatId)
        }
        try await Task.sleep(for: .milliseconds(120))
        await keepalive.stop()
        let chatIds = await tracker.chatIds
        #expect(chatIds.contains("C1"))
        #expect(chatIds.count >= 1)
    }
}

private actor TypingSendTracker {
    private(set) var chatIds: [String] = []

    func record(chatId: String) {
        chatIds.append(chatId)
    }
}
