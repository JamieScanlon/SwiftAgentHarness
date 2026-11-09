import Foundation

/// A ``DisplayTarget`` served by a display host over a ``DisplayHostConnection``. The harness uses it like any
/// local target.
///
/// Made with ``connect(using:clientName:reattachWindow:liveView:liveViewFrameInterval:)``, it reconnects when the
/// connection drops and takes its leases back within the host's grace period; calls in flight at the drop fail as
/// ``DisplayTargetError/driverFailure(_:)``, and later calls wait for the reconnection. Made with
/// ``connect(over:clientName:liveView:liveViewFrameInterval:)``, a dropped connection is final: calls throw,
/// `permissions()` reports nothing granted, and the host releases the leases. Call ``close()`` when done with it.
///
/// Given a ``DisplayLiveViewServer``, it serves the live view itself from the frames the host gives out, for a host
/// whose target declares a live view (`observerAccess: stream`) and gives out frames, as `MacHostDisplayTarget` does
/// with `liveFrames`. Without one, live-view calls go to the host.
public actor RemoteDisplayTarget: DisplayTarget {
    public typealias Connector = @Sendable () async throws -> any DisplayHostConnection

    public nonisolated let manifest: DisplayTargetManifest
    public nonisolated let hostName: String

    private struct Handshake: Sendable {
        var version: DisplayHostVersion
        var manifest: DisplayTargetManifest
        var hostName: String
        var capabilities: Set<DisplayHostCapability>
        var imageDirectory: String?
    }

    private struct Holder {
        var lease: Lease
        var isAlive: @Sendable () async -> Bool
        var reattachToken: String?
    }

    private let connector: Connector?
    private let clientName: String
    private let reattachWindow: Duration
    private let relay: DisplayLiveViewRelay?
    private var channel: DisplayHostClientChannel
    private var handshake: Handshake
    private var reconnecting: Task<Void, Never>?
    private var closed = false
    private let hub = DisplayTargetEventHub()
    /// Leases this client holds, with the local holder's liveness.
    private var holders: [UUID: Holder] = [:]

    private init(
        channel: DisplayHostClientChannel,
        handshake: Handshake,
        connector: Connector?,
        clientName: String,
        reattachWindow: Duration,
        liveView: DisplayLiveViewServer?,
        liveViewFrameInterval: Duration
    ) {
        self.channel = channel
        self.handshake = handshake
        self.manifest = handshake.manifest
        self.hostName = handshake.hostName
        self.connector = connector
        self.clientName = clientName
        self.reattachWindow = reattachWindow
        let relays = handshake.manifest.observerAccess == .stream && handshake.capabilities.contains(.liveView)
        self.relay = relays ? liveView.map { DisplayLiveViewRelay(server: $0, frameInterval: liveViewFrameInterval) } : nil
    }

    /// Opens the protocol on `connection` and reads the host's manifest. A dropped connection is final.
    ///
    /// - Parameter liveView: Serves the live view here from the host's frames; see the type's documentation.
    public static func connect(
        over connection: any DisplayHostConnection,
        clientName: String = ProcessInfo.processInfo.processName,
        liveView: DisplayLiveViewServer? = nil,
        liveViewFrameInterval: Duration = .milliseconds(500)
    ) async throws -> RemoteDisplayTarget {
        let (channel, handshake) = try await open(connection, clientName: clientName)
        let target = RemoteDisplayTarget(
            channel: channel, handshake: handshake, connector: nil, clientName: clientName, reattachWindow: .zero,
            liveView: liveView, liveViewFrameInterval: liveViewFrameInterval
        )
        await target.listen(to: channel)
        return target
    }

    /// Connects with `connector`, and again whenever the connection drops, for up to `reattachWindow`, taking back
    /// the leases the host kept for this client.
    ///
    /// - Parameter liveView: Serves the live view here from the host's frames; see the type's documentation. A
    ///   viewer stays connected while the lease is taken back.
    public static func connect(
        using connector: @escaping Connector,
        clientName: String = ProcessInfo.processInfo.processName,
        reattachWindow: Duration = .seconds(5),
        liveView: DisplayLiveViewServer? = nil,
        liveViewFrameInterval: Duration = .milliseconds(500)
    ) async throws -> RemoteDisplayTarget {
        let (channel, handshake) = try await open(try await connector(), clientName: clientName)
        let target = RemoteDisplayTarget(
            channel: channel, handshake: handshake, connector: connector, clientName: clientName, reattachWindow: reattachWindow,
            liveView: liveView, liveViewFrameInterval: liveViewFrameInterval
        )
        await target.listen(to: channel)
        return target
    }

    private static func open(_ connection: any DisplayHostConnection, clientName: String) async throws -> (DisplayHostClientChannel, Handshake) {
        let channel = DisplayHostClientChannel(connection: connection)
        await channel.start()
        var offered = DisplayHostProtocol.capabilities
        if !connection.sharesFilesystem { offered.remove(.imageFiles) }
        let reply: DisplayHostResponse
        do {
            reply = try await channel.call(.hello(
                version: DisplayHostProtocol.version,
                client: clientName,
                capabilities: offered.sorted { $0.rawValue < $1.rawValue }
            ))
        } catch {
            await channel.close()
            throw error
        }
        switch reply {
        case .welcome(let version, let host, let manifest, let capabilities, let imageDirectory)
        where version.major == DisplayHostProtocol.version.major:
            let agreed = offered.intersection(capabilities)
            return (channel, Handshake(
                version: version,
                manifest: manifest,
                hostName: host,
                capabilities: agreed,
                imageDirectory: agreed.contains(.imageFiles) ? imageDirectory : nil
            ))
        case .welcome(let version, _, _, _, _):
            await channel.close()
            throw DisplayHostError.versionMismatch(host: version, client: DisplayHostProtocol.version)
        case .failure(.versionMismatch(let host, let client)):
            await channel.close()
            throw DisplayHostError.versionMismatch(host: host, client: client)
        default:
            await channel.close()
            throw DisplayHostError.unexpectedResponse(String(describing: reply))
        }
    }

    /// The capabilities this connection agreed on with the host.
    public var capabilities: Set<DisplayHostCapability> { handshake.capabilities }

    /// Releases the leases still held, as `holder-lost`, and closes the connection.
    public func close() async {
        closed = true
        reconnecting?.cancel()
        for holder in holders.values {
            await relay?.close(holder.lease.id)
            _ = try? await channel.call(.release(leaseID: holder.lease.id, reason: .holderLost))
            hub.finish(holder.lease.id)
        }
        holders = [:]
        await channel.close()
    }

    // MARK: - Connection

    private func listen(to channel: DisplayHostClientChannel) {
        Task { [weak self] in
            for await event in channel.events {
                guard let self else { return }
                if case .target(let leaseID, let event) = event { self.hub.post(event, to: leaseID) }
                await channel.noteEventHandled()
            }
            await self?.ended(channel)
        }
    }

    private func ended(_ old: DisplayHostClientChannel) async {
        guard !closed, old === channel, reconnecting == nil else { return }
        guard let connector else {
            // The drop is final, so nothing will come to watch.
            for leaseID in holders.keys { await relay?.close(leaseID) }
            return
        }
        let window = reattachWindow
        reconnecting = Task { [weak self] in
            let deadline = ContinuousClock.now.advanced(by: window)
            while ContinuousClock.now < deadline, !Task.isCancelled {
                if let opened = try? await Self.open(try await connector(), clientName: self?.clientName ?? "") {
                    await self?.adopt(opened.0, opened.1)
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            await self?.giveUp()
        }
    }

    private func adopt(_ channel: DisplayHostClientChannel, _ handshake: Handshake) async {
        guard !closed else {
            await channel.close()
            return
        }
        self.channel = channel
        self.handshake = handshake
        listen(to: channel)
        for (leaseID, holder) in holders {
            var answer: DisplayHostResponse?
            if let token = holder.reattachToken, handshake.capabilities.contains(.reattach) {
                answer = try? await channel.call(.reattach(leaseID: leaseID, token: token))
            }
            if case .leaseEnded(let reason)? = answer {
                await lose(leaseID, reason: reason)
                continue
            }
            guard case .reattached(_, let next, let snapshot)? = answer else {
                await lose(leaseID, reason: .holderLost)
                continue
            }
            holders[leaseID]?.reattachToken = next
            hub.post(.permissionsChanged(snapshot.permissions), to: leaseID)
            hub.post(.takeoverChanged(on: snapshot.takeover), to: leaseID)
        }
        reconnecting = nil
    }

    private func giveUp() async {
        for leaseID in holders.keys { await lose(leaseID, reason: .holderLost) }
        reconnecting = nil
    }

    /// The lease is gone: the session hears how it ended before its events stop.
    private func lose(_ leaseID: UUID, reason: ReleaseReason) async {
        holders.removeValue(forKey: leaseID)
        hub.post(.leaseEnded(reason), to: leaseID)
        hub.finish(leaseID)
        await relay?.close(leaseID)
    }

    // MARK: - Target

    public func lease(_ request: LeaseRequest) async throws -> Lease {
        do {
            return try await leaseOnce(request)
        } catch DisplayTargetError.targetBusy(let holder) {
            // The host sees this connection as alive, so it can't tell that a holder here has died.
            guard await releaseDeadHolders() else { throw DisplayTargetError.targetBusy(holder: holder) }
            return try await leaseOnce(request)
        }
    }

    public func release(_ lease: Lease, reason: ReleaseReason) async {
        holders.removeValue(forKey: lease.id)
        await relay?.close(lease.id)
        _ = try? await call(.release(leaseID: lease.id, reason: wireReason(reason)))
        // The host sends what the target said at release before replying; the holder must hear it before its
        // events end.
        await channel.awaitEventsHandled()
        hub.finish(lease.id)
    }

    /// Hosts before 7.1 can't decode `target-unavailable`.
    private func wireReason(_ reason: ReleaseReason) -> ReleaseReason {
        reason == .targetUnavailable && handshake.version.minor < 1 ? .cancelled : reason
    }

    public func permissions() async -> PermissionSnapshot {
        guard case .permissions(let snapshot)? = try? await call(.permissions) else {
            return PermissionSnapshot(states: [:])
        }
        return snapshot
    }

    /// Asks the host. A host that can't say, or doesn't answer, is taken as unlocked: the lease then says if it isn't.
    public func isLocked() async -> Bool {
        guard handshake.capabilities.contains(.lockState), case .locked(let locked)? = try? await call(.isLocked) else {
            return false
        }
        return locked
    }

    public func describe(_ lease: Lease) async throws -> TargetLayout {
        guard case .layout(let layout) = try await call(.describe(leaseID: lease.id)) else { throw unexpected("layout") }
        return layout
    }

    public func observe(_ lease: Lease, _ request: ObserveRequest) async throws -> DisplayObservation {
        guard case .observation(var observation, let file) = try await call(.observe(leaseID: lease.id, request: request)) else {
            throw unexpected("observation")
        }
        if let file { observation.image?.data = try takeImage(file) }
        return observation
    }

    public func act(_ lease: Lease, _ batch: ActionBatch) async throws -> [ActionOutcome] {
        guard case .outcomes(let outcomes) = try await call(.act(leaseID: lease.id, batch: batch)) else {
            throw unexpected("outcomes")
        }
        return outcomes
    }

    public func liveView(_ lease: Lease, role: DisplayLiveViewRole) async throws -> DisplayLiveView? {
        if let relay { return try await relay.link(for: lease.id, role: role) }
        guard handshake.capabilities.contains(.liveView) else { return nil }
        guard case .liveView(let view) = try await call(.liveView(leaseID: lease.id, role: role)) else { throw unexpected("live view") }
        return view
    }

    public func liveViewers(_ lease: Lease) async throws -> Int {
        if let relay { return await relay.viewerCount(lease.id) }
        guard handshake.capabilities.contains(.liveView) else { return 0 }
        guard case .liveViewers(let count) = try await call(.liveViewers(leaseID: lease.id)) else { throw unexpected("viewer count") }
        return count
    }

    public func liveConnections(_ lease: Lease) async throws -> [DisplayLiveViewConnection] {
        if let relay { return await relay.connections(lease.id) }
        guard handshake.capabilities.contains(.liveView) else { return [] }
        guard case .liveConnections(let connections) = try await call(.liveConnections(leaseID: lease.id)) else {
            throw unexpected("live connections")
        }
        return connections
    }

    public func revokeLiveView(_ lease: Lease, id: UUID) async throws -> Bool {
        if let relay { return await relay.revoke(id, for: lease.id) }
        guard handshake.capabilities.contains(.liveView) else { return false }
        guard case .revoked(let revoked) = try await call(.revokeLiveView(leaseID: lease.id, id: id)) else { throw unexpected("revoked") }
        return revoked
    }

    public func liveFrame(_ lease: Lease) async throws -> DisplayLiveViewFrame? {
        guard handshake.capabilities.contains(.liveView) else { return nil }
        guard case .liveFrame(var frame, let file) = try await call(.liveFrame(leaseID: lease.id)) else { throw unexpected("live frame") }
        if let file, frame != nil { frame?.jpeg = try takeImage(file) }
        return frame
    }

    public func liveInput(_ lease: Lease, _ input: DisplayLiveViewInput) async throws {
        guard handshake.capabilities.contains(.liveView) else { throw DisplayTargetError.unsupported("display host \(hostName) serves no live view") }
        guard case .done = try await call(.liveInput(leaseID: lease.id, input: input)) else { throw unexpected("done") }
    }

    public func endObservers(_ lease: Lease) async throws {
        if let relay { return await relay.endObservers(lease.id) }
        guard handshake.capabilities.contains(.liveView) else { return }
        guard case .done = try await call(.endObservers(leaseID: lease.id)) else { throw unexpected("done") }
    }

    public func takeover(_ lease: Lease, on: Bool) async throws {
        guard case .done = try await call(.takeover(leaseID: lease.id, on: on)) else { throw unexpected("done") }
        await relay?.setControl(on, for: lease.id)
    }

    public func downloads(_ lease: Lease) async -> [DisplayDownload] {
        guard handshake.capabilities.contains(.downloads),
              case .downloads(let downloads)? = try? await call(.downloads(leaseID: lease.id))
        else { return [] }
        return downloads
    }

    public func events(_ lease: Lease) async -> AsyncStream<DisplayTargetEvent> {
        guard holders[lease.id] != nil else { return AsyncStream { $0.finish() } }
        return hub.stream(for: lease.id)
    }

    private func leaseOnce(_ request: LeaseRequest) async throws -> Lease {
        guard case .lease(let lease, let token) = try await call(.lease(request: DisplayHostLeaseRequest(request))) else {
            throw unexpected("lease")
        }
        holders[lease.id] = Holder(lease: lease, isAlive: request.isHolderAlive, reattachToken: token)
        await relay?.open(lease.id, label: manifest.label, isShared: manifest.humanPresence == .shared, source: DisplayLiveViewRelay.Source(
            frame: { [weak self] in try? await self?.liveFrame(lease) },
            input: { [weak self] input in try? await self?.liveInput(lease, input) },
            typed: { [hub, leaseID = lease.id] value in hub.post(.typedDuringTakeover(value), to: leaseID) }
        ))
        return lease
    }

    private func releaseDeadHolders() async -> Bool {
        var released = false
        for holder in holders.values {
            guard !(await holder.isAlive()) else { continue }
            await release(holder.lease, reason: .holderLost)
            released = true
        }
        return released
    }

    /// Reads and deletes an image file the host wrote, only from the folder it named at the handshake.
    private func takeImage(_ path: String) throws -> Data {
        guard let directory = handshake.imageDirectory else {
            throw DisplayTargetError.driverFailure("display host \(hostName) sent an image file it didn't agree to")
        }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard file.deletingLastPathComponent().path == URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.path else {
            throw DisplayTargetError.driverFailure("display host \(hostName) sent an image outside its image folder")
        }
        defer { try? FileManager.default.removeItem(at: file) }
        return try Data(contentsOf: file)
    }

    /// Target failures come back as themselves; transport failures as driver failures.
    private func call(_ request: DisplayHostRequest) async throws -> DisplayHostResponse {
        if let reconnecting { await reconnecting.value }
        let response: DisplayHostResponse
        do {
            response = try await channel.call(request)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw DisplayTargetError.driverFailure("display host \(hostName): \(error)")
        }
        switch response {
        case .failure(.target(let error)):
            throw error
        case .failure(let failure):
            throw DisplayTargetError.driverFailure("display host \(hostName): \(failure)")
        default:
            return response
        }
    }

    private func unexpected(_ expected: String) -> DisplayTargetError {
        .driverFailure("display host \(hostName) sent an unexpected response; expected \(expected)")
    }
}

/// Request ids, pending replies, and the read loop for one client connection.
actor DisplayHostClientChannel {
    nonisolated let events: AsyncStream<DisplayHostEvent>
    private let eventContinuation: AsyncStream<DisplayHostEvent>.Continuation
    private let connection: any DisplayHostConnection
    private var nextID: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<DisplayHostResponse, any Error>] = [:]
    private var closedError: (any Error)?
    private var reader: Task<Void, Never>?
    private var eventsReceived = 0
    private var eventsHandled = 0
    private var handledWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(connection: any DisplayHostConnection) {
        self.connection = connection
        (events, eventContinuation) = AsyncStream.makeStream(of: DisplayHostEvent.self)
    }

    deinit {
        reader?.cancel()
    }

    func start() {
        guard reader == nil else { return }
        let inbound = connection.inbound
        reader = Task { [weak self] in
            var failure: any Error = DisplayHostError.connectionClosed
            do {
                for try await data in inbound {
                    guard let self else { return }
                    await self.receive(data)
                }
            } catch {
                failure = error
            }
            await self?.finish(failure)
        }
    }

    func call(_ request: DisplayHostRequest) async throws -> DisplayHostResponse {
        if let closedError { throw closedError }
        let id = nextID
        nextID += 1
        let message = try DisplayHostCodec.encode(.request(id: id, body: request))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                Task { await self.send(message, id: id) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func close() async {
        await connection.close()
        finish(DisplayHostError.connectionClosed)
        reader?.cancel()
    }

    private func send(_ message: Data, id: UInt64) async {
        do {
            try await connection.send(message)
        } catch {
            pending.removeValue(forKey: id)?.resume(throwing: error)
        }
    }

    private func cancel(_ id: UInt64) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func receive(_ data: Data) {
        guard let message = try? DisplayHostCodec.decode(data) else { return }
        switch message {
        case .response(let id, let body):
            pending.removeValue(forKey: id)?.resume(returning: body)
        case .event(let event):
            eventsReceived += 1
            eventContinuation.yield(event)
        case .request:
            break
        }
    }

    /// The listener handed on one more event.
    func noteEventHandled() {
        eventsHandled += 1
        let ready = handledWaiters.filter { $0.count <= eventsHandled }
        handledWaiters.removeAll { $0.count <= eventsHandled }
        for waiter in ready { waiter.continuation.resume() }
    }

    /// Returns once every event received so far has been handed on, or the channel has closed.
    func awaitEventsHandled() async {
        let count = eventsReceived
        guard eventsHandled < count, closedError == nil else { return }
        await withCheckedContinuation { handledWaiters.append((count, $0)) }
    }

    private func finish(_ error: any Error) {
        guard closedError == nil else { return }
        let waiters = handledWaiters
        handledWaiters.removeAll()
        for waiter in waiters { waiter.continuation.resume() }
        closedError = error
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
        eventContinuation.finish()
    }
}
