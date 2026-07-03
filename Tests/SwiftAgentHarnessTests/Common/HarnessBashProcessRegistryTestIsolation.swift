import Foundation
@testable import SwiftAgentHarness

/// Serializes access to the process-global ``BashProcessRegistry/shared`` during tests.
enum HarnessBashProcessRegistryTestIsolation {
    private actor Gate {
        func run(_ body: @Sendable () async throws -> Void) async rethrows {
            await BashProcessRegistry.shared.resetForTesting()
            defer { Task { await BashProcessRegistry.shared.resetForTesting() } }
            try await body()
        }
    }

    private static let gate = Gate()

    static func withExclusiveAccess(_ body: @Sendable () async throws -> Void) async rethrows {
        try await gate.run(body)
    }
}
