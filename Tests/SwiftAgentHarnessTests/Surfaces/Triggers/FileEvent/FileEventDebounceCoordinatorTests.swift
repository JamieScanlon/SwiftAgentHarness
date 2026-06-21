import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("FileEventDebounceCoordinator")
struct FileEventDebounceCoordinatorTests {
    @Test("burst writes invoke handler once")
    func debounceBurst() async throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("burst.json")
        try Data("{}".utf8).write(to: url)
        let counter = Counter()
        let coordinator = FileEventDebounceCoordinator(debounceMilliseconds: 50) { _ in
            await counter.increment()
        }
        await coordinator.noteEvent(eventURL: url)
        await coordinator.noteEvent(eventURL: url)
        await coordinator.noteEvent(eventURL: url)
        guard try await waitUntil(timeoutNanoseconds: 5_000_000_000, condition: { await counter.value == 1 }) else {
            Issue.record("timed out waiting for debounce handler")
            return
        }
        let value = await counter.value
        #expect(value == 1)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        pollNanoseconds: UInt64 = 25_000_000,
        condition: @escaping () async -> Bool
    ) async throws -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() { return true }
            try await Task.sleep(nanoseconds: pollNanoseconds)
        }
        return false
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("file-event-debounce-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
