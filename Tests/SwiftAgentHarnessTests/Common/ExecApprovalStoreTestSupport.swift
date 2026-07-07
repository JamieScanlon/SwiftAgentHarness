import Foundation
@testable import SwiftAgentHarness

/// Serializes the full body of tests that touch ``ExecApprovalStore/shared``.
private actor ExecApprovalStoreSharedTestGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    func runIsolated<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        await ExecApprovalStore.shared.resetForTesting()
        do {
            let value = try await body()
            await ExecApprovalStore.shared.resetForTesting()
            return value
        } catch {
            await ExecApprovalStore.shared.resetForTesting()
            throw error
        }
    }

    func reset() async {
        await acquire()
        defer { release() }
        await ExecApprovalStore.shared.resetForTesting()
    }
}

/// Isolates ``ExecApprovalStore/shared`` between tests that configure or assert grant state.
enum ExecApprovalStoreTestSupport {
    private static let gate = ExecApprovalStoreSharedTestGate()

    static func resetShared() async {
        await gate.reset()
    }

    static func isolated<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        try await gate.runIsolated(body)
    }
}
