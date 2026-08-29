import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ModelCompletionSettlementSink")
struct ModelCompletionSettlementSinkTests {
    @Test("a recorded cost is delivered once")
    func recordThenConsume() {
        let sink = ModelCompletionSettlementSink()
        let conversationID = UUID()
        sink.record(conversationID: conversationID, costUSD: 0.5)
        #expect(sink.consume(conversationID: conversationID) == 0.5)
        // Consumed, not peeked — the next completion must not inherit this price.
        #expect(sink.consume(conversationID: conversationID) == nil)
    }

    /// Cancellation and errors clear rather than leave the previous figure standing, or one call's
    /// tokens would be billed at another call's price.
    @Test("recording nil clears a pending figure")
    func nilClears() {
        let sink = ModelCompletionSettlementSink()
        let conversationID = UUID()
        sink.record(conversationID: conversationID, costUSD: 0.5)
        sink.record(conversationID: conversationID, costUSD: nil)
        #expect(sink.consume(conversationID: conversationID) == nil)
    }

    @Test("conversations do not see each other's figures")
    func conversationsAreIsolated() {
        let sink = ModelCompletionSettlementSink()
        let a = UUID()
        let b = UUID()
        sink.record(conversationID: a, costUSD: 1)
        sink.record(conversationID: b, costUSD: 2)
        #expect(sink.consume(conversationID: b) == 2)
        #expect(sink.consume(conversationID: a) == 1)
    }

    /// The gate has a `UUID?` conversation id; a nil one has nowhere to land and must not trap.
    @Test("a conversation-less call records nothing")
    func nilConversationIsIgnored() {
        let sink = ModelCompletionSettlementSink()
        sink.record(conversationID: nil, costUSD: 1)
        #expect(sink.consume(conversationID: UUID()) == nil)
    }

    /// Zero is a real answer and must not read as "nothing recorded", which falls back to catalog
    /// pricing. (The gate settles `0` to the budget accounting on cancellation but records `nil`
    /// here, so this case comes from a genuinely free completion, not from a cancel.)
    @Test("zero is a figure, not an absence")
    func zeroIsDistinctFromAbsent() {
        let sink = ModelCompletionSettlementSink()
        let conversationID = UUID()
        sink.record(conversationID: conversationID, costUSD: 0)
        #expect(sink.consume(conversationID: conversationID) == 0)
    }
}
