import Foundation
import Synchronization
import Testing
@testable import SwiftAgentHarness

@Suite("Local agent run deadline: re-read so it can move")
struct LocalAgentRunDeadlineTests {
    @Test("Waiting ends when a fixed deadline passes")
    func fixed() async throws {
        let start = Date()
        let end = start.addingTimeInterval(0.05)
        try await LocalAgentRunDeadline.wait(until: { end })
        #expect(Date().timeIntervalSince(start) >= 0.04)
    }

    @Test("A deadline moved later while waiting is honored")
    func moved() async throws {
        let start = Date()
        let reads = Mutex(0)
        try await LocalAgentRunDeadline.wait(until: {
            let read = reads.withLock { value -> Int in
                value += 1
                return value
            }
            return start.addingTimeInterval(read == 1 ? 0.05 : 0.25)
        })
        #expect(Date().timeIntervalSince(start) >= 0.2)
        #expect(reads.withLock { $0 } >= 2)
    }

    @Test("A deadline moved earlier while waiting takes effect at the next recheck")
    func movedEarlier() async throws {
        let start = Date()
        let early = Mutex(false)
        let waiting = Task {
            try await LocalAgentRunDeadline.wait(
                until: { early.withLock { $0 } ? start : start.addingTimeInterval(60) },
                recheck: .milliseconds(20)
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        early.withLock { $0 = true }
        try await waiting.value
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("Cancellation stops the wait")
    func cancelled() async {
        let task = Task { try await LocalAgentRunDeadline.wait(until: { Date().addingTimeInterval(60) }) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
