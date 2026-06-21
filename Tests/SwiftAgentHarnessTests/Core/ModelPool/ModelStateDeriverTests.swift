import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ModelStateDeriver")
struct ModelStateDeriverTests {
    @Test("Connecting longer than threshold yields thinking")
    func connectingThinkingThreshold() {
        let entered = Date(timeIntervalSince1970: 1_000)
        let now = entered.addingTimeInterval(0.25)
        let thinking = ModelStateDeriver.thinking(
            phase: .connecting,
            connectingEnteredAt: entered,
            now: now,
            streamingAssistantContent: nil
        )
        #expect(thinking == true)
    }

    @Test("Connecting under threshold is not thinking")
    func connectingBelowThreshold() {
        let entered = Date(timeIntervalSince1970: 1_000)
        let now = entered.addingTimeInterval(0.1)
        let thinking = ModelStateDeriver.thinking(
            phase: .connecting,
            connectingEnteredAt: entered,
            now: now,
            streamingAssistantContent: nil
        )
        #expect(thinking == false)
    }

    @Test("Streaming reasoning-only content yields thinking")
    func streamingReasoningOnly() {
        let raw = "<think>\nstep…\n</think>"
        #expect(ModelStateDeriver.streamingThinkingOnly(assistantContent: raw) == true)
    }

    @Test("Streaming reasoning-only flag yields thinking without XML tags")
    func streamingReasoningFlag() {
        let thinking = ModelStateDeriver.thinking(
            phase: .streaming,
            connectingEnteredAt: nil,
            now: Date(),
            streamingAssistantContent: "",
            streamingReasoningOnly: true
        )
        #expect(thinking == true)
    }

    @Test("Streaming visible text clears reasoning-only flag semantics")
    func streamingReasoningFlagWithVisibleText() {
        let thinking = ModelStateDeriver.thinking(
            phase: .streaming,
            connectingEnteredAt: nil,
            now: Date(),
            streamingAssistantContent: "Hello",
            streamingReasoningOnly: true
        )
        #expect(thinking == true)
    }
}
