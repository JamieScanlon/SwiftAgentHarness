import Foundation
import Logging

actor ChannelTransportSupervisor {
    private let transport: any ChannelTransport
    private let logger: Logger
    private let maxBackoffSeconds: TimeInterval = 60
    private var backoffSeconds: TimeInterval = 1
    private var runTask: Task<Void, Never>?
    private let onEvent: @Sendable (MockChannelRawEvent) async -> Void

    init(
        transport: any ChannelTransport,
        logger: Logger,
        onEvent: @escaping @Sendable (MockChannelRawEvent) async -> Void
    ) {
        self.transport = transport
        self.logger = logger
        self.onEvent = onEvent
    }

    func start() {
        guard runTask == nil else { return }
        runTask = Task {
            await self.runLoop()
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        Task { await transport.disconnect() }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                try await transport.connect()
                backoffSeconds = 1
                for await event in transport.events() {
                    if Task.isCancelled { break }
                    await onEvent(event)
                }
            } catch {
                logger.warning("channel_transport_error error=\(String(describing: error))")
                try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
                backoffSeconds = min(backoffSeconds * 2, maxBackoffSeconds)
            }
            if Task.isCancelled { break }
            await transport.disconnect()
            try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
            backoffSeconds = min(backoffSeconds * 2, maxBackoffSeconds)
        }
    }
}
