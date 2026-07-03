import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Background process session scope (SEC-009)", .serialized, .timeLimit(.minutes(1)))
struct BackgroundProcessSessionScopeTests {
    private let sessionA = "session-a"
    private let sessionB = "session-b"

    private func waitForSnapshotOutput(
        registry: BashProcessRegistry,
        id: String,
        sessionSlug: String,
        containing substring: String,
        timeout: Duration = .seconds(10)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let snap = await registry.snapshot(id: id, sessionSlug: sessionSlug),
               snap.output.contains(substring) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test("authorized session can poll, snapshot, send keys, and kill")
    func authorizedSessionOperationsSucceed() async throws {
        let registry = BashProcessRegistry()
        let id = try await registry.register(
            sessionSlug: sessionA,
            argv: ["/bin/bash", "-c", "echo hello; sleep 5"],
            env: [:],
            cwd: nil
        )
        #expect(await waitForSnapshotOutput(registry: registry, id: id, sessionSlug: sessionA, containing: "hello"))

        let polled = await registry.poll(id: id, sessionSlug: sessionA)
        #expect(polled != nil)

        let idForCat = try await registry.register(
            sessionSlug: sessionA,
            argv: ["/bin/bash", "-c", "cat"],
            env: [:],
            cwd: nil
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        try await registry.sendKeys(id: idForCat, sessionSlug: sessionA, data: Data("ping\n".utf8))

        #expect(await registry.kill(id: idForCat, sessionSlug: sessionA))
        await registry.kill(id: id, sessionSlug: sessionA)
    }

    @Test("foreign session cannot poll, snapshot, send keys, or kill")
    func foreignSessionDenied() async throws {
        let registry = BashProcessRegistry()
        let id = try await registry.register(
            sessionSlug: sessionA,
            argv: ["/bin/bash", "-c", "echo secret; sleep 10"],
            env: [:],
            cwd: nil
        )

        #expect(await waitForSnapshotOutput(registry: registry, id: id, sessionSlug: sessionA, containing: "secret"))

        #expect(await registry.poll(id: id, sessionSlug: sessionB) == nil)
        #expect(await registry.snapshot(id: id, sessionSlug: sessionB) == nil)
        #expect(await registry.kill(id: id, sessionSlug: sessionB) == false)

        do {
            try await registry.sendKeys(id: id, sessionSlug: sessionB, data: Data("pwn\n".utf8))
            Issue.record("Expected sendKeys to fail for foreign session")
        } catch let error as SandboxBackendError {
            if case .commandFailed(let reason) = error {
                #expect(reason.contains("process not found"))
            } else {
                Issue.record("Unexpected SandboxBackendError: \(error)")
            }
        }

        #expect(await registry.snapshot(id: id, sessionSlug: sessionA) != nil)
        await registry.kill(id: id, sessionSlug: sessionA)
    }
}
