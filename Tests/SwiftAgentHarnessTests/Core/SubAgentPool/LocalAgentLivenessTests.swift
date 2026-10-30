import Foundation
import Synchronization
import Testing
@testable import SwiftAgentHarness

private final class LivenessTestClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    func now() -> Date { current.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { current.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

@Suite("Local agent liveness: what the idle timeout reads")
struct LocalAgentLivenessTests {
    @Test("Before the run is observed there is nothing to time")
    func unobserved() async {
        let clock = LivenessTestClock()
        let liveness = LocalAgentLiveness(now: clock.now)
        clock.advance(600)
        #expect(await liveness.quietTime() == nil)
    }

    @Test("Quiet time grows without events, and any event resets it")
    func touches() async {
        let clock = LivenessTestClock()
        let liveness = LocalAgentLiveness(now: clock.now)
        liveness.observe(waitingOnApproval: { false })
        clock.advance(30)
        #expect(await liveness.quietTime() == 30)
        liveness.touch()
        clock.advance(5)
        #expect(await liveness.quietTime() == 5)
    }

    @Test("Waiting on a person isn't idle: the clock restarts when the wait ends")
    func paused() async {
        let clock = LivenessTestClock()
        let liveness = LocalAgentLiveness(now: clock.now)
        liveness.observe(waitingOnApproval: { false })
        liveness.pause()
        clock.advance(600)
        #expect(await liveness.quietTime() == 0)
        liveness.resume()
        clock.advance(7)
        #expect(await liveness.quietTime() == 7)
    }

    @Test("Pauses nest, so overlapping waits keep the clock paused until the last ends")
    func nestedPauses() async {
        let clock = LivenessTestClock()
        let liveness = LocalAgentLiveness(now: clock.now)
        liveness.observe(waitingOnApproval: { false })
        liveness.pause()
        liveness.pause()
        liveness.resume()
        clock.advance(100)
        #expect(await liveness.quietTime() == 0)
        liveness.resume()
        clock.advance(3)
        #expect(await liveness.quietTime() == 3)
    }

    @Test("A pending tool approval counts as waiting on a person")
    func pendingApproval() async {
        let clock = LivenessTestClock()
        let waiting = Mutex(true)
        let liveness = LocalAgentLiveness(now: clock.now)
        liveness.observe(waitingOnApproval: { waiting.withLock { $0 } })
        clock.advance(600)
        #expect(await liveness.quietTime() == 0)
        waiting.withLock { $0 = false }
        clock.advance(4)
        #expect(await liveness.quietTime() == 4)
    }

    @Test("A cancelled run reports why it was cancelled, when the canceller said")
    func cancellationDetail() {
        let cancelled = AgentRuntimeRunResult.cancelled(
            reason: ConversationRunTerminalReason(category: .externalCancellation, detail: "task_cancelled")
        )
        let explained = cancelled.applyingCancellationDetail("idle-timeout")
        #expect(explained.terminalState == .cancelled)
        #expect(explained.terminalReason == ConversationRunTerminalReason(category: .externalCancellation, detail: "idle-timeout"))
        #expect(cancelled.applyingCancellationDetail(nil).terminalReason?.detail == "task_cancelled")
        let completed = AgentRuntimeRunResult.completed(reason: ConversationRunTerminalReason(category: .naturalStop))
        #expect(completed.applyingCancellationDetail("idle-timeout").terminalReason?.category == .naturalStop)
    }
}
