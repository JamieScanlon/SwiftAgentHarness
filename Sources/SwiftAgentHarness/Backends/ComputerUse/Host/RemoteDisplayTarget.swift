import Foundation

/// A ``DisplayTarget`` served by a display host over a ``DisplayHostConnection``. The harness uses it like any
/// local target.
///
/// When the connection drops, calls in flight and later calls throw ``DisplayTargetError/driverFailure(_:)``,
/// `permissions()` reports nothing granted, and the host releases this client's leases. Call ``close()`` when
/// done with it.
public actor RemoteDisplayTarget: DisplayTarget {
    public nonisolated let manifest: DisplayTargetManifest
    public nonisolated let hostName: String
    /// Events from the host, such as its stop key. Iterate from one task.
    public nonisolated let events: AsyncStream<DisplayHostEvent>

    private let channel: DisplayHostClientChannel
    /// Leases this client holds, with the local holder's liveness.
    private var holders: [UUID: (lease: Lease, isAlive: @Sendable () async -> Bool)] = [:]

    private init(channel: DisplayHostClientChannel, manifest: DisplayTargetManifest, hostName: String) {
        self.channel = channel
        self.manifest = manifest
        self.hostName = hostName
        self.events = channel.events
    }

    /// Opens the protocol on `connection` and reads the host's manifest.
    public static func connect(
        over connection: any DisplayHostConnection,
        clientName: String = ProcessInfo.processInfo.processName
    ) async throws -> RemoteDisplayTarget {
        let channel = DisplayHostClientChannel(connection: connection)
        await channel.start()
        let reply: DisplayHostResponse
        do {
            reply = try await channel.call(.hello(version: DisplayHostProtocol.version, client: clientName))
        } catch {
            await channel.close()
            throw error
        }
        switch reply {
        case .welcome(let version, let host, let manifest) where version == DisplayHostProtocol.version:
            return RemoteDisplayTarget(channel: channel, manifest: manifest, hostName: host)
        case .welcome(let version, _, _):
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

    public func close() async {
        await channel.close()
    }

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
        _ = try? await channel.call(.release(leaseID: lease.id, reason: reason))
    }

    public func permissions() async -> PermissionSnapshot {
        guard case .permissions(let snapshot)? = try? await channel.call(.permissions) else {
            return PermissionSnapshot(states: [:])
        }
        return snapshot
    }

    public func describe(_ lease: Lease) async throws -> TargetLayout {
        guard case .layout(let layout) = try await call(.describe(leaseID: lease.id)) else { throw unexpected("layout") }
        return layout
    }

    public func observe(_ lease: Lease, _ request: ObserveRequest) async throws -> DisplayObservation {
        guard case .observation(let observation) = try await call(.observe(leaseID: lease.id, request: request)) else {
            throw unexpected("observation")
        }
        return observation
    }

    public func act(_ lease: Lease, _ batch: ActionBatch) async throws -> [ActionOutcome] {
        guard case .outcomes(let outcomes) = try await call(.act(leaseID: lease.id, batch: batch)) else {
            throw unexpected("outcomes")
        }
        return outcomes
    }

    public func liveView(_ lease: Lease) async throws -> DisplayLiveView? {
        guard case .liveView(let view) = try await call(.liveView(leaseID: lease.id)) else { throw unexpected("live view") }
        return view
    }

    public func takeover(_ lease: Lease, on: Bool) async throws {
        guard case .done = try await call(.takeover(leaseID: lease.id, on: on)) else { throw unexpected("done") }
    }

    private func leaseOnce(_ request: LeaseRequest) async throws -> Lease {
        guard case .lease(let lease) = try await call(.lease(request: DisplayHostLeaseRequest(request))) else {
            throw unexpected("lease")
        }
        holders[lease.id] = (lease, request.isHolderAlive)
        return lease
    }

    private func releaseDeadHolders() async -> Bool {
        var released = false
        for holder in holders.values {
            guard !(await holder.isAlive()) else { continue }
            await release(holder.lease, reason: .aborted)
            released = true
        }
        return released
    }

    /// Target failures come back as themselves; transport failures as driver failures.
    private func call(_ request: DisplayHostRequest) async throws -> DisplayHostResponse {
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
            eventContinuation.yield(event)
        case .request:
            break
        }
    }

    private func finish(_ error: any Error) {
        guard closedError == nil else { return }
        closedError = error
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
        eventContinuation.finish()
    }
}
