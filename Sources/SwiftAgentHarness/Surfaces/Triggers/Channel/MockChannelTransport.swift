import Foundation
import os

final class MockChannelTransport: ChannelTransport, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var continuation: AsyncStream<ChannelTransportRawEvent>.Continuation?
    private var stream: AsyncStream<ChannelTransportRawEvent>?
    private var connected = false

    func connect() async throws {
        lock.withLock {
            guard !connected else { return }
            stream = AsyncStream { self.continuation = $0 }
            connected = true
        }
    }

    func disconnect() async {
        lock.withLock {
            continuation?.finish()
            continuation = nil
            stream = nil
            connected = false
        }
    }

    func events() -> AsyncStream<ChannelTransportRawEvent> {
        lock.withLock { stream ?? AsyncStream { _ in } }
    }

    func inject(_ event: ChannelTransportRawEvent) {
        _ = lock.withLock { continuation?.yield(event) }
    }
}
