import Foundation
import Logging

final class MemorySubAgentSpawnPortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var port: MemorySubAgentSpawnPort?

    func set(_ port: MemorySubAgentSpawnPort) {
        lock.lock()
        defer { lock.unlock() }
        self.port = port
    }

    func get() -> MemorySubAgentSpawnPort? {
        lock.lock()
        defer { lock.unlock() }
        return port
    }
}
