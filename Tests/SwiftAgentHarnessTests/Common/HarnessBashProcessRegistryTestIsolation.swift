import Foundation
@testable import SwiftAgentHarness

/// Serializes access to the process-global ``BashProcessRegistry/shared`` during tests.
///
/// Uses an explicit waiter queue so isolation remains exclusive across `await` points.
/// A plain actor method is insufficient: Swift actors are reentrant.
enum HarnessBashProcessRegistryTestIsolation {
    private actor Gate {
        private var isRunning = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func run(_ body: @Sendable () async throws -> Void) async rethrows {
            if isRunning {
                await withCheckedContinuation { continuation in
                    waiters.append(continuation)
                }
            }
            isRunning = true
            await BashProcessRegistry.shared.resetForTesting()
            do {
                try await body()
                await BashProcessRegistry.shared.resetForTesting()
            } catch {
                await BashProcessRegistry.shared.resetForTesting()
                resumeNextWaiter()
                throw error
            }
            resumeNextWaiter()
        }

        private func resumeNextWaiter() {
            if let next = waiters.first {
                waiters.removeFirst()
                next.resume()
            } else {
                isRunning = false
            }
        }
    }

    private static let gate = Gate()

    static func withExclusiveAccess(_ body: @Sendable () async throws -> Void) async rethrows {
        try await gate.run(body)
    }
}
