import Foundation
import Synchronization

/// Whether an in-process delegate's child run is alive: when it last produced an event, and whether it is waiting
/// on a person. The idle timeout reads it. It measures liveness, not progress: a child that keeps calling tools
/// without getting anywhere is alive.
final class LocalAgentLiveness: Sendable {
    /// The liveness of the child run being driven, for the child-run port to report into.
    @TaskLocal static var current: LocalAgentLiveness?

    private struct State {
        var lastActivity: Date
        var pauses = 0
        var waitingOnApproval: (@Sendable () async -> Bool)?
    }

    private let state: Mutex<State>
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        self.state = Mutex(State(lastActivity: now()))
    }

    /// Starts timing. Until then the run can't be observed, so it is never idle.
    func observe(waitingOnApproval: @escaping @Sendable () async -> Bool) {
        let current = now()
        state.withLock {
            $0.waitingOnApproval = waitingOnApproval
            $0.lastActivity = current
        }
    }

    /// Any event: streamed output, a tool call starting or finishing, a state change.
    func touch() {
        let current = now()
        state.withLock { $0.lastActivity = current }
    }

    /// The run is waiting on a person: a question, a handoff, a takeover, or an approval card.
    func pause() {
        state.withLock { $0.pauses += 1 }
    }

    func resume() {
        let current = now()
        state.withLock {
            $0.pauses = max(0, $0.pauses - 1)
            $0.lastActivity = current
        }
    }

    var isPaused: Bool {
        state.withLock { $0.pauses > 0 }
    }

    /// How long the run has gone without an event, or `nil` while it isn't observed. Waiting on a person is never
    /// quiet: the clock restarts when the wait ends.
    func quietTime() async -> TimeInterval? {
        let (probe, paused) = state.withLock { ($0.waitingOnApproval, $0.pauses > 0) }
        guard let probe else { return nil }
        let current = now()
        if paused {
            state.withLock { $0.lastActivity = current }
            return 0
        }
        if await probe() {
            state.withLock { $0.lastActivity = current }
            return 0
        }
        return current.timeIntervalSince(state.withLock { $0.lastActivity })
    }
}
