import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("HumanPacer")
struct HumanPacerTests {
    @Test("No delay for first block, final reply, or tool summary")
    func exemptions() {
        let pacer = HumanPacer(config: PacingConfig(mode: .natural), randomUnit: { 0.5 })
        #expect(pacer.delayMs(isFirstBlock: true, isFinalReply: false, isToolSummary: false) == 0)
        #expect(pacer.delayMs(isFirstBlock: false, isFinalReply: true, isToolSummary: false) == 0)
        #expect(pacer.delayMs(isFirstBlock: false, isFinalReply: false, isToolSummary: true) == 0)
    }

    @Test("Natural mode delay within expected range")
    func naturalRange() {
        let pacer = HumanPacer(config: PacingConfig(mode: .natural), randomUnit: { 0.0 })
        let low = pacer.delayMs(isFirstBlock: false, isFinalReply: false, isToolSummary: false)
        #expect(low == HumanPacer.naturalMinMs)

        let pacerHigh = HumanPacer(config: PacingConfig(mode: .natural), randomUnit: { 1.0 })
        let high = pacerHigh.delayMs(isFirstBlock: false, isFinalReply: false, isToolSummary: false)
        #expect(high == HumanPacer.naturalMaxMs)
    }

    @Test("Custom mode respects bounds")
    func customRange() {
        let pacer = HumanPacer(
            config: PacingConfig(mode: .custom(minMs: 100, maxMs: 300)),
            randomUnit: { 0.5 }
        )
        let delay = pacer.delayMs(isFirstBlock: false, isFinalReply: false, isToolSummary: false)
        #expect(delay == 200)
    }

    @Test("Off mode never delays")
    func offMode() {
        let pacer = HumanPacer(config: PacingConfig(mode: .off))
        #expect(pacer.delayMs(isFirstBlock: false, isFinalReply: false, isToolSummary: false) == 0)
    }
}
