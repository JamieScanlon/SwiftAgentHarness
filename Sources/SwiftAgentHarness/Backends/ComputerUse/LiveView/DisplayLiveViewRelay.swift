import Foundation

/// Serves live views of targets whose screen is reached only through them, such as a VM guest or a display host,
/// from the frames they give out (``DisplayTarget/liveFrame(_:)``). Each lease gets its own feed: frames are pulled
/// only while someone watches, and a viewer's input is passed on only while the lease has control, which
/// ``setControl(_:for:)`` gives it during takeover.
public actor DisplayLiveViewRelay {
    /// Where one lease's view comes from.
    public struct Source: Sendable {
        public var frame: @Sendable () async -> DisplayLiveViewFrame?
        public var input: @Sendable (DisplayLiveViewInput) async -> Void
        /// Each value the user typed during a takeover, so it can be kept out of helper models' inputs.
        public var typed: @Sendable (String) async -> Void

        public init(
            frame: @escaping @Sendable () async -> DisplayLiveViewFrame?,
            input: @escaping @Sendable (DisplayLiveViewInput) async -> Void,
            typed: @escaping @Sendable (String) async -> Void
        ) {
            self.frame = frame
            self.input = input
            self.typed = typed
        }
    }

    private struct Relayed {
        var feed: UUID
        var source: Source
        var control = false
        var frames: Task<Void, Never>?
    }

    public nonisolated let server: DisplayLiveViewServer
    public nonisolated let frameInterval: Duration
    private var leases: [UUID: Relayed] = [:]

    public init(server: DisplayLiveViewServer, frameInterval: Duration = .milliseconds(500)) {
        self.server = server
        self.frameInterval = frameInterval
    }

    /// Opens the lease's feed. `isShared` marks someone's own screen, which takes observers only if the server allows
    /// them on shared feeds.
    public func open(_ leaseID: UUID, label: String, isShared: Bool, source: Source) async {
        await close(leaseID)
        let feed = await server.open(DisplayLiveViewFeed(
            label: label,
            isShared: isShared,
            viewersChanged: { [weak self] count in await self?.viewersChanged(count, leaseID: leaseID) },
            input: { [weak self] input in await self?.relay(input, leaseID: leaseID) },
            typed: source.typed
        ))
        leases[leaseID] = Relayed(feed: feed, source: source)
    }

    /// Ends the lease's viewers and revokes its links. Idempotent.
    public func close(_ leaseID: UUID) async {
        guard let relayed = leases.removeValue(forKey: leaseID) else { return }
        relayed.frames?.cancel()
        await server.close(relayed.feed)
    }

    public func setControl(_ on: Bool, for leaseID: UUID) async {
        guard let feed = leases[leaseID]?.feed else { return }
        leases[leaseID]?.control = on
        await server.setControl(on, for: feed)
    }

    /// A new link to the lease's view, or `nil` when it has none.
    public func link(for leaseID: UUID, role: DisplayLiveViewRole = .user) async throws -> DisplayLiveView? {
        guard let feed = leases[leaseID]?.feed else { return nil }
        return try await server.link(for: feed, role: role)
    }

    public func viewerCount(_ leaseID: UUID) async -> Int {
        guard let feed = leases[leaseID]?.feed else { return 0 }
        return await server.viewerCount(feed)
    }

    public func connections(_ leaseID: UUID) async -> [DisplayLiveViewConnection] {
        guard let feed = leases[leaseID]?.feed else { return [] }
        return await server.connections(feed)
    }

    public func revoke(_ linkID: UUID, for leaseID: UUID) async -> Bool {
        guard let feed = leases[leaseID]?.feed else { return false }
        return await server.revoke(linkID, in: feed)
    }

    public func endObservers(_ leaseID: UUID) async {
        guard let feed = leases[leaseID]?.feed else { return }
        await server.endObservers(feed)
    }

    private func viewersChanged(_ count: Int, leaseID: UUID) {
        guard var relayed = leases[leaseID] else { return }
        if count > 0, relayed.frames == nil {
            let interval = frameInterval
            relayed.frames = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.publishFrame(leaseID: leaseID)
                    try? await Task.sleep(for: interval)
                }
            }
        } else if count == 0 {
            relayed.frames?.cancel()
            relayed.frames = nil
        }
        leases[leaseID] = relayed
    }

    private func publishFrame(leaseID: UUID) async {
        guard let relayed = leases[leaseID], let frame = await relayed.source.frame() else { return }
        // The lease's view may have closed, or been reopened, while the frame was on its way.
        guard leases[leaseID]?.feed == relayed.feed else { return }
        await server.publish(frame, to: relayed.feed)
    }

    private func relay(_ input: DisplayLiveViewInput, leaseID: UUID) async {
        guard let relayed = leases[leaseID], relayed.control else { return }
        await relayed.source.input(input)
    }
}
